defmodule NeuZeit.Planning.Placements do
  @moduledoc false
  alias NeuZeit.Planning.WriteSupport
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Planning.Placement
  alias NeuZeit.Planning.Plan
  alias NeuZeit.Repo

  def list_placements do
    Repo.all(
      from p in Placement,
        order_by: [asc: p.plan_id, asc: p.day, asc: p.slot],
        preload: [:room, :plan, session: [:cohorts, slot_profile: [:cells]]]
    )
  end

  @doc """
  Lists one plan's placements with associations required by the board.
  """
  def list_placements(plan_id) do
    Repo.all(
      from p in Placement,
        where: p.plan_id == ^plan_id,
        order_by: [asc: p.day, asc: p.slot],
        preload: [
          :room,
          session: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [
              :allowed_rooms,
              course: :translations,
              teaching_type: :translations
            ]
          ]
        ]
    )
  end

  def get_placement!(id),
    do:
      Placement
      |> Repo.get!(id)
      |> Repo.preload([:room, :plan, session: [:cohorts, slot_profile: [:cells]]])

  def create_placement(attrs) do
    WriteSupport.transaction_result(fn ->
      with {:ok, plan_id} <-
             WriteSupport.require_id(WriteSupport.attr(attrs, :plan_id), %Placement{}, :plan_id),
           {:ok, _term} <- WriteSupport.lock_plan_term(plan_id),
           {:ok, attrs} <- hydrate_placement_attrs(attrs, lock_plan: true),
           :ok <- validate_candidate(attrs),
           {:ok, placement} <- %Placement{} |> Placement.changeset(attrs) |> Repo.insert() do
        {:ok, placement}
      end
    end)
  end

  def update_placement(%Placement{} = placement, attrs) do
    WriteSupport.transaction_result(fn ->
      with {:ok, _term} <- WriteSupport.lock_plan_term(placement.plan_id) do
        placement = lock_placement!(placement.id) |> Repo.preload([:plan, :session])
        attrs = placement |> placement_attrs() |> Map.merge(WriteSupport.stringify_keys(attrs))

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
    WriteSupport.transaction_result(fn ->
      with {:ok, _term} <- WriteSupport.lock_plan_term(placement.plan_id) do
        placement = lock_placement!(placement.id)

        with {:ok, _plan} <- WriteSupport.lock_draft_plan(placement.plan_id),
             :ok <- ensure_unlocked_update(placement, %{"delete" => true}),
             {:ok, placement} <- Repo.delete(placement) do
          {:ok, placement}
        end
      end
    end)
  end

  @doc """
  Applies several placement changes as one edit.

  A change sets `day`, `slot`, `room_id` and optionally `week_mask` for a
  session, creating its placement when it has none, or removes the placement
  with `remove: true`. Rules are checked once on the result, so sessions can
  exchange positions.
  """
  def change_placements(plan_id, changes) do
    WriteSupport.transaction_result(fn ->
      with {:ok, term} <- WriteSupport.lock_plan_term(plan_id),
           {:ok, _plan} <- WriteSupport.lock_draft_plan(plan_id) do
        # Rows may pass through each other's rooms until the last change is written.
        Repo.query!("SET CONSTRAINTS placements_no_overlapping_week_room DEFERRED")

        current =
          Repo.all(from p in Placement, where: p.plan_id == ^plan_id, lock: "FOR UPDATE")
          |> Map.new(&{&1.session_id, &1})

        with {:ok, ids} <- write_changes(plan_id, current, changes),
             :ok <- validate_changed(term, plan_id, ids) do
          {:ok, ids}
        end
      end
    end)
  end

  defp write_changes(plan_id, current, changes) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, ids} ->
      case write_change(plan_id, Map.get(current, change.session_id), change) do
        {:ok, nil} -> {:cont, {:ok, ids}}
        {:ok, placement} -> {:cont, {:ok, [placement.id | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_change(_plan_id, nil, %{remove: true}), do: {:ok, nil}

  defp write_change(_plan_id, placement, %{remove: true}) do
    with :ok <- ensure_unlocked_update(placement, %{"delete" => true}),
         {:ok, _placement} <- Repo.delete(placement) do
      {:ok, nil}
    end
  end

  defp write_change(plan_id, nil, change) do
    attrs = change |> WriteSupport.stringify_keys() |> Map.put("plan_id", plan_id)

    with {:ok, attrs} <- hydrate_placement_attrs(attrs, lock_plan: false) do
      %Placement{} |> Placement.changeset(attrs) |> Repo.insert()
    end
  end

  defp write_change(_plan_id, placement, change) do
    attrs = placement |> placement_attrs() |> Map.merge(WriteSupport.stringify_keys(change))

    with {:ok, attrs} <- hydrate_placement_attrs(attrs, lock_plan: false),
         :ok <- ensure_unlocked_update(placement, attrs) do
      placement |> Placement.changeset(attrs) |> Repo.update()
    end
  end

  # The same rules as a single edit, on the plan after every change.
  defp validate_changed(term, plan_id, ids) do
    placements =
      Repo.all(
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
      )

    changed = Enum.filter(placements, &(&1.id in ids))

    case Hard.validate_placements(placements, NeuZeit.Config.grid!(term)) do
      :ok ->
        with :ok <- NeuZeit.Constraints.AutomaticWeeks.validate(term, changed) do
          NeuZeit.Planning.SharedResources.validate(term, changed)
        end

      {:error, errors} ->
        {:error, %{errors: errors}}
    end
  end

  defp hydrate_placement_attrs(attrs, opts) do
    with {:ok, plan_id} <-
           WriteSupport.require_id(WriteSupport.attr(attrs, :plan_id), %Placement{}, :plan_id),
         {:ok, session_id} <-
           WriteSupport.require_id(
             WriteSupport.attr(attrs, :session_id),
             %Placement{},
             :session_id
           ),
         %Plan{} = plan <-
           WriteSupport.fetch_plan(plan_id, lock: Keyword.get(opts, :lock_plan, false)),
         :ok <- WriteSupport.ensure_draft_plan_status(plan),
         %Session{} = session <- Repo.get(Session, session_id),
         true <- plan.term_id == session.term_id do
      attrs = WriteSupport.stringify_keys(attrs)
      attrs = if session.delivery_mode == :online, do: Map.put(attrs, "room_id", nil), else: attrs

      {:ok,
       attrs
       |> Map.put("term_id", plan.term_id)
       |> Map.put(
         "week_mask",
         if(session.automatic_weeks,
           do: WriteSupport.attr(attrs, :week_mask, [hd(session.week_mask)]),
           else: session.week_mask
         )
       )
       |> Map.put("duration_slots", session.duration_slots)}
    else
      {:error, _reason} = error ->
        error

      false ->
        WriteSupport.error_result(%Placement{}, :term_id, "must match plan and session term")

      nil ->
        WriteSupport.error_result(%Placement{}, :plan_id, "or session_id does not exist")
    end
  end

  defp ensure_unlocked_update(%Placement{locked: true}, attrs) do
    if WriteSupport.attr(attrs, :locked) in [false, "false"] do
      :ok
    else
      WriteSupport.error_result(
        %Placement{},
        :locked,
        "locked placements cannot be changed without unlocking"
      )
    end
  end

  defp ensure_unlocked_update(_placement, _attrs), do: :ok

  defp ensure_same_plan(placement, attrs) do
    if WriteSupport.attr(attrs, :plan_id) == placement.plan_id do
      :ok
    else
      WriteSupport.error_result(%Placement{}, :plan_id, "is read-only")
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
    plan_id = WriteSupport.attr(attrs, :plan_id)

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
      :ok ->
        with :ok <-
               NeuZeit.Constraints.AutomaticWeeks.validate(
                 Repo.get!(Term, WriteSupport.attr(attrs, :term_id)),
                 [candidate]
               ) do
          NeuZeit.Planning.SharedResources.validate(
            Repo.get!(Term, WriteSupport.attr(attrs, :term_id)),
            [
              candidate
            ]
          )
        end

      {:error, errors} ->
        {:error, %{errors: errors}}
    end
  end

  defp lock_placement!(id) do
    Repo.one!(from p in Placement, where: p.id == ^id, lock: "FOR UPDATE")
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
end
