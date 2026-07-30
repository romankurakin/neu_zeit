defmodule NeuZeit.Scheduling.Defaults do
  @moduledoc """
  Default business policy for schedule generation.

  These values are product defaults, not deployment/runtime infrastructure
  settings. Future admin-facing configuration should persist and version this
  shape through the domain model instead of adding another file-based source.
  """

  def policy do
    %{
      institution: %{
        name: "DKU",
        timezone: "Asia/Almaty",
        default_locale: "de",
        supported_locales: ["de", "en", "ru"]
      },
      ects: %{
        hours_per_credit: 30,
        contact_ratio: 0.4,
        academic_hour_minutes: 45
      },
      grid: %{
        days: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        slots: [
          %{start: "08:00", end: "09:30"},
          %{start: "09:50", end: "11:20"},
          %{start: "12:20", end: "13:50"},
          %{start: "14:10", end: "15:40"},
          %{start: "16:00", end: "17:30"},
          %{start: "17:50", end: "19:20"}
        ]
      },
      soft: %{
        cluster_buildings: %{weight: 10},
        minimize_gaps: %{weight: 5},
        minimize_active_days: %{weight: 2},
        sequence_adjacency: %{weight: 8},
        minimal_perturbation: %{weight: 3},
        avoid_excluded_days: %{weight: 10}
      },
      solver: %{
        time_limit: 180,
        gap: 0.01,
        workers: 8,
        require_complete_solution: true
      }
    }
  end
end
