defmodule NeuZeit.Constraints.SoftTest do
  use ExUnit.Case, async: true

  alias NeuZeit.Constraints.Soft

  test "builds solver sequence pairs only for sessions with overlapping weeks" do
    sessions = [
      %{
        id: "first",
        teacher: "teacher-a",
        cohorts: ["cohort"],
        weeks: [1],
        sequence_group: "alternating"
      },
      %{
        id: "second",
        teacher: "teacher-a",
        cohorts: ["cohort"],
        weeks: [2],
        sequence_group: "alternating"
      },
      %{
        id: "third",
        teacher: "teacher-a",
        cohorts: ["cohort"],
        weeks: [1],
        sequence_group: "alternating"
      }
    ]

    assert %{
             building_groups: [
               %{week: 1, session_ids: ["first", "third"]},
               %{week: 1, session_ids: ["first", "third"]}
             ],
             gap_groups: [
               %{week: 1, session_ids: ["first", "third"]},
               %{week: 1, session_ids: ["first", "third"]}
             ],
             active_day_groups: [
               %{week: 1, session_ids: ["first", "third"]},
               %{week: 1, session_ids: ["first", "third"]}
             ],
             sequence_pairs: [%{left: "first", right: "third"}]
           } = Soft.solver_rules(sessions)
  end
end
