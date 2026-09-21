from __future__ import annotations

import json
import sys
import time
from itertools import product
from collections import Counter
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
    """Load the spec, solve it and write one JSON result line to stdout."""
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
    """Read JSON from the path in argv, or from stdin when no path is given."""
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r", encoding="utf-8") as spec_file:
            return json.load(spec_file)

    return json.load(sys.stdin)


class AssignmentVariables(dict):
    """Expose recurring assignments and week-specific choices through one lookup."""

    def __init__(self, sessions):
        super().__init__()
        self.sessions = {session["id"]: session for session in sessions}
        self.weekly = {}
        self.views = {}

    def for_week(self, week):
        if not self.weekly:
            return self
        if week not in self.views:
            self.views[week] = {
                key: self.weekly.get((*key, week), variable)
                for key, variable in self.items()
                if week in self.sessions[key[0]]["weeks"]
            }
        return self.views[week]


def cp_sat_solve(spec: dict, started: float) -> dict:
    """Build and solve the CP-SAT timetable model for the spec.

    Return status, objective and assignments. A successful result assigns every
    session a day, slot and room. Failure returns no assignments."""
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
    deadline = started + float(solver_config["time_limit"])

    if not spec["requirements"]["all_sessions_placed"]:
        return error_result(
            "MODEL_INVALID", "solver requires all_sessions_placed=true", started
        )

    model = cp_model.CpModel()
    x = AssignmentVariables(sessions)

    for session in sessions:
        session_id = session["id"]
        allowed_rooms = [
            room for room in candidate_rooms(session) if room is None or room in rooms
        ]

        for slot_index in session["allowed_starts"]:
            for room in allowed_rooms:
                x[(session_id, slot_index, room)] = model.new_bool_var(
                    f"x_{session_id}_{slot_index}_{room}"
                )
                if session["choose_week"]:
                    choices = []
                    for week in sorted(session["weeks"]):
                        variable = model.new_bool_var(
                            f"week_{session_id}_{slot_index}_{room}_{week}"
                        )
                        x.weekly[(session_id, slot_index, room, week)] = variable
                        choices.append(variable)
                    model.add(sum(choices) == x[(session_id, slot_index, room)])

        assignment_vars = [
            x[(session_id, slot_index, room)]
            for slot_index in session["allowed_starts"]
            for room in allowed_rooms
        ]
        model.add(sum(assignment_vars) == 1)

    # Published bookings in overlapping terms are already mapped to each
    # session's weeks by the Elixir context; keep the full Cartesian domain so
    # existing soft constraints can still address every variable.
    for session in spec["sessions"]:
        for blocked in session.get("blocked_assignments", []):
            key = (
                str(session["id"]),
                (int(blocked["day"]) - 1) * slots_per_day + int(blocked["slot"]) - 1,
                normalize_room(blocked.get("room")),
            )
            variable = (
                x.weekly.get((*key, int(blocked["week"])))
                if "week" in blocked
                else x.get(key)
            )
            if variable is not None:
                model.add(variable == 0)

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
        if sessions_by_id[session_id]["choose_week"]:
            weeks = placement.get("weeks", [])
            variable = x.weekly.get((*key, weeks[0])) if len(weeks) == 1 else None
            if variable is None:
                return error_result(
                    "MODEL_INVALID", "fixed placement has no allowed week", started
                )
            model.add(variable == 1)

    # Automatically generated meetings must deliver the requested contact hours.
    # Unlike legacy recurring templates, they cannot fall on an excluded date.
    excluded = normalize_excluded_cells(spec.get("excluded_cells", []))
    for (_session_id, start, _room, week), variable in x.weekly.items():
        if (week, start // slots_per_day + 1) in excluded:
            model.add(variable == 0)

    hard_constraints_seen = set()
    add_room_group_constraints(
        model,
        x,
        hard["room_groups"],
        sessions_by_id,
        slot_count,
        slots_per_day,
        hard_constraints_seen,
    )
    add_exclusive_group_constraints(
        model,
        x,
        hard["exclusive_groups"],
        sessions_by_id,
        slot_count,
        slots_per_day,
        hard_constraints_seen,
    )

    base_objective_terms = automatic_workload_terms(
        model,
        x,
        sessions,
        int(weights.get("weekly_balance", 100)),
        set(fixed)
        | set(current)
        | {
            str(session["id"])
            for session in spec["sessions"]
            if session.get("blocked_assignments")
        },
    )
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

    remaining_time = deadline - time.monotonic()
    if remaining_time <= 0:
        return error_result("UNKNOWN", "time budget exhausted before search", started)

    use_two_phases = bool(base_objective_terms and active_day_objective_terms)
    first_phase_time = remaining_time * 0.4 if use_two_phases else remaining_time
    base_objective = sum(base_objective_terms)
    full_objective = sum(base_objective_terms + active_day_objective_terms)
    model.minimize(base_objective if use_two_phases else full_objective)
    solver = configured_solver(solver_config, first_phase_time)
    status = solver.solve(model)

    # Retry a first phase without a solution using the remaining shared budget.
    if use_two_phases and status == cp_model.UNKNOWN:
        remaining_time = deadline - time.monotonic()
        if remaining_time > 0.01:
            solver = configured_solver(solver_config, remaining_time)
            status = solver.solve(model)

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
        # A hint alone does not guarantee an outcome as good as this incumbent.
        # Preserve both the first-stage priority and the incumbent's full cost.
        model.add(base_objective <= solver.value(base_objective))
        model.add(full_objective <= solver.value(full_objective))
        model.clear_hints()
        for index in range(len(model.proto.variables)):
            variable = model.get_int_var_from_proto_index(index)
            model.add_hint(variable, solver.value(variable))
        model.minimize(full_objective)

        # First-stage optimality says nothing about the full objective.
        status = cp_model.FEASIBLE
        remaining_time = deadline - time.monotonic()
        if remaining_time > 0.01:
            compact_solver = configured_solver(solver_config, remaining_time)
            compact_status = compact_solver.solve(model)
            if compact_status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
                solver = compact_solver
                status = compact_status

    status_name = solver.status_name(status)
    assignment = {}
    for session in sessions:
        session_id = session["id"]
        for slot_index in session["allowed_starts"]:
            for room in candidate_rooms(session):
                variable = x.get((session_id, slot_index, room))
                if variable is not None and solver.boolean_value(variable):
                    assignment[session_id] = slot_to_day_slot(
                        slot_index, slots_per_day, room
                    )
                    if session["choose_week"]:
                        assignment[session_id]["weeks"] = [
                            week
                            for week in sorted(session["weeks"])
                            if solver.boolean_value(
                                x.weekly[(session_id, slot_index, room, week)]
                            )
                        ]
                    break
            if session_id in assignment:
                break

    return {
        "ok": len(assignment) == len(sessions),
        "status": status_name,
        "objective": round(solver.value(full_objective)),
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
    model, x, groups, sessions_by_id, slot_count, slots_per_day, seen=None
):
    """Prevent room conflicts in every occupied slot and teaching week."""
    seen = set() if seen is None else seen
    for group in groups:
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        room = str(group["room_id"])

        for slot_index in range(slot_count):
            add_week_overlap_constraints(
                model, x, sessions, slot_index, [room], slots_per_day, seen
            )


def add_exclusive_group_constraints(
    model, x, groups, sessions_by_id, slot_count, slots_per_day, seen=None
):
    """Prevent teacher and cohort conflicts in every occupied slot and teaching week.
    Check all rooms."""
    seen = set() if seen is None else seen
    for group in groups:
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]

        for slot_index in range(slot_count):
            add_week_overlap_constraints(
                model, x, sessions, slot_index, None, slots_per_day, seen
            )


def add_week_overlap_constraints(
    model, x, sessions, slot_index, rooms, slots_per_day, seen
):
    """Add at-most-one constraints per (slot, week) over the sessions' candidate
    room variables.

    `rooms` limits the check to the given rooms. With None, check each session's
    allowed rooms."""
    weeks = (
        set().union(*(session["weeks"] for session in sessions)) if sessions else set()
    )
    weekly_ids = {
        (
            week if getattr(x, "weekly", {}) else None,
            tuple(s["id"] for s in sessions if week in s["weeks"]),
        )
        for week in weeks
    }
    by_id = {session["id"]: session for session in sessions}
    for week, session_ids in sorted(weekly_ids):
        candidates = x.for_week(week) if week is not None else x
        variables = []
        for session_id in session_ids:
            session = by_id[session_id]

            room_candidates = rooms if rooms is not None else candidate_rooms(session)
            for start_index in session["allowed_starts"]:
                if not covers_slot(
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
                model.add_at_most_one(variables)
                seen.add(key)


def perturbation_terms(model, x, current, weight):
    """Penalize changes to current assignments that remain valid candidates."""
    if weight <= 0:
        return []

    terms = []
    for session_id, placement in current.items():
        key = (session_id, placement["slot_index"], placement["room"])
        if key in x:
            variable = x[key]
            weeks = placement.get("weeks", [])
            if getattr(x, "weekly", {}) and len(weeks) == 1:
                variable = x.weekly.get((*key, weeks[0]), variable)
            moved = model.new_bool_var(f"moved_{session_id}")
            model.add(moved == 1 - variable)
            terms.append(weight * moved)

    return terms


def excluded_day_terms(x, sessions, excluded_cells, slots_per_day, weight):
    """Penalize each meeting lost because its date is excluded."""
    if weight <= 0 or not excluded_cells:
        return []

    weeks_by_day: dict[int, set[int]] = {}
    for week, day in excluded_cells:
        weeks_by_day.setdefault(day, set()).add(week)

    terms = []
    for session in sessions:
        if session.get("choose_week", False):
            continue
        for day, weeks in weeks_by_day.items():
            lost = len(session["weeks"] & weeks)
            if lost == 0:
                continue

            for slot in range(slots_per_day):
                slot_index = (day - 1) * slots_per_day + slot
                for room in candidate_rooms(session):
                    variable = x.get((session["id"], slot_index, room))
                    if variable is not None:
                        terms.append(weight * lost * variable)

    return terms


def normalize_excluded_cells(raw):
    """Convert excluded cells to a set of integer (week, day) pairs."""
    return {(int(cell["week"]), int(cell["day"])) for cell in raw}


def weighted_groups(groups):
    """Share identical weekly expressions while retaining every resource/week cost."""
    return sorted(
        Counter(tuple(sorted(group["session_ids"])) for group in groups).items()
    )


def weekly_group_variables(x, groups):
    """Keep week identity when a meeting can move between weeks."""
    if getattr(x, "weekly", {}):
        grouped = Counter(
            (int(group["week"]), tuple(sorted(group["session_ids"])))
            for group in groups
        )
        return [
            (x.for_week(week), ids, count)
            for (week, ids), count in sorted(grouped.items())
        ]
    return [(x, ids, count) for ids, count in weighted_groups(groups)]


def automatic_workload_terms(model, x, sessions, weight, existing_ids):
    """Spread each teaching requirement across weeks and favour recurring times."""
    groups = {}
    for session in sessions:
        if session["choose_week"]:
            groups.setdefault(session["workload"], []).append(session)
    terms = []
    for index, group in enumerate(groups.values()):
        ids = {session["id"] for session in group}
        weeks = sorted(set().union(*(session["weeks"] for session in group)))
        week_counts = {}
        for week in weeks:
            variables = [
                variable
                for (sid, _start, _room, candidate_week), variable in x.weekly.items()
                if sid in ids and candidate_week == week
            ]
            week_counts[week] = sum(variables)
            deviation = model.new_int_var(
                0, len(weeks) * len(group), f"spread_{index}_{week}"
            )
            model.add_abs_equality(deviation, len(weeks) * sum(variables) - len(group))
            terms.append(weight * deviation)
        if 1 < len(group) < len(weeks):
            # Sliding windows favour regular intervals without choosing odd/even
            # weeks for the administrator. Explicit eligible weeks still bound the run.
            window_size = max(2, round(len(weeks) / len(group)))
            for offset in range(len(weeks) - window_size + 1):
                window = weeks[offset : offset + window_size]
                deviation = model.new_int_var(
                    0, len(weeks) * len(group), f"interval_{index}_{offset}"
                )
                model.add_abs_equality(
                    deviation,
                    len(weeks) * sum(week_counts[week] for week in window)
                    - window_size * len(group),
                )
                terms.append(weight * deviation)
        positions = {}
        for (sid, start, room), variable in x.items():
            if sid in ids:
                positions.setdefault((start, room), []).append(variable)
        for position, variables in positions.items():
            used = model.new_bool_var(f"recurring_{index}_{position}")
            model.add_max_equality(used, variables)
            terms.append(used)
        if not ids.intersection(existing_ids) and all(
            (session["weeks"], session["allowed_starts"], session["allowed_rooms"])
            == (
                group[0]["weeks"],
                group[0]["allowed_starts"],
                group[0]["allowed_rooms"],
            )
            for session in group
        ):
            # New interchangeable meetings can be ordered without removing a timetable.
            cells = sorted(
                (week, start, room)
                for week in weeks
                for start in group[0]["allowed_starts"]
                for room in candidate_rooms(group[0])
            )
            orders = [
                sum(
                    (rank + 1) * x.weekly[(sid, start, room, week)]
                    for rank, (week, start, room) in enumerate(cells)
                )
                for sid in sorted(ids)
            ]
            for left, right in zip(orders, orders[1:]):
                model.add(left <= right)
    return terms


def building_terms(
    model, x, groups, sessions_by_id, room_buildings, days_count, slots_per_day, weight
):
    """Penalize each additional building used by a group on the same day."""
    if weight <= 0:
        return []

    terms = []
    buildings = sorted(set(room_buildings.values()))

    for group_index, (weekly_x, session_ids, repetitions) in enumerate(
        weekly_group_variables(x, groups)
    ):
        group_weight = weight * repetitions
        sessions = [sessions_by_id[session_id] for session_id in session_ids]
        if len(sessions) < 2:
            continue

        for day in range(days_count):
            uses = []

            for building in buildings:
                variables = []
                for session in sessions:
                    for slot in range(slots_per_day):
                        slot_index = day * slots_per_day + slot
                        for room in candidate_rooms(session):
                            if room_buildings.get(room) == building:
                                variable = weekly_x.get(
                                    (session["id"], slot_index, room)
                                )
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
                terms.append(group_weight * penalty)

    return terms


def gap_terms(model, x, groups, sessions_by_id, days_count, slots_per_day, weight):
    """Penalize free slots between a group's sessions on the same day."""
    if weight <= 0 or slots_per_day < 3:
        return []

    terms = []

    for group_index, (weekly_x, session_ids, repetitions) in enumerate(
        weekly_group_variables(x, groups)
    ):
        group_weight = weight * repetitions
        sessions = [sessions_by_id[session_id] for session_id in session_ids]
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

                        for room in candidate_rooms(session):
                            variable = weekly_x.get((session["id"], start_index, room))
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
                terms.append(group_weight * gap)

    return terms


def active_day_terms(
    model, x, groups, sessions_by_id, days_count, slots_per_day, weight
):
    """Penalize each day used by a weekly cohort/teacher group.

    This encourages fewer teaching days. Gap penalties alone do not discourage
    days with one session.
    """
    if weight <= 0:
        return []

    terms = []

    for group_index, (weekly_x, session_ids, repetitions) in enumerate(
        weekly_group_variables(x, groups)
    ):
        group_weight = weight * repetitions
        sessions = [sessions_by_id[session_id] for session_id in session_ids]
        if len(sessions) < 2:
            continue

        for day in range(days_count):
            variables = []
            for session in sessions:
                for slot in range(slots_per_day):
                    slot_index = day * slots_per_day + slot
                    for room in candidate_rooms(session):
                        variable = weekly_x.get((session["id"], slot_index, room))
                        if variable is not None:
                            variables.append(variable)

            if variables:
                active = model.new_bool_var(f"active_day_{group_index}_{day}")
                model.add_max_equality(active, variables)
                terms.append(group_weight * active)

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
                for room in candidate_rooms(left)
                if (left["id"], left_start, room) in x
            ]
            right_variables = [
                x[(right["id"], right_start, room)]
                for room in candidate_rooms(right)
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
                "delivery_mode": session.get("delivery_mode", "in_person"),
                "allowed_rooms": [str(room) for room in session["allowed_rooms"]],
                "allowed_starts": sorted(starts),
                "duration_slots": duration,
                "weeks": {int(week) for week in session["weeks"]},
                "choose_week": bool(session.get("choose_week", False)),
                "workload": session.get("workload", str(session["id"])),
            }
        )

    return sessions


def covers_slot(start_index, duration, slot_index, slots_per_day):
    """Return whether a start assignment occupies a flattened grid cell."""
    start_day, start_inner = divmod(start_index, slots_per_day)
    slot_day, slot_inner = divmod(slot_index, slots_per_day)
    return start_day == slot_day and start_inner <= slot_inner < start_inner + duration


def normalize_placements(raw, slots_per_day):
    """Normalize room IDs to strings and day/slot values to 1-based integers.
    Add the 0-based slot_index used by model variables."""
    normalized = {}
    for session_id, placement in raw.items():
        day = int(placement["day"])
        slot = int(placement["slot"])
        normalized[str(session_id)] = {
            "day": day,
            "slot": slot,
            "room": normalize_room(placement.get("room")),
            "slot_index": (day - 1) * slots_per_day + (slot - 1),
            "weeks": [int(week) for week in placement.get("weeks", [])],
        }
    return normalized


def slot_to_day_slot(slot_index, slots_per_day, room):
    """Convert a 0-based slot index to 1-based day and slot values; keep the room ID."""
    return {
        "day": slot_index // slots_per_day + 1,
        "slot": slot_index % slots_per_day + 1,
        "room": room,
    }


def candidate_rooms(session):
    """Return physical room IDs, or one roomless candidate for an online session."""
    return [None] if session.get("delivery_mode") == "online" else session["allowed_rooms"]


def normalize_room(room):
    return None if room is None else str(room)


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
