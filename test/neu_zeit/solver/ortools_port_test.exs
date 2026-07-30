defmodule NeuZeit.Solver.OrToolsPortTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NeuZeit.Solver.OrToolsPort

  describe "decode_output/1" do
    test "decodes a bare JSON result" do
      assert {:ok, %{"ok" => true, "status" => "OPTIMAL"}} =
               OrToolsPort.decode_output(~s({"ok":true,"status":"OPTIMAL"}\n))
    end

    test "tolerates uv/Python stderr noise around the JSON result" do
      output = """
      Installed 12 packages in 1.2s
      warning: `VIRTUAL_ENV` does not match the project environment path
      {"ok":true,"status":"OPTIMAL","assignment":{}}
      """

      assert {:ok, %{"ok" => true, "status" => "OPTIMAL"}} = OrToolsPort.decode_output(output)
    end

    test "returns solver error payloads as errors" do
      assert {:error, %{"ok" => false, "status" => "INFEASIBLE"}} =
               OrToolsPort.decode_output(~s({"ok":false,"status":"INFEASIBLE"}))
    end

    test "reports undecodable output as a protocol error with the raw output" do
      log =
        capture_log(fn ->
          assert {:error, %{"status" => "PROTOCOL_ERROR", "output" => "Traceback: boom"}} =
                   OrToolsPort.decode_output("Traceback: boom")
        end)

      assert log =~ "undecodable"
    end
  end

  test "runs the uv-managed solver contract" do
    spec = %{
      grid: %{days_count: 1, slots_per_day: 2},
      rooms: [%{id: "room-a", building_id: "main"}],
      sessions: [
        %{
          id: "s1",
          allowed_rooms: ["room-a"],
          weeks: [1, 2]
        },
        %{
          id: "s2",
          allowed_rooms: ["room-a"],
          weeks: [1]
        }
      ],
      fixed: %{},
      current: %{},
      hard: %{
        room_groups: [%{room_id: "room-a", session_ids: ["s1", "s2"]}],
        exclusive_groups: [%{session_ids: ["s1", "s2"]}]
      },
      soft: %{
        weights: %{building: 0, gaps: 0, sequence: 0, perturbation: 0},
        building_groups: [],
        gap_groups: [],
        sequence_pairs: []
      },
      requirements: %{all_sessions_placed: true},
      solver: %{time_limit: 1, gap: 0.01, workers: 1}
    }

    assert {:ok,
            %{
              "ok" => true,
              "status" => status,
              "backend" => "cp_sat",
              "unplaced" => [],
              "assignment" => assignment
            }} = OrToolsPort.solve(spec, timeout: 30_000)

    assert status in ["OPTIMAL", "FEASIBLE"]
    assert Map.keys(assignment) |> Enum.sort() == ["s1", "s2"]
    assert assignment["s1"]["room"] == "room-a"
    assert assignment["s2"]["room"] == "room-a"
    refute assignment["s1"]["slot"] == assignment["s2"]["slot"]
  end

  test "solver avoids days whose weeks collide with excluded dates" do
    spec = %{
      grid: %{days_count: 2, slots_per_day: 1},
      excluded_cells: [%{week: 1, day: 1}],
      rooms: [%{id: "room-a", building_id: "main"}],
      sessions: [%{id: "s1", allowed_rooms: ["room-a"], weeks: [1]}],
      fixed: %{},
      current: %{},
      hard: %{
        room_groups: [%{room_id: "room-a", session_ids: ["s1"]}],
        exclusive_groups: []
      },
      soft: %{
        weights: %{building: 0, gaps: 0, sequence: 0, perturbation: 0, excluded_days: 10},
        building_groups: [],
        gap_groups: [],
        sequence_pairs: []
      },
      requirements: %{all_sessions_placed: true},
      solver: %{time_limit: 1, gap: 0.0, workers: 1}
    }

    assert {:ok, %{"ok" => true, "status" => "OPTIMAL", "assignment" => assignment}} =
             OrToolsPort.solve(spec, timeout: 30_000)

    assert assignment["s1"]["day"] == 2
  end

  test "solver respects duration and allowed start cells" do
    spec = %{
      grid: %{days_count: 1, slots_per_day: 4},
      rooms: [%{id: "room-a", building_id: "main"}],
      sessions: [
        %{
          id: "long",
          allowed_rooms: ["room-a"],
          allowed_starts: [%{day: 1, slot: 1}],
          duration_slots: 2,
          weeks: [1]
        },
        %{
          id: "after",
          allowed_rooms: ["room-a"],
          allowed_starts: [%{day: 1, slot: 2}, %{day: 1, slot: 3}],
          duration_slots: 1,
          weeks: [1]
        }
      ],
      fixed: %{},
      current: %{},
      hard: %{
        room_groups: [%{room_id: "room-a", session_ids: ["long", "after"]}],
        exclusive_groups: []
      },
      soft: %{
        weights: %{
          building: 0,
          gaps: 0,
          sequence: 0,
          perturbation: 0,
          excluded_days: 0
        },
        building_groups: [],
        gap_groups: [],
        sequence_pairs: []
      },
      requirements: %{all_sessions_placed: true},
      solver: %{time_limit: 1, gap: 0.0, workers: 1}
    }

    assert {:ok, %{"status" => "OPTIMAL", "assignment" => assignment}} =
             OrToolsPort.solve(spec, timeout: 30_000)

    assert assignment["long"]["slot"] == 1
    assert assignment["after"]["slot"] == 3
  end

  test "solver minimizes active teaching days for a weekly resource group" do
    session_ids = ["s1", "s2", "s3"]

    spec = %{
      grid: %{days_count: 3, slots_per_day: 3},
      rooms: [%{id: "room-a", building_id: "main"}],
      sessions:
        Enum.map(session_ids, fn id ->
          %{id: id, allowed_rooms: ["room-a"], weeks: [1]}
        end),
      fixed: %{},
      current: %{},
      hard: %{
        room_groups: [%{room_id: "room-a", session_ids: session_ids}],
        exclusive_groups: [%{session_ids: session_ids}]
      },
      soft: %{
        weights: %{
          building: 0,
          gaps: 10,
          active_days: 10,
          sequence: 0,
          perturbation: 0,
          excluded_days: 0
        },
        building_groups: [],
        gap_groups: [%{week: 1, session_ids: session_ids}],
        active_day_groups: [%{week: 1, session_ids: session_ids}],
        sequence_pairs: []
      },
      requirements: %{all_sessions_placed: true},
      solver: %{time_limit: 1, gap: 0.0, workers: 1}
    }

    assert {:ok, %{"status" => "OPTIMAL", "assignment" => assignment}} =
             OrToolsPort.solve(spec, timeout: 30_000)

    assert assignment
           |> Map.values()
           |> Enum.map(& &1["day"])
           |> Enum.uniq()
           |> length() == 1
  end
end
