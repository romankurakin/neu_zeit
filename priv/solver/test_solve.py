"""Regression checks for the Python model and staged search."""

import time
import unittest
from unittest.mock import patch

import solve
from ortools.sat.python import cp_model


def small_spec(weeks=1):
    ids = ["a", "b"]
    groups = [{"week": week, "session_ids": ids} for week in range(1, weeks + 1)]
    return {
        "grid": {"days_count": 2, "slots_per_day": 3},
        "rooms": [{"id": "r", "building_id": "main"}],
        "sessions": [
            {"id": key, "allowed_rooms": ["r"], "weeks": list(range(1, weeks + 1))}
            for key in ids
        ],
        "fixed": {},
        "current": {},
        "hard": {
            "room_groups": [{"room_id": "r", "session_ids": ids}],
            "exclusive_groups": groups,
        },
        "soft": {
            "weights": {
                "building": 0,
                "gaps": 5,
                "active_days": 2,
                "sequence": 0,
                "perturbation": 0,
            },
            "building_groups": [],
            "gap_groups": groups,
            "active_day_groups": groups,
            "sequence_pairs": [],
        },
        "requirements": {"all_sessions_placed": True},
        "solver": {"time_limit": 2, "gap": 0, "workers": 1},
    }


class FixedSearch:
    """Run CP-SAT on a cloned model with a chosen valid assignment."""

    def __init__(self, starts):
        self.solver = cp_model.CpSolver()
        self.solver.parameters.num_search_workers = 1
        self.starts = starts

    def solve(self, model):
        model = model.clone()
        for index, var in enumerate(model.proto.variables):
            if var.name.startswith("x_"):
                _, session, start, _ = var.name.split("_")
                if int(start) == self.starts[session]:
                    model.add(model.get_bool_var_from_proto_index(index) == 1)
        return self.solver.solve(model)

    def __getattr__(self, name):
        return getattr(self.solver, name)


class SearchTests(unittest.TestCase):
    def test_failed_second_phase_keeps_full_cost_and_feasible_status(self):
        first = FixedSearch({"a": 0, "b": 1})
        failed = unittest.mock.Mock()
        failed.solve.return_value = cp_model.UNKNOWN
        with patch.object(solve, "configured_solver", side_effect=[first, failed]):
            result = solve.cp_sat_solve(small_spec(), time.monotonic())
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "FEASIBLE")
        self.assertEqual(result["objective"], 2)

    def test_second_phase_cannot_replace_incumbent_with_higher_total_cost(self):
        first = FixedSearch({"a": 0, "b": 1})
        worse = FixedSearch({"a": 0, "b": 3})
        with patch.object(solve, "configured_solver", side_effect=[first, worse]):
            result = solve.cp_sat_solve(small_spec(), time.monotonic())
        self.assertEqual(result["objective"], 2)
        self.assertEqual({p["day"] for p in result["assignment"].values()}, {1})

    def test_expired_budget_does_not_start_search(self):
        with patch.object(solve, "configured_solver") as configured:
            result = solve.cp_sat_solve(small_spec(), time.monotonic() - 3)
        configured.assert_not_called()
        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "UNKNOWN")

    def test_second_phase_is_skipped_when_the_shared_budget_is_used_up(self):
        first = FixedSearch({"a": 0, "b": 1})
        with patch.object(solve, "configured_solver", return_value=first) as configured:
            with patch.object(solve.time, "monotonic", side_effect=[0.0, 3.0, 3.0]):
                result = solve.cp_sat_solve(small_spec(), 0.0)
        self.assertEqual(configured.call_count, 1)
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], "FEASIBLE")
        self.assertEqual(result["objective"], 2)

    def test_week_repetition_preserves_cost_without_repeating_model(self):
        counts = []
        original = solve.configured_solver

        def recording(config, limit):
            solver = original(config, limit)
            run = solver.solve

            def measured(model):
                counts.append(
                    (len(model.proto.variables), len(model.proto.constraints))
                )
                return run(model)

            solver.solve = measured
            return solver

        with patch.object(solve, "configured_solver", side_effect=recording):
            once = solve.cp_sat_solve(small_spec(), time.monotonic())
        single = counts[0]
        counts.clear()
        with patch.object(solve, "configured_solver", side_effect=recording):
            repeated = solve.cp_sat_solve(small_spec(16), time.monotonic())
        self.assertEqual(repeated["objective"], once["objective"] * 16)
        self.assertEqual(counts[0], single)


class EnumerationTests(unittest.TestCase):
    def test_small_models_match_exhaustive_search(self):
        import itertools
        import random

        rng = random.Random(913)
        for case in range(32):
            with self.subTest(case=case):
                spec = small_spec(2)
                spec["rooms"].append({"id": "q", "building_id": "other"})
                sessions = []
                for key in ["a", "b", "c"]:
                    duration = rng.choice([1, 1, 2])
                    candidates = [
                        {"day": d, "slot": s}
                        for d in [1, 2]
                        for s in range(1, 5 - duration)
                    ]
                    sessions.append(
                        {
                            "id": key,
                            "allowed_rooms": rng.choice([["r"], ["q"], ["r", "q"]]),
                            "allowed_starts": rng.sample(
                                candidates, rng.randint(1, len(candidates))
                            ),
                            "duration_slots": duration,
                            "weeks": rng.choice([[1], [2], [1, 2]]),
                        }
                    )
                spec["sessions"] = sessions
                ids = [s["id"] for s in sessions]
                groups = [
                    {
                        "week": week,
                        "session_ids": [
                            s["id"] for s in sessions if week in s["weeks"]
                        ],
                    }
                    for week in [1, 2]
                ]
                spec["hard"] = {
                    "room_groups": [
                        {
                            "room_id": r,
                            "session_ids": [
                                s["id"] for s in sessions if r in s["allowed_rooms"]
                            ],
                        }
                        for r in ["r", "q"]
                    ],
                    "exclusive_groups": [{"session_ids": ids}],
                }
                spec["soft"].update(
                    building_groups=groups, gap_groups=groups, active_day_groups=groups
                )
                spec["soft"]["weights"].update(
                    building=2, gaps=3, active_days=0, excluded_days=4
                )
                spec["excluded_cells"] = [{"week": 1, "day": 1}]
                domains = [
                    [
                        (c["day"], c["slot"], room)
                        for c in s["allowed_starts"]
                        for room in s["allowed_rooms"]
                    ]
                    for s in sessions
                ]
                if case % 3 == 0:
                    day, slot, room = domains[0][0]
                    sessions[0]["blocked_assignments"] = [
                        {"day": day, "slot": slot, "room": room}
                    ]
                    domains[0] = domains[0][1:]
                if case % 5 == 0 and domains[1]:
                    day, slot, room = domains[1][0]
                    spec["fixed"] = {"b": {"day": day, "slot": slot, "room": room}}
                    domains[1] = domains[1][:1]
                best = None
                for positions in itertools.product(*domains):
                    conflict = False
                    for i, j in itertools.combinations(range(3), 2):
                        day, slot, _ = positions[i]
                        other_day, other_slot, _ = positions[j]
                        if (
                            day == other_day
                            and set(sessions[i]["weeks"]) & set(sessions[j]["weeks"])
                            and set(range(slot, slot + sessions[i]["duration_slots"]))
                            & set(
                                range(
                                    other_slot,
                                    other_slot + sessions[j]["duration_slots"],
                                )
                            )
                        ):
                            conflict = True
                            break
                    if conflict:
                        continue
                    cost = sum(
                        4
                        for s, p in zip(sessions, positions)
                        if 1 in s["weeks"] and p[0] == 1
                    )
                    for week in [1, 2]:
                        for day in [1, 2]:
                            active = [
                                (s, p)
                                for s, p in zip(sessions, positions)
                                if week in s["weeks"] and p[0] == day
                            ]
                            buildings = {p[2] for _, p in active}
                            cost += max(0, len(buildings) - 1) * 2
                            occupied = {
                                slot
                                for s, p in active
                                for slot in range(p[1], p[1] + s["duration_slots"])
                            }
                            if occupied:
                                cost += (
                                    max(occupied) - min(occupied) + 1 - len(occupied)
                                ) * 3
                    best = cost if best is None else min(best, cost)
                result = solve.cp_sat_solve(spec, time.monotonic())
                if best is None:
                    self.assertEqual(result["status"], "INFEASIBLE")
                else:
                    self.assertTrue(result["ok"])
                    self.assertEqual(result["objective"], best)


class QualityBenchmarkTests(unittest.TestCase):
    def test_reference_exposes_the_cost_of_prioritizing_existing_placements(self):
        from benchmark_quality import run

        spec = small_spec(16)
        spec["soft"]["weights"]["perturbation"] = 3
        # A teacher and a cohort attend the same two sessions for 16 weeks.
        spec["soft"]["gap_groups"] *= 2
        spec["soft"]["active_day_groups"] = spec["soft"]["gap_groups"]
        spec["current"] = {
            "a": {"day": 1, "slot": 1, "room": "r"},
            "b": {"day": 2, "slot": 1, "room": "r"},
        }
        result = run(spec, 2, reference=True)
        self.assertEqual(result["staged"]["objective"], 128)
        reference = result["weighted_reference"]
        # One move costs 3; one teaching day for each resource/week costs 64.
        self.assertEqual(reference["objective"], 67)
        self.assertEqual(reference["lower_bound"], 67)
        self.assertEqual(reference["metrics"]["weighted_cost"], 67)
        self.assertEqual(reference["metrics"]["gaps"], 0)

    def test_reference_does_not_double_count_days_in_single_stage_model(self):
        from benchmark_quality import run

        spec = small_spec()
        spec["soft"]["weights"]["gaps"] = 0
        result = run(spec, 2, reference=True)
        self.assertEqual(result["staged"]["objective"], 2)
        self.assertEqual(result["weighted_reference"]["objective"], 2)


if __name__ == "__main__":
    unittest.main()


class AutomaticWeeksTest(unittest.TestCase):
    def test_solver_selects_different_weeks_when_only_one_weekly_slot_is_available(
        self,
    ):
        spec = small_spec(weeks=2)
        for session in spec["sessions"]:
            session.update(
                choose_week=True,
                workload="seminars",
                allowed_starts=[{"day": 1, "slot": 1}],
            )
        result = solve.cp_sat_solve(spec, time.monotonic())
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            {tuple(value["weeks"]) for value in result["assignment"].values()},
            {(1,), (2,)},
        )

    def test_non_teaching_dates_and_external_bookings_restrict_only_their_week(self):
        spec = small_spec(weeks=3)
        for session in spec["sessions"]:
            session.update(
                choose_week=True,
                workload="seminars",
                allowed_starts=[{"day": 1, "slot": 1}],
            )
        spec["excluded_cells"] = [{"week": 1, "day": 1}]
        spec["sessions"][0]["blocked_assignments"] = [
            {"week": 2, "day": 1, "slot": 1, "room": "r"}
        ]
        result = solve.cp_sat_solve(spec, time.monotonic())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["assignment"]["a"]["weeks"], [3])
        self.assertEqual(result["assignment"]["b"]["weeks"], [2])

    def test_a_locked_meeting_keeps_its_week(self):
        spec = small_spec(weeks=3)
        for session in spec["sessions"]:
            session.update(
                choose_week=True,
                workload="seminars",
                allowed_starts=[{"day": 1, "slot": 1}],
            )
        spec["fixed"] = {"a": {"day": 1, "slot": 1, "room": "r", "weeks": [3]}}
        result = solve.cp_sat_solve(spec, time.monotonic())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["assignment"]["a"]["weeks"], [3])

    def test_generated_meetings_share_resources_with_recurring_sessions(self):
        spec = small_spec(weeks=2)
        spec["sessions"][0].update(weeks=[1], allowed_starts=[{"day": 1, "slot": 1}])
        spec["sessions"][1].update(
            choose_week=True, workload="lab", allowed_starts=[{"day": 1, "slot": 1}]
        )
        result = solve.cp_sat_solve(spec, time.monotonic())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["assignment"]["b"]["weeks"], [2])

    def test_regular_intervals_choose_parity_without_an_admin_preset(self):
        for blocked_week, expected in [(1, {2, 4}), (4, {1, 3})]:
            with self.subTest(blocked_week=blocked_week):
                spec = small_spec(weeks=4)
                for session in spec["sessions"]:
                    session.update(
                        choose_week=True,
                        workload="seminars",
                        allowed_starts=[{"day": 1, "slot": 1}],
                    )
                spec["excluded_cells"] = [{"week": blocked_week, "day": 1}]
                result = solve.cp_sat_solve(spec, time.monotonic())
                self.assertTrue(result["ok"], result)
                self.assertEqual(
                    {value["weeks"][0] for value in result["assignment"].values()},
                    expected,
                )

    def test_guest_teaching_stays_in_two_consecutive_eligible_weeks(self):
        spec = small_spec(weeks=8)
        for session in spec["sessions"]:
            session.update(
                choose_week=True,
                workload="guest",
                weeks=[3, 4],
                allowed_starts=[{"day": 1, "slot": 1}],
            )
        result = solve.cp_sat_solve(spec, time.monotonic())
        self.assertTrue(result["ok"], result)
        self.assertEqual(
            {value["weeks"][0] for value in result["assignment"].values()}, {3, 4}
        )
