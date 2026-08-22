defmodule NeuZeit.Planning do
  @moduledoc """
  Draft plans, placements, publication, occurrence exceptions, and solver runs.
  """

  import Ecto.Query, warn: false

  require Logger

  alias NeuZeit.Catalog.{Session, Term}
  alias NeuZeit.Constraints.{Advisory, Hard, Occurrence, Projection}
  alias NeuZeit.Planning.{Placement, Plan, ScheduleException}
  alias NeuZeit.Repo
  alias NeuZeit.Solver
  alias NeuZeit.Solver.{ResultValidator, SpecBuilder}

  def list_plans do
    Repo.all(from p in Plan, order_by: [asc: p.term_id, asc: p.name], preload: [:term])
  end

  def get_plan!(id), do: Plan |> Repo.get!(id) |> Repo.preload([:term, :placements])
  def create_plan(attrs), do: %Plan{} |> Plan.create_changeset(attrs) |> Repo.insert()

  def update_plan(%Plan{} = plan, attrs),
    do: plan |> Plan.update_changeset(attrs) |> Repo.update()

  def delete_plan(%Plan{} = plan) do
    transaction_result(fn ->
      with {:ok, _term} <- lock_plan_term(plan.id, :not_found) do
        case fetch_plan(plan.id, lock: true) do
          %Plan{status: "active"} ->
            {:error,
             {:conflict,
              "active plans cannot be deleted; publish another plan for the term first"}}

          %Plan{} = locked_plan ->
            Repo.delete(locked_plan)

          nil ->
            {:error, :not_found}
        end
      end
    end)
  end

  def clone_plan(plan_id, attrs \\ %{}) do
    transaction_result(fn ->
      term_id = Repo.one!(from p in Plan, where: p.id == ^plan_id, select: p.term_id)
      Repo.one!(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE")

      source =
        Repo.one!(from p in Plan, where: p.id == ^plan_id, lock: "FOR UPDATE")
        |> Repo.preload(
          placements: [
            :room,
            session: [
              :cohorts,
              teacher: [:availability_cells],
              slot_profile: [:cells],
              course_component: [:allowed_rooms]
            ]
          ]
        )

      with {:ok, plan} <-
             %Plan{}
             |> Plan.changeset(%{
               term_id: source.term_id,
               name: attr(attrs, :name, "#{source.name} copy"),
               status: "draft"
             })
             |> Repo.insert(),
           placements <- cloned_placements(source.placements, plan),
           :ok <- validate_cloned_placements(placements),
           :ok <- insert_cloned_placements(placements) do
        {:ok, plan}
      end
    end)
  end

  def publish_plan(plan_id) do
    do_publish_plan(plan_id)
  rescue
    error in ArgumentError -> error_result(%Plan{}, :base, Exception.message(error))
  end

  def publish_plan!(plan_id) do
    case do_publish_plan(plan_id) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp do_publish_plan(plan_id) do
    Repo.transaction(fn ->
      term_id = Repo.one!(from p in Plan, where: p.id == ^plan_id, select: p.term_id)

      term =
        Repo.one!(from t in NeuZeit.Catalog.Term, where: t.id == ^term_id, lock: "FOR UPDATE")

      plan =
        Repo.one!(from p in Plan, where: p.id == ^plan_id, lock: "FOR UPDATE")
        |> Repo.preload(
          placements: [
            :room,
            session: [
              :cohorts,
              teacher: [:availability_cells],
              slot_profile: [:cells],
              course_component: [:allowed_rooms]
            ]
          ]
        )

      validate_publishable!(plan)

      exceptions =
        Repo.all(
          from e in ScheduleException,
            where: e.term_id == ^term_id and e.status == "active"
        )

      case Occurrence.validate(
             term,
             plan.placements,
             exceptions,
             dates: Occurrence.affected_dates(exceptions),
             require_origins: true
           ) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      from(p in Plan, where: p.term_id == ^term_id and p.status == "active")
      |> Repo.update_all(set: [status: "archived"])

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      published_at = plan.published_at || now

      plan
      |> Plan.changeset(%{status: "active", published_at: published_at})
      |> Repo.update!()
    end)
  end

  def validate_publishable!(%Plan{} = plan) do
    if plan.status != "draft" do
      raise ArgumentError, "only draft plans can be published"
    end

    required_ids =
      Session
      |> where([s], s.term_id == ^plan.term_id)
      |> select([s], s.id)
      |> Repo.all()
      |> MapSet.new()

    placed_ids = plan.placements |> Enum.map(& &1.session_id) |> MapSet.new()

    if MapSet.size(required_ids) != MapSet.size(placed_ids) or
         not MapSet.subset?(required_ids, placed_ids) do
      raise ArgumentError, "plan has unplaced sessions"
    end

    case Hard.validate_placements(plan.placements) do
      :ok -> :ok
      {:error, errors} -> raise ArgumentError, "plan has hard conflicts: #{inspect(errors)}"
    end
  end

  def list_placements do
    Repo.all(
      from p in Placement,
        order_by: [asc: p.plan_id, asc: p.day, asc: p.slot],
        preload: [:room, :plan, session: [:cohorts, slot_profile: [:cells]]]
    )
  end

  def get_placement!(id),
    do:
      Placement
      |> Repo.get!(id)
      |> Repo.preload([:room, :plan, session: [:cohorts, slot_profile: [:cells]]])

  def create_placement(attrs) do
    transaction_result(fn ->
      with {:ok, plan_id} <- require_id(attr(attrs, :plan_id), %Placement{}, :plan_id),
           {:ok, _term} <- lock_plan_term(plan_id),
           {:ok, attrs} <- hydrate_placement_attrs(attrs, lock_plan: true),
           :ok <- validate_candidate(attrs),
           {:ok, placement} <- %Placement{} |> Placement.changeset(attrs) |> Repo.insert() do
        {:ok, placement}
      end
    end)
  end

  def update_placement(%Placement{} = placement, attrs) do
    transaction_result(fn ->
      with {:ok, _term} <- lock_plan_term(placement.plan_id) do
        placement = lock_placement!(placement.id) |> Repo.preload([:plan, :session])
        attrs = placement |> placement_attrs() |> Map.merge(stringify_keys(attrs))

        with :ok <- ensure_same_plan(placement, attrs),
             {:ok, attrs} <- hydrate_placement_attrs(attrs, lock_plan: true),
             :ok <- ensure_unlocked_update(placement, attrs),
             :ok <- validate_candidate(attrs, placement.id),
             {:ok, placement} <- placement |> Placement.changeset(attrs) |> Repo.update() do
          {:ok, placement}
        end
      end
    end)
  end

  def delete_placement(%Placement{} = placement) do
    transaction_result(fn ->
      with {:ok, _term} <- lock_plan_term(placement.plan_id) do
        placement = lock_placement!(placement.id)

        with {:ok, _plan} <- lock_draft_plan(placement.plan_id),
             :ok <- ensure_unlocked_update(placement, %{"delete" => true}),
             {:ok, placement} <- Repo.delete(placement) do
          {:ok, placement}
        end
      end
    end)
  end

  def check_plan(plan_id) do
    plan =
      Plan
      |> Repo.get!(plan_id)
      |> Repo.preload(
        placements: [
          :room,
          session: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [:allowed_rooms]
          ]
        ]
      )

    Hard.check_placements(plan.placements)
  end

  def plan_advisories(plan_id) do
    plan =
      Plan
      |> Repo.get!(plan_id)
      |> Repo.preload(
        placements: [
          :room,
          session: [
            :cohorts,
            slot_profile: [:cells],
            course_component: [:course, :allowed_rooms]
          ]
        ]
      )

    Advisory.check_placements(plan.placements)
  end

  def solve_plan(plan_id) do
    with :ok <- ensure_draft_plan(plan_id),
         :ok <- validate_solver_input(plan_id),
         spec <- SpecBuilder.build!(plan_id),
         {:ok, result} <- solve_spec(spec),
         {:ok, persisted} <- persist_solver_result(plan_id, result) do
      {:ok, persisted.result}
    end
  end

  def project_active_term(term_id) do
    term = Repo.get!(Term, term_id)

    plan =
      Repo.one(
        from p in Plan,
          where: p.term_id == ^term_id and p.status == "active",
          preload: [
            placements: [
              :room,
              session: [
                :cohorts,
                teacher: [:availability_cells],
                slot_profile: [:cells],
                course_component: [:allowed_rooms]
              ]
            ]
          ]
      )

    exceptions =
      Repo.all(
        from e in ScheduleException,
          where: e.term_id == ^term_id and e.status == "active",
          preload: [:session]
      )

    placements = if plan, do: plan.placements, else: []
    placed_session_ids = MapSet.new(placements, & &1.session_id)

    unplaced_session_ids =
      Repo.all(from s in Session, where: s.term_id == ^term_id, order_by: s.id, select: s.id)
      |> Enum.reject(&MapSet.member?(placed_session_ids, &1))

    %{
      occurrences: Projection.project(term, placements, exceptions),
      unplaced_session_ids: unplaced_session_ids,
      active_plan_id: plan && plan.id
    }
  end

  def list_schedule_exceptions do
    Repo.all(from e in ScheduleException, order_by: [asc: e.term_id, asc: e.occurrence_date])
  end

  def get_schedule_exception!(id), do: Repo.get!(ScheduleException, id)

  def create_schedule_exception(attrs) do
    transaction_result(fn ->
      with {:ok, attrs} <- hydrate_exception_attrs(attrs),
           {:ok, term} <- lock_term(attr(attrs, :term_id)),
           changeset = ScheduleException.changeset(%ScheduleException{}, attrs),
           :ok <- validate_exception_change(term, changeset, nil),
           {:ok, exception} <- Repo.insert(changeset) do
        {:ok, exception}
      end
    end)
  end

  def update_schedule_exception(%ScheduleException{} = exception, attrs) do
    transaction_result(fn ->
      with {:ok, term} <- lock_term(exception.term_id),
           {:ok, current} <- lock_schedule_exception(exception.id),
           changeset = ScheduleException.update_changeset(current, attrs),
           :ok <- validate_exception_change(term, changeset, current),
           {:ok, updated} <- Repo.update(changeset) do
        {:ok, updated}
      end
    end)
  end

  def delete_schedule_exception(%ScheduleException{} = exception) do
    transaction_result(fn ->
      with {:ok, term} <- lock_term(exception.term_id),
           {:ok, current} <- lock_schedule_exception(exception.id),
           :ok <- validate_exception_removal(term, current),
           {:ok, deleted} <- Repo.delete(current) do
        {:ok, deleted}
      end
    end)
  end

  defp hydrate_placement_attrs(attrs, opts) do
    with {:ok, plan_id} <- require_id(attr(attrs, :plan_id), %Placement{}, :plan_id),
         {:ok, session_id} <- require_id(attr(attrs, :session_id), %Placement{}, :session_id),
         %Plan{} = plan <- fetch_plan(plan_id, lock: Keyword.get(opts, :lock_plan, false)),
         :ok <- ensure_draft_plan_status(plan),
         %Session{} = session <- Repo.get(Session, session_id),
         true <- plan.term_id == session.term_id do
      {:ok,
       attrs
       |> stringify_keys()
       |> Map.put("term_id", plan.term_id)
       |> Map.put("week_mask", session.week_mask)
       |> Map.put("duration_slots", session.duration_slots)}
    else
      {:error, _reason} = error -> error
      false -> error_result(%Placement{}, :term_id, "must match plan and session term")
      nil -> error_result(%Placement{}, :plan_id, "or session_id does not exist")
    end
  end

  defp hydrate_exception_attrs(attrs) do
    with {:ok, session_id} <-
           require_id(attr(attrs, :session_id), %ScheduleException{}, :session_id),
         %Session{} = session <- Repo.get(Session, session_id) do
      {:ok, attrs |> stringify_keys() |> Map.put("term_id", session.term_id)}
    else
      {:error, _reason} = error -> error
      nil -> error_result(%ScheduleException{}, :session_id, "does not exist")
    end
  end

  defp require_id(nil, schema, field), do: error_result(schema, field, "can't be blank")

  defp require_id(value, schema, field) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> error_result(schema, field, "is invalid")
    end
  end

  defp validate_exception_change(term, changeset, previous) do
    candidate = Ecto.Changeset.apply_changes(changeset)

    if changeset.valid? and exception_dates_valid?(term, candidate) do
      placements = active_placements(term.id)
      existing = active_exceptions(term.id, previous && previous.id)

      resulting =
        if candidate.status == "active", do: [candidate | existing], else: existing

      with :ok <- validate_candidate_origin(changeset, term, placements, candidate),
           :ok <-
             Occurrence.validate(
               term,
               placements,
               resulting,
               dates: Occurrence.affected_dates([previous, candidate])
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp validate_exception_removal(term, exception) do
    placements = active_placements(term.id)
    resulting = active_exceptions(term.id, exception.id)

    Occurrence.validate(
      term,
      placements,
      resulting,
      dates: Occurrence.affected_dates([exception])
    )
  end

  defp validate_candidate_origin(changeset, term, placements, candidate) do
    excluded_dates = MapSet.new(term.excluded_dates || [])

    cond do
      candidate.status != "active" ->
        :ok

      candidate.kind in ["move", "cancel"] and
          not Projection.template_occurrence?(
            term,
            placements,
            candidate.session_id,
            candidate.occurrence_date
          ) ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :occurrence_date,
           "does not match any scheduled occurrence"
         )}

      candidate.kind == "cancel" and MapSet.member?(excluded_dates, candidate.occurrence_date) ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :occurrence_date,
           "is already removed from the schedule by an excluded date"
         )}

      true ->
        :ok
    end
  end

  defp active_placements(term_id) do
    Repo.all(
      from p in Placement,
        join: plan in assoc(p, :plan),
        where: plan.term_id == ^term_id and plan.status == "active"
    )
  end

  defp active_exceptions(term_id, exclude_id) do
    query =
      from e in ScheduleException,
        where: e.term_id == ^term_id and e.status == "active"

    query = if exclude_id, do: from(e in query, where: e.id != ^exclude_id), else: query
    Repo.all(query)
  end

  defp exception_dates_valid?(term, exception) do
    days_count = length(NeuZeit.Config.grid!().days)
    slots_count = length(NeuZeit.Config.grid!().slots)

    duration_slots =
      case Repo.get(Session, exception.session_id) do
        %Session{duration_slots: duration} -> duration
        nil -> 1
      end

    valid_date? = fn
      nil ->
        true

      %Date{} = date ->
        not Date.before?(date, term.starts_on) and not Date.after?(date, term.ends_on) and
          Date.day_of_week(date) <= days_count

      _other ->
        false
    end

    valid_date?.(exception.occurrence_date) and valid_date?.(exception.new_date) and
      (is_nil(exception.new_slot) or
         (is_integer(exception.new_slot) and exception.new_slot > 0 and
            exception.new_slot + duration_slots - 1 <= slots_count))
  end

  defp lock_term(term_id) do
    case Repo.one(from t in Term, where: t.id == ^term_id, lock: "FOR UPDATE") do
      %Term{} = term -> {:ok, term}
      nil -> error_result(%ScheduleException{}, :term_id, "does not exist")
    end
  end

  defp lock_schedule_exception(id) do
    case Repo.one(from e in ScheduleException, where: e.id == ^id, lock: "FOR UPDATE") do
      %ScheduleException{} = exception -> {:ok, exception}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_draft_plan(plan_id) do
    case fetch_plan(plan_id) do
      %Plan{} = plan -> ensure_draft_plan_status(plan)
      nil -> error_result(%Placement{}, :plan_id, "does not exist")
    end
  end

  defp lock_draft_plan(plan_id) do
    case fetch_plan(plan_id, lock: true) do
      %Plan{status: "draft"} = plan -> {:ok, plan}
      %Plan{} -> error_result(%Placement{}, :plan_id, "is read-only unless it is a draft")
      nil -> error_result(%Placement{}, :plan_id, "does not exist")
    end
  end

  defp ensure_draft_plan_status(%Plan{status: "draft"}), do: :ok

  defp ensure_draft_plan_status(%Plan{}) do
    error_result(%Placement{}, :plan_id, "is read-only unless it is a draft")
  end

  defp ensure_unlocked_update(%Placement{locked: true}, attrs) do
    if attr(attrs, :locked) in [false, "false"] do
      :ok
    else
      error_result(%Placement{}, :locked, "locked placements cannot be changed without unlocking")
    end
  end

  defp ensure_unlocked_update(_placement, _attrs), do: :ok

  defp ensure_same_plan(placement, attrs) do
    if attr(attrs, :plan_id) == placement.plan_id do
      :ok
    else
      error_result(%Placement{}, :plan_id, "is read-only")
    end
  end

  defp validate_candidate(attrs, self_id \\ nil) do
    changeset = Placement.changeset(%Placement{}, attrs)

    if changeset.valid? do
      validate_candidate_constraints(changeset, attrs, self_id)
    else
      {:error, changeset}
    end
  end

  defp validate_candidate_constraints(changeset, attrs, self_id) do
    plan_id = attr(attrs, :plan_id)

    existing_query =
      from p in Placement,
        where: p.plan_id == ^plan_id,
        preload: [
          :room,
          session: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [:allowed_rooms]
          ]
        ]

    existing_query =
      if self_id do
        from p in existing_query, where: p.id != ^self_id
      else
        existing_query
      end

    existing = Repo.all(existing_query)

    candidate =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Repo.preload([
        :room,
        session: [
          :cohorts,
          teacher: [:availability_cells],
          slot_profile: [:cells],
          course_component: [:allowed_rooms]
        ]
      ])

    case Hard.validate_placements([candidate | existing]) do
      :ok -> :ok
      {:error, errors} -> {:error, %{errors: errors}}
    end
  end

  defp validate_solver_input(plan_id) do
    case check_plan(plan_id) do
      [] -> :ok
      errors -> {:error, %{errors: errors}}
    end
  end

  defp cloned_placements(source_placements, plan) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.map(source_placements, fn placement ->
      %Placement{
        id: Ecto.UUID.generate(version: 7),
        plan_id: plan.id,
        session_id: placement.session_id,
        term_id: placement.term_id,
        week_mask: placement.session.week_mask,
        duration_slots: placement.session.duration_slots,
        room_id: placement.room_id,
        day: placement.day,
        slot: placement.slot,
        locked: placement.locked,
        session: placement.session,
        room: placement.room,
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp validate_cloned_placements(placements) do
    case Hard.validate_placements(placements) do
      :ok -> :ok
      {:error, errors} -> {:error, %{errors: errors}}
    end
  end

  defp insert_cloned_placements(placements) do
    fields = [
      :id,
      :plan_id,
      :session_id,
      :term_id,
      :week_mask,
      :duration_slots,
      :room_id,
      :day,
      :slot,
      :locked,
      :inserted_at,
      :updated_at
    ]

    rows = Enum.map(placements, &(&1 |> Map.from_struct() |> Map.take(fields)))
    Repo.insert_all(Placement, rows)
    :ok
  end

  defp solve_spec(spec) do
    case Solver.solve(spec) do
      {:ok, result} -> {:ok, result}
      {:error, result} when is_map(result) -> {:error, %{errors: [solver_error(result)]}}
      {:error, reason} -> {:error, %{errors: [solver_error(%{"error" => inspect(reason)})]}}
    end
  end

  defp solver_error(result) do
    status = result["status"] || "failed"

    Logger.error("solver failed with status #{inspect(status)}: #{inspect(result)}")

    %{
      type: "solver_#{status |> to_string() |> String.downcase()}",
      message: result["error"] || "solver could not produce a complete timetable",
      solver_status: status
    }
  end

  defp persist_solver_result(plan_id, result) do
    transaction_result(fn ->
      with {:ok, _term} <- lock_plan_term(plan_id),
           {:ok, plan} <- lock_draft_plan(plan_id),
           :ok <- validate_solver_input(plan_id),
           spec <- SpecBuilder.build!(plan_id),
           {:ok, validated} <- ResultValidator.validate(plan_id, spec, result),
           :ok <- replace_solver_placements(plan, validated) do
        {:ok, validated}
      end
    end)
  rescue
    error in Ecto.ConstraintError ->
      {:error,
       %{
         errors: [
           %{
             type: "solver_persistence_failed",
             message: Exception.message(error)
           }
         ]
       }}
  end

  defp replace_solver_placements(plan, %{placements: placements}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(p in Placement, where: p.plan_id == ^plan.id and p.locked == false)
    |> Repo.delete_all()

    rows =
      placements
      |> Enum.map(fn placement ->
        %{
          plan_id: plan.id,
          session_id: placement.session_id,
          term_id: plan.term_id,
          week_mask: placement.week_mask,
          duration_slots: placement.duration_slots,
          room_id: placement.room_id,
          day: placement.day,
          slot: placement.slot,
          locked: placement.locked,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows = Enum.map(rows, &Map.put_new(&1, :id, Ecto.UUID.generate(version: 7)))

    Repo.insert_all(Placement, rows,
      on_conflict:
        {:replace,
         [
           :term_id,
           :week_mask,
           :duration_slots,
           :room_id,
           :day,
           :slot,
           :locked,
           :updated_at
         ]},
      conflict_target: [:plan_id, :session_id]
    )

    :ok
  end

  defp fetch_plan(plan_id, opts \\ []) do
    query = from p in Plan, where: p.id == ^plan_id

    query =
      if Keyword.get(opts, :lock, false), do: from(p in query, lock: "FOR UPDATE"), else: query

    Repo.one(query)
  end

  defp lock_placement!(id) do
    Repo.one!(from p in Placement, where: p.id == ^id, lock: "FOR UPDATE")
  end

  defp lock_plan_term(plan_id, missing \\ :changeset) do
    case Repo.one(from plan in Plan, where: plan.id == ^plan_id, select: plan.term_id) do
      nil ->
        case missing do
          :not_found -> {:error, :not_found}
          :changeset -> error_result(%Placement{}, :plan_id, "does not exist")
        end

      term_id ->
        {:ok, Repo.one!(from term in Term, where: term.id == ^term_id, lock: "FOR UPDATE")}
    end
  end

  defp placement_attrs(%Placement{} = placement) do
    %{
      "plan_id" => placement.plan_id,
      "session_id" => placement.session_id,
      "term_id" => placement.term_id,
      "week_mask" => placement.week_mask,
      "duration_slots" => placement.duration_slots,
      "room_id" => placement.room_id,
      "day" => placement.day,
      "slot" => placement.slot,
      "locked" => placement.locked
    }
  end

  defp transaction_result(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, result} -> result
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_result(schema, field, message) do
    {:error,
     schema
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(field, message)}
  end

  defp attr(attrs, key, default \\ nil)

  defp attr(attrs, key, default) when is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
