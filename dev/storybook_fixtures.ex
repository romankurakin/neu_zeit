defmodule NeuZeitWeb.Storybook.Fixtures do
  use Gettext, backend: NeuZeitWeb.Gettext

  def sessions do
    for {weeks, index} <-
          Enum.with_index(
            [
              [1, 2, 3, 4, 5, 6, 7],
              Enum.to_list(1..15//2),
              [2, 4, 6, 8, 10, 12, 14],
              [1, 3, 8, 11]
            ],
            1
          ) do
      %{
        id: "demo-session-#{index}",
        week_mask: weeks,
        duration_slots: if(index == 1, do: 2, else: 1),
        course_component: %{
          kind: "lecture",
          course: %{
            code: "UX#{index}",
            title:
              "Einführung in die Betriebswirtschaftslehre und internationale Unternehmensführung"
          }
        },
        teacher: %{name: "Alexandra Marie Müller"},
        cohorts: [%{name: "WI-International-2026"}]
      }
    end
  end

  def placements do
    for {session, index} <- Enum.with_index(Enum.take(sessions(), 2)) do
      %{
        id: "demo-placement-#{index}",
        session: session,
        session_id: session.id,
        room: %{name: "Hauptgebäude, Raum 101"},
        week_mask: session.week_mask,
        duration_slots: session.duration_slots,
        day: 1,
        slot: 1 + index,
        locked: index == 1
      }
    end
  end

  def rows do
    [
      %{
        code: "INF110",
        kind: gettext("Lecture"),
        teacher: "Anna Weber",
        weeks: Enum.to_list(1..15),
        status: :ok
      },
      %{
        code: "INF110",
        kind: gettext("Lab"),
        teacher: "Erik Hoffmann",
        weeks: Enum.filter(1..15, &(rem(&1, 2) == 0)),
        status: :warning
      },
      %{
        code: "DEU100",
        kind: "Seminar",
        teacher: "Lch",
        weeks: Enum.to_list(1..7),
        status: :error
      }
    ]
  end
end
