defmodule NeuZeit.Planning.Plans do
  @moduledoc false
  alias NeuZeit.Planning.WriteSupport
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Constraints.Occurrence
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Planning.ScheduleException
  alias NeuZeit.Repo

  def list_plans do
    Repo.all(from p in Plan, order_by: [asc: p.term_id, asc: p.name], preload: [:term])
  end

  @doc """
  Lists a term's plans in order: drafts, active plan, archived plans.
  """
  def list_plans(term_id) do
    Repo.all(
      from p in Plan,
        where: p.term_id == ^term_id,
        order_by: [
          asc: fragment("array_position(ARRAY['draft','active','archived'], ?)", p.status),
          asc: p.name
        ],
        preload: [:term]
    )
  end

  def get_plan!(id, term_id) do
    record = get_plan!(id)
    if record.term_id != term_id, do: raise(Ecto.NoResultsError, queryable: Plan)
    record
  end

  def get_plan!(id), do: Plan |> Repo.get!(id) |> Repo.preload([:term, :placements])

  def create_plan(attrs), do: %Plan{} |> Plan.create_changeset(attrs) |> Repo.insert()

  def change_plan(%Plan{} = plan, attrs \\ %{}), do: Plan.update_changeset(plan, attrs)

  def update_plan(%Plan{} = plan, attrs),
    do: plan |> Plan.update_changeset(attrs) |> Repo.update()

  def delete_plan(%Plan{} = plan) do
    WriteSupport.transaction_result(fn ->
      with {:ok, _term} <- WriteSupport.lock_plan_term(plan.id, :not_found) do
        case WriteSupport.fetch_plan(plan.id, lock: true) do
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
    WriteSupport.transaction_result(fn ->
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
               name: WriteSupport.attr(attrs, :name, "#{source.name} copy"),
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

  def publish_plan(plan_id, opts \\ []) do
    do_publish_plan(plan_id, opts)
  rescue
    error in ArgumentError -> WriteSupport.error_result(%Plan{}, :base, Exception.message(error))
  end

  def publish_plan!(plan_id, opts \\ []) do
    case do_publish_plan(plan_id, opts) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp do_publish_plan(plan_id, opts) do
    Repo.transaction(fn ->
      NeuZeit.Planning.SharedResources.lock!()
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

      case NeuZeit.Catalog.Workloads.check(term_id) do
        :ok -> :ok
        {:error, error} -> Repo.rollback(error)
      end

      validate_publishable!(plan, opts)

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

  def validate_publishable!(%Plan{} = plan, opts \\ []) do
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

    incomplete? = not MapSet.subset?(required_ids, placed_ids)

    if incomplete? && Keyword.get(opts, :allow_partial) != true do
      raise ArgumentError,
            "Some sessions are unplaced. Confirm publication of this partial timetable."
    end

    case Hard.validate_placements(plan.placements) do
      :ok -> :ok
      {:error, errors} -> raise ArgumentError, "plan has hard conflicts: #{inspect(errors)}"
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
        week_mask:
          if(placement.session.automatic_weeks,
            do: placement.week_mask,
            else: placement.session.week_mask
          ),
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
end
