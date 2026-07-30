defmodule NeuZeit.ConfigTest do
  use ExUnit.Case, async: true

  test "loads scheduling policy from code defaults" do
    assert %{
             institution: %{name: "DKU", default_locale: "de"},
             grid: %{days: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], slots: slots},
             solver: %{time_limit: 180, gap: 0.01, workers: 8, require_complete_solution: true}
           } = NeuZeit.Config.load!()

    assert length(slots) == 6
    assert NeuZeit.Constraints.Soft.weights().active_days == 2
  end

  test "soft weights are non-negative integers" do
    policy = NeuZeit.Scheduling.Defaults.policy()
    policy = put_in(policy, [:soft, :minimize_gaps, :weight], 2.5)

    assert_raise ArgumentError, "soft weights must be non-negative integers", fn ->
      NeuZeit.Config.validate!(policy)
    end
  end

  test "rejects an ects contact ratio outside (0, 1]" do
    policy = NeuZeit.Scheduling.Defaults.policy()
    policy = put_in(policy, [:ects, :contact_ratio], 1.5)

    assert_raise ArgumentError, "ects.contact_ratio must be in (0, 1]", fn ->
      NeuZeit.Config.validate!(policy)
    end
  end

  test "rejects overlapping canonical slots" do
    policy = NeuZeit.Scheduling.Defaults.policy()

    policy =
      put_in(policy, [:grid, :slots], [
        %{start: "08:00", end: "09:30"},
        %{start: "09:00", end: "10:30"}
      ])

    assert_raise ArgumentError,
                 "grid.slots must be valid, ordered, and non-overlapping",
                 fn -> NeuZeit.Config.validate!(policy) end
  end
end
