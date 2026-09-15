defmodule NeuZeit.Scheduling.Defaults do
  @moduledoc """
  Default scheduling policy.

  Institution settings and each term grid are stored as domain data. These values initialize them.
  """

  def policy do
    %{
      institution: %{
        name: "DKU",
        timezone: "Asia/Almaty",
        default_locale: "en",
        supported_locales: ["de", "en", "ru"]
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
        balance_weeks: %{weight: 100},
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
