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


class WarmStartTests(unittest.TestCase):
    def seed(self, spec):
        grid = spec["grid"]
        sessions = solve.normalize_sessions(
            spec["sessions"], grid["days_count"], grid["slots_per_day"]
        )
        model = cp_model.CpModel()
        x = solve.AssignmentVariables(sessions)
        rooms = [str(room["id"]) for room in spec["rooms"]]
        for session in sessions:
            model.add(
                sum(solve.add_assignment_variables(model, x, session, rooms)) == 1
            )
        fixed = solve.normalize_placements(spec["fixed"], grid["slots_per_day"])
        current = solve.normalize_placements(spec["current"], grid["slots_per_day"])
        assignment = solve.greedy_assignment(spec, x, fixed, current)
        solve.add_assignment_hints(model, x, assignment, current)
        return assignment, model, x

    def validate(self, spec, assignment):
        from benchmark_quality import validate

        placements = {}
        for sid, (start, room, week) in assignment.items():
            placement = solve.slot_to_day_slot(
                start, spec["grid"]["slots_per_day"], room
            )
            if week is not None:
                placement["weeks"] = [week]
            placements[sid] = placement
        validate(spec, placements)

    def test_complete_seed_preserves_locks_current_and_duration(self):
        spec = small_spec(2)
        spec["soft"]["weights"]["perturbation"] = 5
        spec["sessions"][0]["duration_slots"] = 2
        spec["fixed"] = {"b": {"day": 1, "slot": 1, "room": "r"}}
        spec["current"] = {
            "a": {"day": 2, "slot": 2, "room": "r"},
            "b": {"day": 2, "slot": 1, "room": "r"},
        }

        assignment, model, x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment, {"b": (0, "r", None), "a": (4, "r", None)})
        self.assertEqual(len(model.proto.solution_hint.vars), len(x))
        self.assertEqual(sum(model.proto.solution_hint.values), 2)
        self.assertEqual(self.seed(spec)[0], assignment)

    def test_week_choices_obey_bookings_dates_and_recurring_occupancy(self):
        spec = small_spec()
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}
        spec["sessions"][0].update(
            choose_week=True,
            weeks=[1, 2, 3, 4],
            blocked_assignments=[{"day": 1, "slot": 1, "room": "r", "week": 3}],
        )
        spec["fixed"] = {"b": {"day": 1, "slot": 1, "room": "r"}}
        spec["current"] = {"a": {"day": 1, "slot": 1, "room": "r", "weeks": [2]}}
        spec["excluded_cells"] = [{"week": 2, "day": 1}]

        assignment, model, x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["a"], (0, "r", 4))
        self.assertEqual(len(model.proto.solution_hint.vars), len(x) + len(x.weekly))
        self.assertEqual(sum(model.proto.solution_hint.values), 3)

    def test_duration_conflict_moves_a_current_placement(self):
        spec = small_spec()
        spec["sessions"][0]["duration_slots"] = 2
        spec["fixed"] = {"a": {"day": 1, "slot": 1, "room": "r"}}
        spec["current"] = {"b": {"day": 1, "slot": 2, "room": "r"}}

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (2, "r", None))

    def test_fewer_choices_take_priority_over_session_id(self):
        spec = small_spec()
        spec["sessions"][1]["allowed_starts"] = [{"day": 1, "slot": 1}]

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment, {"b": (0, "r", None), "a": (1, "r", None)})

    def test_movable_lock_keeps_its_week_and_current_week_is_preferred(self):
        spec = small_spec(2)
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}
        for session in spec["sessions"]:
            session["choose_week"] = True
        spec["fixed"] = {"b": {"day": 1, "slot": 1, "room": "r", "weeks": [2]}}
        spec["current"] = {"a": {"day": 1, "slot": 1, "room": "r", "weeks": [1]}}

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment, {"b": (0, "r", 2), "a": (0, "r", 1)})

    def test_online_sessions_share_a_cell_only_without_exclusive_groups(self):
        spec = small_spec()
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}
        for session in spec["sessions"]:
            session.update(delivery_mode="online", allowed_rooms=[])
        assignment, _model, _x = self.seed(spec)
        self.assertEqual(len(assignment), 1)

        spec["hard"]["exclusive_groups"] = []
        assignment, _model, _x = self.seed(spec)
        self.validate(spec, assignment)
        self.assertEqual(assignment, {"a": (0, None, None), "b": (0, None, None)})

    def test_partial_seed_leaves_unplaced_sessions_without_zero_hints(self):
        spec = small_spec()
        spec["sessions"][1]["blocked_assignments"] = [
            {"day": day, "slot": slot, "room": "r"}
            for day in (1, 2)
            for slot in (1, 2, 3)
        ]

        assignment, model, x = self.seed(spec)

        self.assertEqual(set(assignment), {"a"})
        hints = dict(
            zip(model.proto.solution_hint.vars, model.proto.solution_hint.values)
        )
        self.assertEqual(
            set(hints), {var.index for (sid, _, _), var in x.items() if sid == "a"}
        )
        self.assertEqual(sum(hints.values()), 1)

    def test_empty_seed_retains_current_hints_and_the_stage_one_model(self):
        spec = small_spec()
        spec["current"] = {"a": {"day": 2, "slot": 1, "room": "r"}}
        models = []
        limits = []
        original = solve.configured_solver

        def recording(config, limit):
            solver = original(config, limit)
            run = solver.solve

            def measured(model):
                models.append(model.clone())
                limits.append(solver.parameters.hint_conflict_limit)
                return run(model)

            solver.solve = measured
            return solver

        with patch.object(solve, "configured_solver", side_effect=recording):
            solve.cp_sat_solve(spec, time.monotonic())
        seeded = models[0]
        self.assertEqual(limits[0], 1000)
        models.clear()
        limits.clear()
        with (
            patch.object(solve, "greedy_assignment", return_value={}),
            patch.object(solve, "configured_solver", side_effect=recording),
        ):
            result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertTrue(result["ok"], result)
        self.assertEqual(limits[0], cp_model.CpSolver().parameters.hint_conflict_limit)
        unseeded = models[0]
        hint = unseeded.proto.solution_hint
        self.assertEqual(list(hint.values), [1])
        self.assertEqual(unseeded.proto.variables[hint.vars[0]].name, "x_a_3_r")
        seeded.clear_hints()
        unseeded.clear_hints()
        self.assertEqual(str(seeded.proto), str(unseeded.proto))

    def test_stage_one_can_improve_a_complete_seed(self):
        with patch.object(
            solve,
            "greedy_assignment",
            return_value={"a": (0, "r", None), "b": (2, "r", None)},
        ):
            result = solve.cp_sat_solve(small_spec(), time.monotonic())

        self.assertTrue(result["ok"], result)
        self.assertEqual(result["objective"], 2)

    def test_empty_seed_keeps_the_unknown_retry_and_stage_two(self):
        first = unittest.mock.Mock()
        first.solve.return_value = cp_model.UNKNOWN
        retry = FixedSearch({"a": 0, "b": 1})
        compact = FixedSearch({"a": 0, "b": 1})
        with (
            patch.object(solve, "greedy_assignment", return_value={}),
            patch.object(
                solve, "configured_solver", side_effect=[first, retry, compact]
            ) as configured,
        ):
            result = solve.cp_sat_solve(small_spec(), time.monotonic())

        self.assertEqual(configured.call_count, 3)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["objective"], 2)

    def test_complete_current_keeps_its_existing_hints(self):
        spec = small_spec()
        spec["current"] = {
            "b": {"day": 1, "slot": 2, "room": "r"},
            "a": {"day": 1, "slot": 1, "room": "r"},
        }
        hints = []
        original = solve.configured_solver

        def recording(config, limit):
            solver = original(config, limit)
            run = solver.solve

            def measured(model):
                hints.append(
                    [
                        (model.proto.variables[index].name, value)
                        for index, value in zip(
                            model.proto.solution_hint.vars,
                            model.proto.solution_hint.values,
                        )
                    ]
                )
                return run(model)

            solver.solve = measured
            return solver

        with (
            patch.object(solve, "greedy_assignment") as greedy,
            patch.object(solve, "configured_solver", side_effect=recording),
        ):
            result = solve.cp_sat_solve(spec, time.monotonic())

        greedy.assert_not_called()
        self.assertTrue(result["ok"], result)
        self.assertEqual(hints[0], [("x_b_1_r", 1), ("x_a_0_r", 1)])

    def test_cheapest_cell_joins_a_day_without_a_gap(self):
        spec = small_spec()
        spec["fixed"] = {"a": {"day": 2, "slot": 3, "room": "r"}}
        spec["sessions"][1]["allowed_starts"] = [
            {"day": 1, "slot": 1},
            {"day": 2, "slot": 1},
            {"day": 2, "slot": 2},
        ]

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (4, "r", None))

    def test_cheapest_room_keeps_the_groups_building(self):
        spec = small_spec()
        spec["rooms"].append({"id": "annex", "building_id": "annex"})
        spec["sessions"][1].update(
            allowed_rooms=["annex", "r"], allowed_starts=[{"day": 1, "slot": 2}]
        )
        spec["fixed"] = {"a": {"day": 1, "slot": 1, "room": "r"}}
        spec["soft"]["building_groups"] = spec["soft"]["gap_groups"]
        spec["soft"]["weights"]["building"] = 10

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (1, "r", None))

    def test_repeated_week_cost_can_outweigh_perturbation(self):
        for weeks, expected in [(1, 0), (2, 4)]:
            with self.subTest(weeks=weeks):
                spec = small_spec(weeks)
                spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r"}}
                spec["current"] = {"b": {"day": 1, "slot": 1, "room": "r"}}
                spec["soft"]["weights"]["perturbation"] = 3

                assignment, _model, _x = self.seed(spec)

                self.validate(spec, assignment)
                self.assertEqual(assignment["b"], (expected, "r", None))

    def test_sequence_uses_the_partners_duration(self):
        spec = small_spec()
        spec["sessions"][0]["duration_slots"] = 2
        spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r"}}
        spec["soft"]["weights"].update(gaps=0, active_days=0, sequence=8)
        spec["soft"]["sequence_pairs"] = [{"left": "a", "right": "b"}]

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (5, "r", None))

    def test_recurring_meeting_avoids_excluded_days(self):
        spec = small_spec(2)
        spec["fixed"] = {"a": {"day": 1, "slot": 1, "room": "r"}}
        spec["excluded_cells"] = [{"week": 1, "day": 1}, {"week": 2, "day": 1}]
        spec["soft"]["weights"]["excluded_days"] = 10

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (3, "r", None))

    def test_movable_meetings_only_join_their_chosen_weeks_groups(self):
        spec = small_spec(2)
        for session in spec["sessions"]:
            session["choose_week"] = True
        spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r", "weeks": [2]}}

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (4, "r", 2))

    def test_weekly_balance_reuses_a_position_in_another_week(self):
        spec = small_spec(2)
        for session in spec["sessions"]:
            session.update(choose_week=True, workload="course")
        spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r", "weeks": [1]}}

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (3, "r", 2))

    def test_active_days_default_to_gap_groups_and_ignore_singletons(self):
        spec = small_spec()
        del spec["soft"]["active_day_groups"]
        spec["soft"]["gap_groups"].append({"week": 1, "session_ids": ["b"]})
        spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r"}}

        assignment, _model, x = self.seed(spec)
        costs = solve.GreedyCosts(spec, x, {})

        self.assertEqual(assignment["b"], (4, "r", None))
        self.assertEqual(costs.delta("b", 0, "r", None), 2)

    def test_zero_weights_keep_the_first_free_candidate(self):
        spec = small_spec()
        spec["soft"]["weights"] = {key: 0 for key in spec["soft"]["weights"]}
        spec["fixed"] = {"a": {"day": 2, "slot": 1, "room": "r"}}

        assignment, _model, _x = self.seed(spec)

        self.validate(spec, assignment)
        self.assertEqual(assignment["b"], (0, "r", None))

    def test_workload_increment_matches_balance_intervals_and_positions(self):
        spec = small_spec(5)
        for session in spec["sessions"]:
            session.update(choose_week=True, workload="course")
        spec["soft"]["weights"] = {key: 0 for key in spec["soft"]["weights"]}
        _assignment, model, x = self.seed(spec)
        costs = solve.GreedyCosts(spec, x, {})
        cells = {"a": (0, "r", 2), "b": (0, "r", 4)}
        # Empty weeks and four two-week windows each start below their target.
        total = 100 * (5 * 2 + 4 * 4)
        for sid, cell in cells.items():
            total += costs.delta(sid, *cell)
            costs.place(sid, *cell)
        terms = solve.automatic_workload_terms(
            model, x, list(x.sessions.values()), 100, set()
        )
        for key, variable in x.weekly.items():
            model.add(variable == int(key[1:] == cells[key[0]]))
        model.minimize(sum(terms))
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1

        status = solver.solve(model)

        self.assertEqual(status, cp_model.OPTIMAL)
        self.assertEqual(total, solver.objective_value)

    def test_incremental_group_costs_match_complete_weekly_metrics(self):
        from benchmark_quality import metrics

        spec = small_spec(2)
        spec["rooms"].append({"id": "annex", "building_id": "annex"})
        for session in spec["sessions"]:
            session.update(choose_week=True, allowed_rooms=["r", "annex"])
        spec["sessions"].append({"id": "c", "weeks": [1, 2], "allowed_rooms": ["r"]})
        for group in spec["soft"]["gap_groups"]:
            group["session_ids"] = ["a", "b", "c"]
        spec["soft"]["building_groups"] = spec["soft"]["gap_groups"]
        spec["soft"]["weights"].update(
            building=10, sequence=8, perturbation=3, excluded_days=10
        )
        spec["soft"]["sequence_pairs"] = [{"left": "a", "right": "c"}]
        spec["current"] = {"b": {"day": 2, "slot": 1, "room": "r", "weeks": [1]}}
        spec["excluded_cells"] = [{"week": 2, "day": 1}]
        _assignment, _model, x = self.seed(spec)
        current = solve.normalize_placements(spec["current"], 3)
        costs = solve.GreedyCosts(spec, x, current)
        cells = {"a": (0, "r", 1), "b": (4, "annex", 2), "c": (2, "r", None)}
        total, placements = 0, {}
        for sid, (start, room, week) in cells.items():
            total += costs.delta(sid, start, room, week)
            costs.place(sid, start, room, week)
            placements[sid] = solve.slot_to_day_slot(start, 3, room)
            if week is not None:
                placements[sid]["weeks"] = [week]
        self.validate(spec, cells)

        # Each one-meeting workload has unchanged balance and one used position.
        self.assertEqual(total - 2, metrics(spec, placements)["weighted_cost"])


class SearchTests(unittest.TestCase):
    def test_online_sessions_share_a_time_without_a_fictitious_room_conflict(self):
        spec = small_spec()
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}
        for session in spec["sessions"]:
            session.update(delivery_mode="online", allowed_rooms=[])
        spec["hard"]["exclusive_groups"] = []

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertTrue(result["ok"], result)
        self.assertEqual(
            {assignment["room"] for assignment in result["assignment"].values()},
            {None},
        )
        self.assertEqual(
            {(assignment["day"], assignment["slot"]) for assignment in result["assignment"].values()},
            {(1, 1)},
        )

    def test_online_sessions_still_obey_teacher_and_cohort_exclusivity(self):
        spec = small_spec()
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}
        for session in spec["sessions"]:
            session.update(delivery_mode="online", allowed_rooms=[])
        spec["hard"]["room_groups"] = []

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertFalse(result["ok"])
        self.assertEqual(result["status"], "INFEASIBLE")

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

    def test_second_phase_cannot_trade_base_cost_for_fewer_active_days(self):
        spec = small_spec()
        spec["soft"]["weights"]["active_days"] = 10
        first = FixedSearch({"a": 0, "b": 3})
        higher_base = FixedSearch({"a": 0, "b": 2})
        with patch.object(solve, "configured_solver", side_effect=[first, higher_base]):
            result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertEqual(result["objective"], 20)
        self.assertEqual({p["day"] for p in result["assignment"].values()}, {1, 2})

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

    def test_a_movable_meeting_elsewhere_keeps_other_weeks_shared(self):
        def with_generated_meeting(weeks):
            spec = small_spec(weeks)
            spec["rooms"].append({"id": "lab", "building_id": "main"})
            spec["sessions"].append(
                {
                    "id": "c",
                    "allowed_rooms": ["lab"],
                    "weeks": [1],
                    "choose_week": True,
                    "workload": "lab",
                    "allowed_starts": [{"day": 1, "slot": 1}],
                }
            )
            return spec

        counts = []
        original = solve.configured_solver

        def recording(config, limit):
            solver = original(config, limit)
            run = solver.solve

            def measured(model):
                counts.append(len(model.proto.variables))
                return run(model)

            solver.solve = measured
            return solver

        with patch.object(solve, "configured_solver", side_effect=recording):
            once = solve.cp_sat_solve(small_spec(), time.monotonic())
            counts.clear()
            single = solve.cp_sat_solve(with_generated_meeting(1), time.monotonic())
            single_variables = counts[0]
            counts.clear()
            repeated = solve.cp_sat_solve(with_generated_meeting(16), time.monotonic())
        # The generated meeting's only cost is its one recurring position.
        self.assertEqual(single["objective"], once["objective"] + 1)
        self.assertEqual(repeated["objective"], once["objective"] * 16 + 1)
        self.assertEqual(counts[0], single_variables)

    def test_weeks_with_a_movable_meeting_keep_their_own_expression(self):
        sessions = solve.normalize_sessions(
            [
                {"id": "a", "allowed_rooms": ["r"], "weeks": [1, 2, 3]},
                {"id": "b", "allowed_rooms": ["r"], "weeks": [1, 2, 3]},
                {
                    "id": "c",
                    "allowed_rooms": ["r"],
                    "weeks": [1, 2],
                    "choose_week": True,
                },
            ],
            1,
            2,
        )
        x = solve.AssignmentVariables(sessions)
        model = cp_model.CpModel()
        for session in sessions:
            solve.add_assignment_variables(model, x, session, ["r"])
        groups = [{"week": week, "session_ids": ["a", "b"]} for week in (1, 2, 3)]
        groups += [{"week": week, "session_ids": ["a", "c"]} for week in (1, 2)]

        shared = solve.weekly_group_variables(x, groups)

        self.assertEqual(
            [(ids, count) for _variables, ids, count in shared],
            [(("a", "b"), 3), (("a", "c"), 1), (("a", "c"), 1)],
        )
        self.assertIs(shared[0][0], x)
        self.assertEqual(
            [variables[("c", 0, "r")] for variables, _ids, _count in shared[1:]],
            [x.weekly[("c", 0, "r", 1)], x.weekly[("c", 0, "r", 2)]],
        )


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


def overloaded_teacher_spec(available_slots=2):
    """Teacher t teaches a, b and c but is available only in the first slots of day 1."""
    spec = small_spec()
    available = [{"day": 1, "slot": slot} for slot in range(1, available_slots + 1)]
    spec["rooms"].append({"id": "q", "building_id": "main"})
    spec["sessions"] = [
        {
            "id": key,
            "teacher": teacher,
            "cohorts": [cohort],
            "allowed_rooms": ["r", "q"],
            "weeks": [1],
            **({"allowed_starts": available} if teacher == "t" else {}),
        }
        for key, teacher, cohort in [
            ("a", "t", "g"),
            ("b", "t", "g"),
            ("c", "t", "h"),
            ("d", "u", "h"),
        ]
    ]
    ids = ["a", "b", "c", "d"]
    spec["hard"] = {
        "room_groups": [{"room_id": room, "session_ids": ids} for room in ("r", "q")],
        "exclusive_groups": [
            {"session_ids": ["a", "b", "c"]},
            {"session_ids": ["a", "b"]},
            {"session_ids": ["c", "d"]},
        ],
    }
    spec["soft"]["gap_groups"] = spec["soft"]["active_day_groups"] = []
    spec["explanation"] = {
        "rules": [
            {
                "kind": "teacher_availability",
                "id": "t",
                "session_ids": ["a", "b", "c"],
                "cells": available,
            },
            {"kind": "teacher_load", "id": "t", "session_ids": ["a", "b", "c"]},
            {"kind": "group_load", "id": "g", "session_ids": ["a", "b"]},
            {"kind": "group_load", "id": "h", "session_ids": ["c", "d"]},
        ]
    }
    return spec


def teacher_and_group_spec():
    """Locked a and c take both slots. Teacher t shares b with a, group g shares b with c."""
    spec = small_spec()
    spec["grid"] = {"days_count": 1, "slots_per_day": 2}
    spec["rooms"] = [{"id": room, "building_id": "main"} for room in "rst"]
    spec["sessions"] = [
        {"id": key, "allowed_rooms": [room], "weeks": [1]}
        for key, room in [("a", "r"), ("b", "s"), ("c", "t")]
    ]
    spec["fixed"] = {
        "a": {"day": 1, "slot": 1, "room": "r"},
        "c": {"day": 1, "slot": 2, "room": "t"},
    }
    spec["hard"] = {
        "room_groups": [],
        "exclusive_groups": [
            {"session_ids": ["a", "b"]},
            {"session_ids": ["b", "c"]},
        ],
    }
    spec["soft"]["gap_groups"] = spec["soft"]["active_day_groups"] = []
    spec["explanation"] = {
        "rules": [
            {"kind": "teacher_load", "id": "t", "session_ids": ["a", "b"]},
            {"kind": "group_load", "id": "g", "session_ids": ["b", "c"]},
        ]
    }
    return spec


def evening_cohort_spec():
    """Group g has a, b and c in two evening slots. Another term books the second
    slot for a and b, so a and b alone conflict with that booking too."""
    spec = small_spec()
    spec["grid"] = {"days_count": 1, "slots_per_day": 3}
    spec["rooms"] = [{"id": room, "building_id": "main"} for room in "rst"]
    evening = [{"day": 1, "slot": slot} for slot in (1, 2)]
    spec["sessions"] = [
        {
            "id": key,
            "allowed_rooms": [room],
            "allowed_starts": evening,
            "weeks": [1],
            "blocked_assignments": [{"day": 1, "slot": 2, "room": room}]
            if key != "c"
            else [],
        }
        for key, room in [("a", "r"), ("b", "s"), ("c", "t")]
    ]
    spec["hard"] = {
        "room_groups": [],
        "exclusive_groups": [{"session_ids": ["a", "b", "c"]}],
    }
    spec["soft"]["gap_groups"] = spec["soft"]["active_day_groups"] = []
    spec["explanation"] = {
        "rules": [
            {"kind": "group_load", "id": "g", "session_ids": ["a", "b", "c"]},
            {
                "kind": "time_profile",
                "id": "p",
                "session_ids": ["a", "b", "c"],
                "starts": evening,
            },
        ]
    }
    return spec


class ConflictExplanationTest(unittest.TestCase):
    def test_teacher_with_less_availability_than_load_is_named_with_their_sessions(
        self,
    ):
        result = solve.cp_sat_solve(overloaded_teacher_spec(), time.monotonic())

        self.assertEqual(result["status"], "INFEASIBLE")
        self.assertEqual(
            result["conflict"],
            {
                "minimal": True,
                "rules": [
                    {"kind": "teacher_load", "id": "t", "session_ids": ["a", "b", "c"]},
                    {
                        "kind": "teacher_availability",
                        "id": "t",
                        "session_ids": ["a", "b", "c"],
                    },
                ],
                "session_ids": ["a", "b", "c"],
            },
        )

    def test_guarded_model_with_every_rule_allows_the_main_model_placements(self):
        for available_slots, expected in [
            (2, cp_model.INFEASIBLE),
            (3, cp_model.OPTIMAL),
        ]:
            with self.subTest(available_slots=available_slots):
                spec = overloaded_teacher_spec(available_slots)
                model, rules, placed = solve.conflict_model(spec)
                model.add_assumptions(
                    [rule["literal"] for rule in rules] + list(placed.values())
                )
                solver = cp_model.CpSolver()
                solver.parameters.num_search_workers = 1
                self.assertEqual(solver.solve(model), expected)
                self.assertEqual(
                    solve.cp_sat_solve(spec, time.monotonic())["ok"],
                    expected == cp_model.OPTIMAL,
                )

    def test_two_locks_in_one_room_conflict_without_the_teacher_load(self):
        spec = small_spec()
        for session in spec["sessions"]:
            session.update(teacher="t", cohorts=[])
        spec["fixed"] = {
            "a": {"day": 1, "slot": 1, "room": "r"},
            "b": {"day": 1, "slot": 1, "room": "r"},
        }
        spec["explanation"] = {
            "rules": [{"kind": "teacher_load", "id": "t", "session_ids": ["a", "b"]}]
        }

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertEqual(
            result["conflict"]["rules"],
            [
                {"kind": "lock", "id": "a", "session_ids": ["a"]},
                {"kind": "lock", "id": "b", "session_ids": ["b"]},
            ],
        )

    def test_single_allowed_room_is_named_when_it_cannot_hold_the_sessions(self):
        spec = small_spec()
        ids = [f"s{index}" for index in range(7)]
        spec["rooms"].append({"id": "q", "building_id": "main"})
        spec["sessions"] = [
            {"id": key, "allowed_rooms": ["r"], "weeks": [1]} for key in ids
        ]
        spec["hard"] = {
            "room_groups": [{"room_id": "r", "session_ids": ids}],
            "exclusive_groups": [],
        }
        spec["soft"]["gap_groups"] = spec["soft"]["active_day_groups"] = []
        spec["explanation"] = {
            "rules": [{"kind": "allowed_rooms", "id": "lab", "session_ids": ids}]
        }

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertEqual(
            result["conflict"]["rules"],
            [{"kind": "allowed_rooms", "id": "lab", "session_ids": ids}],
        )

    def test_forced_room_overlap_is_located_before_building_large_sets(self):
        spec = small_spec()
        spec["sessions"].append({"id": "c", "allowed_rooms": ["r"], "weeks": [1]})
        spec["hard"]["room_groups"][0]["session_ids"].append("c")
        spec["hard"]["exclusive_groups"] = []
        spec["fixed"] = {key: {"day": 1, "slot": 1, "room": "r"} for key in ("a", "b")}
        spec["sessions"][0]["duration_slots"] = 2
        spec["fixed"]["b"]["slot"] = 2
        spec["explanation"] = {"rules": []}

        with patch.object(
            solve, "locate_conflict", wraps=solve.locate_conflict
        ) as locate:
            conflict = solve.explain_infeasibility(spec, time.monotonic() + 5, 60)

        self.assertEqual(locate.call_count, 1)
        self.assertEqual(locate.call_args.args[1], ("a", "b"))
        self.assertTrue(conflict["minimal"])
        self.assertEqual(conflict["session_ids"], ["a", "b"])
        self.assertEqual(
            [(rule["kind"], rule["id"]) for rule in conflict["rules"]],
            [("lock", "a"), ("lock", "b")],
        )

    def test_forced_room_candidates_share_a_week(self):
        spec = small_spec(weeks=2)
        for week, session in enumerate(spec["sessions"], 1):
            session.update(weeks=[week], allowed_starts=[{"day": 1, "slot": 1}])
        spec["explanation"] = {"rules": []}

        self.assertEqual(
            list(solve.forced_conflict_candidates(spec, time.monotonic() + 5)), []
        )
        spec["sessions"][1]["weeks"] = [1, 2]
        self.assertEqual(
            list(solve.forced_conflict_candidates(spec, time.monotonic() + 5)),
            [("a", "b")],
        )

    def test_empty_domain_checks_every_room_and_week(self):
        spec = small_spec()
        spec["rooms"].append({"id": "q", "building_id": "main"})
        spec["sessions"] = [spec["sessions"][0]]
        session = spec["sessions"][0]
        session.update(
            allowed_starts=[{"day": 1, "slot": 1}],
            allowed_rooms=["r", "q"],
            choose_week=True,
            weeks=[1, 2],
            blocked_assignments=[{"day": 1, "slot": 1, "room": "r", "week": 2}],
        )
        spec["excluded_cells"] = [{"week": 1, "day": 1}]
        self.assertEqual(
            list(solve.forced_conflict_candidates(spec, time.monotonic() + 5)), []
        )
        session["blocked_assignments"].append(
            {"day": 1, "slot": 1, "room": "q", "week": 2}
        )
        self.assertEqual(
            list(solve.forced_conflict_candidates(spec, time.monotonic() + 5)),
            [("a",)],
        )
        # Recurring sessions keep their start on non-teaching dates, and only
        # bookings without a week restrict their recurring assignment.
        session["choose_week"] = False
        self.assertEqual(
            list(solve.forced_conflict_candidates(spec, time.monotonic() + 5)), []
        )

    def test_other_sessions_of_the_rules_can_drop_a_rule(self):
        spec = evening_cohort_spec()
        located = {("group_load", "g"), ("other_terms", None)}

        conflict = solve.explain_sessions(
            spec, ["a", "b"], located, time.monotonic() + 10
        )

        self.assertEqual(
            [(rule["kind"], rule["id"]) for rule in conflict["rules"]],
            [("group_load", "g"), ("time_profile", "p")],
        )
        self.assertEqual(conflict["session_ids"], ["a", "b", "c"])
        self.assertTrue(conflict["minimal"])

    def test_conflict_stays_when_wider_sessions_clash_without_rules(self):
        narrow = solve.ConflictSearch.minimal_rules

        def rule_free_when_wide(search, candidate):
            return set() if len(search.placed) > 2 else narrow(search, candidate)

        with patch.object(solve.ConflictSearch, "minimal_rules", rule_free_when_wide):
            conflict = solve.explain_sessions(
                evening_cohort_spec(),
                ["a", "b"],
                {("group_load", "g"), ("other_terms", None)},
                time.monotonic() + 10,
            )

        self.assertEqual(
            [(rule["kind"], rule["id"]) for rule in conflict["rules"]],
            [("group_load", "g"), ("other_terms", None), ("time_profile", "p")],
        )
        self.assertEqual(conflict["session_ids"], ["a", "b"])

    def test_fewest_rules_are_named_when_fewer_sessions_need_more(self):
        result = solve.cp_sat_solve(evening_cohort_spec(), time.monotonic())

        self.assertEqual(
            [(rule["kind"], rule["id"]) for rule in result["conflict"]["rules"]],
            [("group_load", "g"), ("time_profile", "p")],
        )

    def test_term_model_keeps_allowed_starts_without_time_rules(self):
        spec = evening_cohort_spec()

        model, rules, placed = solve.conflict_model(spec, relax_starts=False)

        self.assertEqual(
            sorted(rule["kind"] for rule in rules), ["group_load", "other_terms"]
        )
        model.add_assumptions(
            [rule["literal"] for rule in rules] + list(placed.values())
        )
        solver = cp_model.CpSolver()
        self.assertEqual(solver.solve(model), cp_model.INFEASIBLE)

    def test_building_stops_at_the_deadline(self):
        with self.assertRaises(TimeoutError):
            solve.conflict_model(evening_cohort_spec(), deadline=time.monotonic() - 1)

    def test_spec_without_rule_identities_reports_no_conflict(self):
        spec = small_spec()
        spec["grid"] = {"days_count": 1, "slots_per_day": 1}

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertEqual(result["status"], "INFEASIBLE")
        self.assertIsNone(result["conflict"])

    def test_explanation_stays_within_the_time_limit(self):
        now = time.monotonic()
        self.assertLessEqual(solve.explanation_deadline(now + 1, 180), now + 1.01)
        self.assertLessEqual(
            solve.explanation_deadline(now + 170, 180),
            time.monotonic() + solve.EXPLANATION_SECONDS,
        )
        self.assertLessEqual(
            solve.explanation_deadline(now + 2, 2), time.monotonic() + 1
        )
        self.assertIsNone(
            solve.explain_infeasibility(overloaded_teacher_spec(), time.monotonic())
        )

    def test_whole_term_is_skipped_when_building_it_could_pass_the_deadline(self):
        spec = teacher_and_group_spec()

        self.assertIsNone(solve.explain_infeasibility(spec, time.monotonic() + 1, 10.0))
        self.assertIsNotNone(
            solve.explain_infeasibility(spec, time.monotonic() + 1, 0.0)
        )

    def test_conflict_across_a_teacher_and_a_group_uses_the_whole_term(self):
        spec = teacher_and_group_spec()

        result = solve.cp_sat_solve(spec, time.monotonic())

        self.assertEqual(
            [(rule["kind"], rule["id"]) for rule in result["conflict"]["rules"]],
            [("teacher_load", "t"), ("group_load", "g"), ("lock", "a"), ("lock", "c")],
        )
        self.assertEqual(result["conflict"]["session_ids"], ["a", "b", "c"])


def _reference_overlap(x, sessions, slot_count, rooms, slots_per_day, seen):
    """Replay the direct per-slot scan. `seen` drops repeated variable sets."""
    posted = []
    if not sessions:
        return posted
    weeks = set().union(*(session["weeks"] for session in sessions))
    weekly_ids = {
        (
            week if x.weekly else None,
            tuple(session["id"] for session in sessions if week in session["weeks"]),
        )
        for week in weeks
    }
    by_id = {session["id"]: session for session in sessions}
    for slot_index in range(slot_count):
        for week, session_ids in sorted(weekly_ids):
            candidates = x.for_week(week) if week is not None else x
            variables = []
            for session_id in session_ids:
                session = by_id[session_id]
                room_candidates = (
                    rooms if rooms is not None else solve.candidate_rooms(session)
                )
                for start_index in session["allowed_starts"]:
                    if not solve.covers_slot(
                        start_index,
                        session["duration_slots"],
                        slot_index,
                        slots_per_day,
                    ):
                        continue
                    for room in room_candidates:
                        variable = candidates.get((session["id"], start_index, room))
                        if variable is not None:
                            variables.append(variable)
            if len(variables) > 1:
                key = tuple(sorted(variable.index for variable in variables))
                if key not in seen:
                    seen.add(key)
                    posted.append([variable.index for variable in variables])
    return posted


class IndexTests(unittest.TestCase):
    def _sessions(self):
        raw = [
            {
                "id": "a",
                "allowed_rooms": ["r", "q"],
                "weeks": [1, 2, 3],
                "duration_slots": 2,
                "allowed_starts": [
                    {"day": 1, "slot": 1},
                    {"day": 1, "slot": 2},
                    {"day": 2, "slot": 1},
                ],
            },
            {
                "id": "b",
                "allowed_rooms": ["r"],
                "weeks": [1, 3],
                "duration_slots": 1,
                "allowed_starts": [{"day": 1, "slot": 1}, {"day": 1, "slot": 2}],
            },
            {
                "id": "c",
                "allowed_rooms": ["q"],
                "weeks": [2, 3],
                "choose_week": True,
                "duration_slots": 2,
                "allowed_starts": [{"day": 1, "slot": 1}],
            },
            {
                "id": "d",
                "delivery_mode": "online",
                "allowed_rooms": [],
                "weeks": [1, 2],
                "duration_slots": 1,
                "allowed_starts": [{"day": 1, "slot": 1}],
            },
        ]
        return solve.normalize_sessions(raw, 2, 4)

    def _variables(self, sessions):
        model = cp_model.CpModel()
        x = solve.AssignmentVariables(sessions)
        for session in sessions:
            solve.add_assignment_variables(model, x, session, ["r", "q"])
        return model, x

    def test_for_week_and_indexes_follow_creation_order(self):
        sessions = self._sessions()
        _model, x = self._variables(sessions)
        for week in (1, 2, 3):
            direct = {
                key: x.weekly.get((*key, week), variable)
                for key, variable in x.items()
                if week in x.sessions[key[0]]["weeks"]
            }
            self.assertEqual(list(x.for_week(week).items()), list(direct.items()))

        for session in sessions:
            if not session["choose_week"]:
                continue
            for week in sorted(session["weeks"]):
                scanned = [
                    variable
                    for (sid, _start, _room, candidate), variable in x.weekly.items()
                    if sid == session["id"] and candidate == week
                ]
                self.assertEqual(x.weekly_by_week[session["id"]][week], scanned)

        group = [session for session in sessions if session["choose_week"]]
        ids = {session["id"] for session in group}
        positions = {}
        for session in group:
            for start in session["allowed_starts"]:
                for room, variable in x.by_start[session["id"]].get(start, ()):
                    positions.setdefault((start, room), []).append(variable)
        scanned = {}
        for (sid, start, room), variable in x.items():
            if sid in ids:
                scanned.setdefault((start, room), []).append(variable)
        self.assertEqual(list(positions.items()), list(scanned.items()))

    def test_overlap_constraints_match_the_direct_slot_scan(self):
        sessions = self._sessions()
        by_id = {session["id"]: session for session in sessions}
        model, x = self._variables(sessions)
        seen = set()
        room_groups = [
            {"room_id": "r", "session_ids": ["a", "b"]},
            {"room_id": "q", "session_ids": ["a", "c"]},
        ]
        exclusive = [{"session_ids": ["a", "b", "c", "d"]}]
        solve.add_room_group_constraints(model, x, room_groups, by_id, 8, 4, seen)
        solve.add_exclusive_group_constraints(model, x, exclusive, by_id, 8, 4, seen)

        posted = []
        shared = set()
        for group, rooms in (
            (["a", "b"], ["r"]),
            (["a", "c"], ["q"]),
            (["a", "b", "c", "d"], None),
        ):
            posted.extend(
                _reference_overlap(
                    x,
                    [by_id[session_id] for session_id in group],
                    8,
                    rooms,
                    4,
                    shared,
                )
            )

        got = [
            list(constraint.at_most_one.literals)
            for constraint in model.proto.constraints
            if constraint.has_at_most_one()
        ]
        self.assertEqual(got, posted)
        self.assertTrue(posted)

        enforced = cp_model.CpModel()
        y = solve.AssignmentVariables(sessions)
        for session in sessions:
            solve.add_assignment_variables(enforced, y, session, ["r", "q"])
        literal = enforced.new_bool_var("rule")
        solve.add_exclusive_group_constraints(
            enforced, y, exclusive, by_id, 8, 4, enforce=literal
        )
        added = _reference_overlap(
            y,
            [by_id[session_id] for session_id in exclusive[0]["session_ids"]],
            8,
            None,
            4,
            set(),
        )
        guarded = []
        for constraint in enforced.proto.constraints:
            if constraint.enforcement_literal and constraint.has_linear():
                guarded.append(list(constraint.linear.vars))
        # Enforced sums are stored canonically by variable index.
        self.assertEqual(
            guarded,
            [sorted(literals) for literals in added],
        )
