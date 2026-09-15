defmodule NeuZeit.Catalog.TeacherAvailability do
  @moduledoc false
  alias NeuZeit.Catalog.ScheduleValidation
  alias NeuZeit.Catalog.WriteSupport
  import Ecto.Query, warn: false
  alias NeuZeit.Catalog.Session
  alias NeuZeit.Catalog.Teacher
  alias NeuZeit.Catalog.TeacherAvailabilityCell
  alias NeuZeit.Catalog.Term
  alias NeuZeit.Repo

  def list_teacher_availability(term_id, teacher_id) do
    Repo.all(
      from cell in TeacherAvailabilityCell,
        where: cell.term_id == ^term_id and cell.teacher_id == ^teacher_id,
        order_by: [asc: cell.day, asc: cell.slot]
    )
  end

  @doc """
  Atomically replaces a teacher's recurring weekly availability for one term.

  An empty cell list means unrestricted availability. Once at least one cell is
  present, every occupied slot of the teacher's sessions must be in the allow-list.
  Existing draft and active placements are revalidated before the change commits.
  """
  def replace_teacher_availability(term_id, teacher_id, cells) when is_list(cells) do
    WriteSupport.transaction_result(fn ->
      Repo.one!(from term in Term, where: term.id == ^term_id, lock: "FOR UPDATE")
      Repo.one!(from teacher in Teacher, where: teacher.id == ^teacher_id, lock: "FOR UPDATE")

      Repo.delete_all(
        from cell in TeacherAvailabilityCell,
          where: cell.term_id == ^term_id and cell.teacher_id == ^teacher_id
      )

      with :ok <- insert_teacher_availability(term_id, teacher_id, cells),
           :ok <- validate_teacher_availability_sessions(term_id, teacher_id),
           :ok <- ScheduleValidation.validate_teacher_availability_schedules(term_id, teacher_id),
           :ok <- ScheduleValidation.validate_active_projection(Repo, term_id) do
        {:ok, list_teacher_availability(term_id, teacher_id)}
      end
    end)
  end

  def replace_teacher_availability(_term_id, _teacher_id, _cells) do
    {:error,
     WriteSupport.error_changeset(
       %TeacherAvailabilityCell{},
       :availability,
       "cells must be a list of day/slot maps"
     )}
  end

  defp insert_teacher_availability(term_id, teacher_id, cells) do
    if Enum.all?(cells, &is_map/1) do
      cells
      |> Enum.uniq_by(fn cell ->
        {WriteSupport.attr(cell, :day), WriteSupport.attr(cell, :slot)}
      end)
      |> Enum.reduce_while(:ok, fn cell, _acc ->
        attrs = %{
          term_id: term_id,
          teacher_id: teacher_id,
          day: WriteSupport.attr(cell, :day),
          slot: WriteSupport.attr(cell, :slot)
        }

        case %TeacherAvailabilityCell{}
             |> TeacherAvailabilityCell.changeset(attrs)
             |> Repo.insert() do
          {:ok, _cell} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    else
      {:error,
       WriteSupport.error_changeset(
         %TeacherAvailabilityCell{},
         :availability,
         "each cell must be a day/slot map"
       )}
    end
  end

  defp validate_teacher_availability_sessions(term_id, teacher_id) do
    availability_cells = list_teacher_availability(term_id, teacher_id)

    invalid_session =
      Repo.all(
        from session in Session,
          where: session.term_id == ^term_id and session.teacher_id == ^teacher_id,
          preload: [slot_profile: [:cells]]
      )
      |> Enum.find(fn session ->
        profile_cells = if session.slot_profile, do: session.slot_profile.cells, else: nil

        not TeacherAvailabilityCell.schedulable?(
          availability_cells,
          profile_cells,
          session.duration_slots,
          NeuZeit.Config.grid!(term_id)
        )
      end)

    case invalid_session do
      nil ->
        :ok

      session ->
        {:error,
         WriteSupport.error_changeset(
           %TeacherAvailabilityCell{},
           :availability,
           "leaves no valid start for session #{session.id}"
         )}
    end
  end
end
