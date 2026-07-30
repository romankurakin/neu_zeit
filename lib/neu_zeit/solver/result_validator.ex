defmodule NeuZeit.Solver.ResultValidator do
  @moduledoc false

  import Ecto.Query, warn: false

  alias NeuZeit.Catalog.{Room, Session}
  alias NeuZeit.Constraints.Hard
  alias NeuZeit.Planning.{Placement, Plan}
  alias NeuZeit.Repo

  def validate(plan_id, spec, result) do
    with {:ok, assignment} <- parse_assignment(result),
         {:ok, plan} <- fetch_plan(plan_id),
         sessions <- sessions_for_term(plan.term_id),
         :ok <- validate_session_ids(assignment, sessions),
         {:ok, rooms} <- rooms_for_assignment(assignment),
         {:ok, placements} <- build_placements(plan, sessions, rooms, assignment, spec.fixed),
         :ok <- validate_fixed_placements(placements, spec.fixed),
         :ok <- validate_hard_constraints(placements) do
      {:ok,
       %{
         placements: placements,
         result: result |> Map.drop(["objective"]) |> Map.put("assignment", assignment)
       }}
    end
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
    with {:ok, room_id} <- cast_uuid(field(placement, :room), "room"),
         {:ok, day} <- cast_positive_integer(field(placement, :day), "day"),
         {:ok, slot} <- cast_positive_integer(field(placement, :slot), "slot") do
      {:ok, %{room: room_id, day: day, slot: slot}}
    end
  end

  defp parse_placement(_placement), do: {:error, "placement must be an object"}

  defp fetch_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      %Plan{} = plan -> {:ok, plan}
      nil -> {:error, errors(error("plan_not_found", "plan no longer exists"))}
    end
  end

  defp sessions_for_term(term_id) do
    Repo.all(
      from session in Session,
        where: session.term_id == ^term_id,
        preload: [
          :cohorts,
          teacher: [:availability_cells],
          slot_profile: [:cells],
          course_component: [:allowed_rooms]
        ]
    )
  end

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

  defp rooms_for_assignment(assignment) do
    room_ids = assignment |> Map.values() |> Enum.map(& &1.room) |> Enum.uniq()

    rooms =
      Repo.all(
        from room in Room,
          where: room.id in ^room_ids,
          preload: [:building]
      )
      |> Map.new(&{&1.id, &1})

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
          id: Ecto.UUID.generate(version: 7),
          plan_id: plan.id,
          term_id: plan.term_id,
          session_id: session.id,
          week_mask: session.week_mask,
          duration_slots: session.duration_slots,
          room_id: placement.room,
          day: placement.day,
          slot: placement.slot,
          locked: Map.has_key?(fixed, session_id),
          session: session,
          room: Map.fetch!(rooms, placement.room)
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
             placement.slot != fixed_placement.slot or placement.room_id != fixed_placement.room
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

  defp validate_hard_constraints(placements) do
    case Hard.validate_placements(placements) do
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
