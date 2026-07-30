from __future__ import annotations

import json
import sys
import time
from itertools import product
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ortools.sat.python import cp_model
else:
    try:
        from ortools.sat.python import cp_model
    except (
        ImportError
    ):  # pragma: no cover - exercised only when the uv environment is unavailable.
        cp_model = None


def main() -> int:
    """Entry point: load the spec, solve, and write a one-line JSON result to stdout."""
    started = time.monotonic()

    try:
        spec = load_spec()
        result = (
            error_result(
                "SOLVER_UNAVAILABLE",
                "OR-Tools is unavailable in the uv environment",
                started,
            )
            if cp_model is None
            else cp_sat_solve(spec, started)
        )
    except (KeyError, TypeError, ValueError) as error:
        result = error_result("MODEL_INVALID", f"invalid solver spec: {error}", started)

    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


def load_spec() -> dict:
    """Load the spec JSON from the path given in argv, falling back to stdin."""
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r", encoding="utf-8") as spec_file:
            return json.load(spec_file)

    return json.load(sys.stdin)


def cp_sat_solve(spec: dict, started: float) -> dict:
    """Build and solve the CP-SAT timetable model for the spec.

    Returns the result payload: status, objective, and a session -> (day, slot, room)
    assignment covering every session when the model is feasible."""
    grid = spec["grid"]
    days_count = int(grid["days_count"])
    slots_per_day = int(grid["slots_per_day"])
    slot_count = days_count * slots_per_day
    rooms = [str(room["id"]) for room in spec["rooms"]]
    room_buildings = {
        str(room["id"]): str(room["building_id"]) for room in spec["rooms"]
    }
    sessions = normalize_sessions(spec["sessions"], days_count, slots_per_day)
    sessions_by_id = {session["id"]: session for session in sessions}
    fixed = normalize_placements(spec["fixed"], slots_per_day)
    current = normalize_placements(spec["current"], slots_per_day)
    hard = spec["hard"]
    soft = spec["soft"]
    weights = soft["weights"]
    solver_config = spec["solver"]

    if not spec["requirements"]["all_sessions_placed"]:
        return error_result(
            "MODEL_INVALID", "solver requires all_sessions_placed=true", started
        )

    model = cp_model.CpModel()
    x: dict[tuple[str, int, str], cp_model.IntVar] = {}

    for session in sessions:
        session_id = session["id"]
        allowed_rooms = [room for room in session["allowed_rooms"] if room in rooms]

        for slot_index in session["allowed_starts"]:
            for room in allowed_rooms:
                x[(session_id, slot_index, room)] = model.new_bool_var(
                    f"x_{session_id}_{slot_index}_{room}"
                )

        assignment_vars = [
            x[(session_id, slot_index, room)]
            for slot_index in session["allowed_starts"]
            for room in allowed_rooms
        ]
        model.add(sum(assignment_vars) == 1)

    for session_id, placement in fixed.items():
        if session_id not in sessions_by_id:
            return error_result(
                "MODEL_INVALID",
                f"fixed placement references unknown session {session_id}",
                started,
            )

        key = (session_id, placement["slot_index"], placement["room"])
        if key not in x:
            return error_result(
                "MODEL_INVALID",
                f"fixed placement is outside allowed cells for session {session_id}",
                started,
            )

        model.add(x[key] == 1)

    add_room_group_constraints(
        model,
        x,
        hard["room_groups"],
        sessions_by_id,
        slot_count,
        slots_per_day,
    )
    add_exclusive_group_constraints(
        model,
        x,
        hard["exclusive_groups"],
        sessions_by_id,
        slot_count,
        slots_per_day,
    )

    base_objective_terms = []
    base_objective_terms.extend(
        perturbation_terms(model, x, current, int(weights["perturbation"]))
    )
    base_objective_terms.extend(
        excluded_day_terms(
            x,
            sessions,
            normalize_excluded_cells(spec.get("excluded_cells", [])),
            slots_per_day,
            int(weights.get("excluded_days", 0)),
        )
    )
    base_objective_terms.extend(
        building_terms(
            model,
            x,
            soft["building_groups"],
            sessions_by_id,
            room_buildings,
            days_count,
            slots_per_day,
            int(weights["building"]),
        )
    )
    base_objective_terms.extend(
        gap_terms(
            model,
            x,
            soft["gap_groups"],
            sessions_by_id,
            days_count,
            slots_per_day,
            int(weights["gaps"]),
        )
    )
    base_objective_terms.extend(
        sequence_terms(
            model,
            x,
            soft["sequence_pairs"],
            sessions_by_id,
            slots_per_day,
            int(weights["sequence"]),
        )
    )
    active_day_objective_terms = active_day_terms(
        model,
        x,
        soft.get("active_day_groups", soft["gap_groups"]),
        sessions_by_id,
        days_count,
        slots_per_day,
        int(weights.get("active_days", 0)),
    )

    for session_id, placement in current.items():
        key = (session_id, placement["slot_index"], placement["room"])
        if key in x:
            model.add_hint(x[key], 1)

    total_time = float(solver_config["time_limit"])
    use_two_phases = bool(base_objective_terms and active_day_objective_terms)
    first_phase_time = total_time * 0.4 if use_two_phases else total_time

    model.minimize(
        sum(base_objective_terms)
        if use_two_phases
        else sum(base_objective_terms + active_day_objective_terms)
    )
    solving_started = time.monotonic()
    solver = configured_solver(solver_config, first_phase_time)
    status = solver.solve(model)

    # A split first phase may exhaust its share before CP-SAT finds any feasible
    # assignment. Do not report UNKNOWN while most of the caller's budget is
    # still unused: continue the same base objective with the remaining time.
    if use_two_phases and status == cp_model.UNKNOWN:
        elapsed_solving_time = time.monotonic() - solving_started
        remaining_time = total_time - elapsed_solving_time

        if remaining_time > 0.01:
            continuation_solver = configured_solver(solver_config, remaining_time)
            continuation_status = continuation_solver.solve(model)
            solver = continuation_solver
            status = continuation_status

    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return {
            "ok": False,
            "status": solver.status_name(status),
            "objective": None,
            "wall_time": round(time.monotonic() - started, 4),
            "unplaced": [],
            "assignment": {},
            "backend": "cp_sat",
        }

    if use_two_phases:
        best_base_objective = round(solver.objective_value)
        model.add(sum(base_objective_terms) <= best_base_objective)
        model.clear_hints()

        for variable in x.values():
            if solver.boolean_value(variable):
                model.add_hint(variable, 1)

        model.minimize(sum(base_objective_terms + active_day_objective_terms))
        elapsed_solving_time = time.monotonic() - solving_started
        compact_solver = configured_solver(
            solver_config, total_time - elapsed_solving_time
        )
        compact_status = compact_solver.solve(model)

        if compact_status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            solver = compact_solver
            status = compact_status

    status_name = solver.status_name(status)
    assignment = {}
    for session in sessions:
        session_id = session["id"]
        for slot_index in session["allowed_starts"]:
            for room in session["allowed_rooms"]:
                variable = x.get((session_id, slot_index, room))
                if variable is not None and solver.boolean_value(variable):
                    assignment[session_id] = slot_to_day_slot(
                        slot_index, slots_per_day, room
                    )
                    break
            if session_id in assignment:
                break

    return {
        "ok": len(assignment) == len(sessions),
        "status": status_name,
        "objective": round(solver.objective_value),
        "wall_time": round(time.monotonic() - started, 4),
        "unplaced": [],
        "assignment": assignment,
        "backend": "cp_sat",
    }


def configured_solver(solver_config, time_limit):
    """Create a CP-SAT solver with a phase-specific share of the time budget."""
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = max(float(time_limit), 0.01)
    solver.parameters.relative_gap_limit = float(solver_config["gap"])
    solver.parameters.num_search_workers = int(solver_config["workers"])
    return solver


def add_room_group_constraints(
    model, x, groups, sessions_by_id, slot_count, slots_per_day
):
    """Forbid two sessions from occupying the same room in the same slot on an
    overlapping week."""
    for group in groups:
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        room = str(group["room_id"])

        for slot_index in range(slot_count):
            add_week_overlap_constraints(
                model, x, sessions, slot_index, [room], slots_per_day
            )


def add_exclusive_group_constraints(
    model, x, groups, sessions_by_id, slot_count, slots_per_day
):
    """Forbid sessions sharing an exclusive resource (teacher, cohort) from meeting
    in the same slot on an overlapping week, regardless of room."""
    for group in groups:
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]

        for slot_index in range(slot_count):
            add_week_overlap_constraints(
                model, x, sessions, slot_index, None, slots_per_day
            )


def add_week_overlap_constraints(model, x, sessions, slot_index, rooms, slots_per_day):
    """Add at-most-one constraints per (slot, week) over the sessions' candidate
    room variables.

    `rooms` narrows candidates to one specific room (room groups); None means each
    session's own allowed rooms (exclusive groups)."""
    weeks = (
        sorted(set().union(*(session["weeks"] for session in sessions)))
        if sessions
        else []
    )

    for week in weeks:
        variables = []

        for session in sessions:
            if week not in session["weeks"]:
                continue

            candidate_rooms = rooms if rooms is not None else session["allowed_rooms"]
            for start_index in session["allowed_starts"]:
                if not covers_slot(
                    start_index,
                    session["duration_slots"],
                    slot_index,
                    slots_per_day,
                ):
                    continue

                for room in candidate_rooms:
                    variable = x.get((session["id"], start_index, room))
                    if variable is not None:
                        variables.append(variable)

        if len(variables) > 1:
            model.add(sum(variables) <= 1)


def perturbation_terms(model, x, current, weight):
    """Penalize moving a session away from its current assignment (minimal
    perturbation on re-solves)."""
    if weight <= 0:
        return []

    terms = []
    for session_id, placement in current.items():
        key = (session_id, placement["slot_index"], placement["room"])
        if key in x:
            moved = model.new_bool_var(f"moved_{session_id}")
            model.add(moved == 1 - x[key])
            terms.append(weight * moved)

    return terms


def excluded_day_terms(x, sessions, excluded_cells, slots_per_day, weight):
    """Penalize days where a session's weeks collide with excluded (week, day)
    cells, proportionally to the number of meetings lost to them."""
    if weight <= 0 or not excluded_cells:
        return []

    weeks_by_day: dict[int, set[int]] = {}
    for week, day in excluded_cells:
        weeks_by_day.setdefault(day, set()).add(week)

    terms = []
    for session in sessions:
        for day, weeks in weeks_by_day.items():
            lost = len(session["weeks"] & weeks)
            if lost == 0:
                continue

            for slot in range(slots_per_day):
                slot_index = (day - 1) * slots_per_day + slot
                for room in session["allowed_rooms"]:
                    variable = x.get((session["id"], slot_index, room))
                    if variable is not None:
                        terms.append(weight * lost * variable)

    return terms


def normalize_excluded_cells(raw):
    """Coerce raw excluded-cell dicts into a set of (week, day) tuples."""
    return {(int(cell["week"]), int(cell["day"])) for cell in raw}


def building_terms(
    model, x, groups, sessions_by_id, room_buildings, days_count, slots_per_day, weight
):
    """Penalize every building beyond the first that a group's sessions visit on
    one day (building clustering)."""
    if weight <= 0:
        return []

    terms = []
    buildings = sorted(set(room_buildings.values()))

    for group_index, group in enumerate(groups):
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        if len(sessions) < 2:
            continue

        for day in range(days_count):
            uses = []

            for building in buildings:
                variables = []
                for session in sessions:
                    for slot in range(slots_per_day):
                        slot_index = day * slots_per_day + slot
                        for room in session["allowed_rooms"]:
                            if room_buildings.get(room) == building:
                                variable = x.get((session["id"], slot_index, room))
                                if variable is not None:
                                    variables.append(variable)

                if variables:
                    use = model.new_bool_var(f"building_{group_index}_{day}_{building}")
                    model.add_max_equality(use, variables)
                    uses.append(use)

            if len(uses) > 1:
                penalty = model.new_int_var(
                    0, len(uses), f"building_penalty_{group_index}_{day}"
                )
                model.add(penalty >= sum(uses) - 1)
                terms.append(weight * penalty)

    return terms


def gap_terms(model, x, groups, sessions_by_id, days_count, slots_per_day, weight):
    """Penalize free slots sandwiched between a group's occupied slots within a day."""
    if weight <= 0 or slots_per_day < 3:
        return []

    terms = []

    for group_index, group in enumerate(groups):
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        if len(sessions) < 2:
            continue

        for day in range(days_count):
            occupied = []

            for slot in range(slots_per_day):
                slot_index = day * slots_per_day + slot
                variables = []
                for session in sessions:
                    for start_index in session["allowed_starts"]:
                        if not covers_slot(
                            start_index,
                            session["duration_slots"],
                            slot_index,
                            slots_per_day,
                        ):
                            continue

                        for room in session["allowed_rooms"]:
                            variable = x.get((session["id"], start_index, room))
                            if variable is not None:
                                variables.append(variable)

                occupied_slot = model.new_bool_var(
                    f"occupied_{group_index}_{day}_{slot}"
                )
                if variables:
                    model.add_max_equality(occupied_slot, variables)
                else:
                    model.add(occupied_slot == 0)
                occupied.append(occupied_slot)

            for slot in range(1, slots_per_day - 1):
                before = model.new_bool_var(f"before_{group_index}_{day}_{slot}")
                after = model.new_bool_var(f"after_{group_index}_{day}_{slot}")
                gap = model.new_bool_var(f"gap_{group_index}_{day}_{slot}")

                model.add_max_equality(before, occupied[:slot])
                model.add_max_equality(after, occupied[slot + 1 :])
                model.add(gap >= before + after - occupied[slot] - 1)
                terms.append(weight * gap)

    return terms


def active_day_terms(
    model, x, groups, sessions_by_id, days_count, slots_per_day, weight
):
    """Penalize each day used by a weekly cohort/teacher group.

    Gap minimization removes holes inside a day, but without this term the solver
    may still spread isolated sessions over more days than necessary.
    """
    if weight <= 0:
        return []

    terms = []

    for group_index, group in enumerate(groups):
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        if len(sessions) < 2:
            continue

        for day in range(days_count):
            variables = []
            for session in sessions:
                for slot in range(slots_per_day):
                    slot_index = day * slots_per_day + slot
                    for room in session["allowed_rooms"]:
                        variable = x.get((session["id"], slot_index, room))
                        if variable is not None:
                            variables.append(variable)

            if variables:
                active = model.new_bool_var(f"active_day_{group_index}_{day}")
                model.add_max_equality(active, variables)
                terms.append(weight * active)

    return terms


def sequence_terms(model, x, pairs, sessions_by_id, slots_per_day, weight):
    """Penalize non-adjacent slots for session pairs in the same sequence group,
    scaled by their slot distance."""
    if weight <= 0:
        return []

    terms = []

    for pair in pairs:
        left = sessions_by_id[pair["left"]]
        right = sessions_by_id[pair["right"]]
        for left_start, right_start in product(
            left["allowed_starts"], right["allowed_starts"]
        ):
            penalty = slot_distance_penalty(
                left_start,
                left["duration_slots"],
                right_start,
                right["duration_slots"],
                slots_per_day,
            )
            if penalty == 0:
                continue

            left_variables = [
                x[(left["id"], left_start, room)]
                for room in left["allowed_rooms"]
                if (left["id"], left_start, room) in x
            ]
            right_variables = [
                x[(right["id"], right_start, room)]
                for room in right["allowed_rooms"]
                if (right["id"], right_start, room) in x
            ]
            if not left_variables or not right_variables:
                continue

            both = model.new_bool_var(
                f"sequence_{left['id']}_{right['id']}_{left_start}_{right_start}"
            )
            left_at_start = sum(left_variables)
            right_at_start = sum(right_variables)
            model.add(both <= left_at_start)
            model.add(both <= right_at_start)
            model.add(both >= left_at_start + right_at_start - 1)
            terms.append(weight * penalty * both)

    return terms


def slot_distance_penalty(
    left_slot, left_duration, right_slot, right_duration, slots_per_day
):
    """Penalty for two blocks: zero when their occupied ranges are adjacent."""
    left_day, left_inner = divmod(left_slot, slots_per_day)
    right_day, right_inner = divmod(right_slot, slots_per_day)

    if left_day != right_day:
        return slots_per_day

    left_end = left_inner + left_duration - 1
    right_end = right_inner + right_duration - 1

    if left_end + 1 == right_inner or right_end + 1 == left_inner:
        return 0

    if left_end < right_inner:
        return max(1, right_inner - left_end)

    if right_end < left_inner:
        return max(1, left_inner - right_end)

    return 1


def normalize_sessions(raw_sessions, days_count, slots_per_day):
    """Normalize durations and the explicitly allowed start cells."""
    sessions = []

    for session in raw_sessions:
        duration = int(session.get("duration_slots", 1))
        if duration <= 0:
            raise ValueError("duration_slots must be positive")

        raw_starts = session.get("allowed_starts")
        if raw_starts is None:
            starts = {
                day * slots_per_day + slot
                for day in range(days_count)
                for slot in range(slots_per_day - duration + 1)
            }
        else:
            starts = set()
            for cell in raw_starts:
                day = int(cell["day"])
                slot = int(cell["slot"])
                if (
                    day < 1
                    or day > days_count
                    or slot < 1
                    or slot + duration - 1 > slots_per_day
                ):
                    continue
                starts.add((day - 1) * slots_per_day + (slot - 1))

        sessions.append(
            {
                "id": str(session["id"]),
                "allowed_rooms": [str(room) for room in session["allowed_rooms"]],
                "allowed_starts": sorted(starts),
                "duration_slots": duration,
                "weeks": {int(week) for week in session["weeks"]},
            }
        )

    return sessions


def covers_slot(start_index, duration, slot_index, slots_per_day):
    """Return whether a start assignment occupies a flattened grid cell."""
    start_day, start_inner = divmod(start_index, slots_per_day)
    slot_day, slot_inner = divmod(slot_index, slots_per_day)
    return start_day == slot_day and start_inner <= slot_inner < start_inner + duration


def normalize_placements(raw, slots_per_day):
    """Coerce raw placements into 1-based day/slot/room plus the flattened
    0-based slot_index used for model variables."""
    normalized = {}
    for session_id, placement in raw.items():
        day = int(placement["day"])
        slot = int(placement["slot"])
        normalized[str(session_id)] = {
            "day": day,
            "slot": slot,
            "room": str(placement["room"]),
            "slot_index": (day - 1) * slots_per_day + (slot - 1),
        }
    return normalized


def slot_to_day_slot(slot_index, slots_per_day, room):
    """Convert a flat 0-based slot index back into the 1-based day/slot/room shape."""
    return {
        "day": slot_index // slots_per_day + 1,
        "slot": slot_index % slots_per_day + 1,
        "room": str(room),
    }


def error_result(status: str, message: str, started: float):
    """Build the standard failure payload for the given status and message."""
    return {
        "ok": False,
        "status": status,
        "error": message,
        "objective": None,
        "wall_time": round(time.monotonic() - started, 4),
        "unplaced": [],
        "assignment": {},
        "backend": "cp_sat",
    }


if __name__ == "__main__":
    raise SystemExit(main())
