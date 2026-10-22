defmodule NeuZeit.Solver.Conflict do
  @moduledoc """
  Loads the records named by a solver conflict.

  When no timetable exists, the solver returns rules that cannot hold together
  for the listed sessions. Each rule is a record an administrator edits:
  a teacher's availability or load, a group's load, a time profile, the allowed
  rooms of a teaching type or a lock. Non-teaching dates and bookings in other
  terms apply to the whole term.
  """

  import Ecto.Query

  alias NeuZeit.Catalog.Session
  alias NeuZeit.Repo

  # Reading order: rules an administrator edits for one record come first.
  @kinds [
    :lock,
    :teacher_availability,
    :time_profile,
    :allowed_rooms,
    :teacher_load,
    :group_load,
    :non_teaching_dates,
    :other_terms
  ]
  @kind_names Map.new(@kinds, &{Atom.to_string(&1), &1})

  @doc """
  Returns the conflict rules with their records and sessions, or nil.

  Rules whose records no longer exist are left out.
  """
  def describe(_term_id, nil), do: nil

  def describe(term_id, %{"rules" => rules, "session_ids" => session_ids}) do
    sessions =
      Repo.all(
        from s in Session,
          where: s.term_id == ^term_id and s.id in ^session_ids,
          order_by: [asc: s.inserted_at, asc: s.id],
          preload: [
            :cohorts,
            teacher: [:availability_cells],
            slot_profile: [:cells],
            course_component: [
              :allowed_rooms,
              course: :translations,
              teaching_type: :translations
            ]
          ]
      )

    case Enum.flat_map(rules, &rule(&1, sessions, term_id)) do
      [] -> nil
      described -> %{rules: Enum.sort_by(described, &reading_order/1), sessions: sessions}
    end
  end

  def describe(_term_id, _conflict), do: nil

  defp rule(%{"kind" => kind, "id" => id, "session_ids" => ids}, sessions, term_id) do
    members = Enum.filter(sessions, &(&1.id in ids))

    with {:ok, kind} <- Map.fetch(@kind_names, kind),
         [_ | _] <- members,
         {:ok, fields} <- record(kind, id, members, term_id) do
      [Map.merge(%{kind: kind, sessions: members}, fields)]
    else
      _missing -> []
    end
  end

  defp rule(_rule, _sessions, _term_id), do: []

  defp record(:lock, id, members, _term_id), do: find(members, &(&1.id == id), :session)

  defp record(:teacher_availability, id, members, term_id) do
    with {:ok, %{teacher: teacher}} <- record(:teacher_load, id, members, term_id) do
      slots = Enum.count(teacher.availability_cells, &(&1.term_id == term_id))
      {:ok, %{teacher: teacher, slots: slots}}
    end
  end

  defp record(:teacher_load, id, members, _term_id),
    do: members |> Enum.map(& &1.teacher) |> find(&(&1.id == id), :teacher)

  defp record(:group_load, id, members, _term_id),
    do: members |> Enum.flat_map(& &1.cohorts) |> find(&(&1.id == id), :cohort)

  defp record(:time_profile, id, members, _term_id),
    do: members |> Enum.map(& &1.slot_profile) |> find(&(&1 && &1.id == id), :slot_profile)

  defp record(:allowed_rooms, id, members, _term_id),
    do: members |> Enum.map(& &1.course_component) |> find(&(&1.id == id), :course_component)

  defp record(_term_wide, _id, _members, _term_id), do: {:ok, %{}}

  defp reading_order(rule), do: Enum.find_index(@kinds, &(&1 == rule.kind))

  defp find(records, matches?, key) do
    case Enum.find(records, matches?) do
      nil -> :error
      record -> {:ok, %{key => record}}
    end
  end
end
