defmodule NeuZeit.Solver.ResultValidator do
  @moduledoc false

  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Planning.{Placement, SharedResources}
  alias NeuZeit.Solver.Snapshot

  def validate(plan_id, spec, result) do
    with {:ok, _assignment} <- parse_assignment(result),
         {:ok, snapshot} <- Snapshot.load(plan_id) do
      validate_snapshot(snapshot, spec, result)
    else
      {:error, :not_found} -> {:error, errors(error("plan_not_found", "plan no longer exists"))}
      error -> error
    end
  end

  @doc "Checks output against explicit inputs without database access or generated IDs."
  def validate_snapshot(snapshot, spec, result) do
    with {:ok, assignment} <- parse_assignment(result),
         :ok <- validate_session_ids(assignment, snapshot.sessions),
         {:ok, rooms} <- rooms_for_assignment(assignment, snapshot.rooms),
         {:ok, placements} <-
           build_placements(snapshot.plan, snapshot.sessions, rooms, assignment, spec.fixed),
         :ok <- validate_fixed_placements(placements, spec.fixed),
         :ok <- validate_hard_constraints(placements, snapshot.config.grid),
         :ok <- NeuZeit.Constraints.AutomaticWeeks.validate(snapshot.plan.term, placements),
         :ok <- validate_shared_resources(snapshot, placements) do
      {:ok,
       %{
         placements: placements,
         result: result |> Map.drop(["objective"]) |> Map.put("assignment", assignment)
       }}
    end
  end

  defp validate_shared_resources(snapshot, placements) do
    conflicts =
      placements
      |> Enum.flat_map(
        &SharedResources.candidate_errors(snapshot.external, snapshot.plan.term, &1.session, &1)
      )
      |> Enum.uniq()

    if conflicts == [], do: :ok, else: {:error, %{errors: conflicts}}
  end

  defp parse_assignment(%{"unplaced" => unplaced} = result) when unplaced not in [[], nil] do
    {:error,
     errors(
       error("unplaced_sessions", "solver left required sessions unplaced", %{
         session_ids: Enum.map(unplaced, &to_string/1),
         solver_status: result["status"]
       })
     )}
  end

  defp parse_assignment(%{"assignment" => assignment}) when is_map(assignment) do
    assignment
    |> Enum.reduce_while({:ok, %{}}, fn {session_id, placement}, {:ok, parsed} ->
      with {:ok, session_id} <- cast_uuid(session_id, "session_id"),
           {:ok, placement} <- parse_placement(placement) do
        {:cont, {:ok, Map.put(parsed, session_id, placement)}}
      else
        {:error, message} -> {:halt, {:error, errors(error("invalid_solver_output", message))}}
      end
    end)
  end

  defp parse_assignment(_result),
    do: {:error, errors(error("invalid_solver_output", "solver did not return an assignment"))}

  defp parse_placement(placement) when is_map(placement) do
    with {:ok, room_id} <- cast_optional_uuid(field(placement, :room), "room"),
         {:ok, day} <- cast_positive_integer(field(placement, :day), "day"),
         {:ok, slot} <- cast_positive_integer(field(placement, :slot), "slot") do
      weeks = field(placement, :weeks)

      if is_nil(weeks) or
           (is_list(weeks) && weeks != [] && Enum.all?(weeks, &(is_integer(&1) && &1 > 0))) do
        {:ok,
         %{room: room_id, day: day, slot: slot}
         |> then(fn value -> if weeks, do: Map.put(value, :weeks, weeks), else: value end)}
      else
        {:error, "weeks must be a non-empty list of positive integers"}
      end
    end
  end

  defp parse_placement(_placement), do: {:error, "placement must be an object"}

  defp validate_session_ids(assignment, sessions) do
    expected = sessions |> Enum.map(& &1.id) |> MapSet.new()
    assigned = assignment |> Map.keys() |> MapSet.new()

    if expected == assigned do
      :ok
    else
      {:error,
       errors(
         error(
           "solver_assignment_mismatch",
           "solver assignment does not match the plan sessions",
           %{
             session_ids: MapSet.to_list(MapSet.symmetric_difference(expected, assigned))
           }
         )
       )}
    end
  end

  defp rooms_for_assignment(assignment, all_rooms) do
    room_ids =
      assignment |> Map.values() |> Enum.map(& &1.room) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    rooms = all_rooms |> Map.new(&{&1.id, &1}) |> Map.take(room_ids)

    if map_size(rooms) == length(room_ids) do
      {:ok, rooms}
    else
      {:error, errors(error("unknown_room", "solver assignment references an unknown room"))}
    end
  end

  defp build_placements(plan, sessions, rooms, assignment, fixed) do
    sessions_by_id = Map.new(sessions, &{&1.id, &1})

    placements =
      Enum.map(assignment, fn {session_id, placement} ->
        session = Map.fetch!(sessions_by_id, session_id)

        %Placement{
          id: session.id,
          plan_id: plan.id,
          term_id: plan.term_id,
          session_id: session.id,
          week_mask:
            if(session.automatic_weeks,
              do: Map.get(placement, :weeks, []),
              else: session.week_mask
            ),
          duration_slots: session.duration_slots,
          room_id: placement.room,
          day: placement.day,
          slot: placement.slot,
          locked: Map.has_key?(fixed, session_id),
          session: session,
          room: if(placement.room, do: Map.fetch!(rooms, placement.room), else: nil)
        }
      end)

    {:ok, placements}
  rescue
    KeyError ->
      {:error,
       errors(error("invalid_solver_output", "solver assignment references an unknown session"))}
  end

  defp validate_fixed_placements(placements, fixed) do
    placements_by_session = Map.new(placements, &{&1.session_id, &1})

    case Enum.find(fixed, fn {session_id, fixed_placement} ->
           placement = Map.get(placements_by_session, session_id)

           is_nil(placement) or placement.day != fixed_placement.day or
             placement.slot != fixed_placement.slot or placement.room_id != fixed_placement.room or
             (Map.has_key?(fixed_placement, :weeks) &&
                placement.week_mask != fixed_placement.weeks)
         end) do
      nil ->
        :ok

      {session_id, _fixed_placement} ->
        {:error,
         errors(
           error("locked_placement_moved", "solver moved a locked placement", %{
             session_ids: [session_id]
           })
         )}
    end
  end

  defp validate_hard_constraints(placements, grid) do
    case Hard.validate_placements(placements, grid) do
      :ok -> :ok
      {:error, errors} -> {:error, %{errors: errors}}
    end
  end

  defp cast_uuid(value, field_name) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "#{field_name} must be a UUID"}
    end
  end

  defp cast_uuid(_value, field_name), do: {:error, "#{field_name} must be a UUID"}

  defp cast_optional_uuid(nil, _field_name), do: {:ok, nil}
  defp cast_optional_uuid(value, field_name), do: cast_uuid(value, field_name)

  defp cast_positive_integer(value, _field_name) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp cast_positive_integer(value, field_name) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, "#{field_name} must be a positive integer"}
    end
  end

  defp cast_positive_integer(_value, field_name),
    do: {:error, "#{field_name} must be a positive integer"}

  defp error(type, message, extras \\ %{}),
    do: %{type: type, message: message} |> Map.merge(extras)

  defp errors(error), do: %{errors: [error]}
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
