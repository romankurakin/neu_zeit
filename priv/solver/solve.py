from __future__ import annotations

import json
import sys
import time
from itertools import combinations, product
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
    """Expose recurring assignments and week-specific choices through one lookup.

    Choices are also indexed by session and start, and movable meetings by week,
    so later constraints can gather variables without scanning the whole model.
    """

    def __init__(self, sessions):
        super().__init__()
        self.sessions = {session["id"]: session for session in sessions}
        self.weekly = {}
        self.views = {}
        # session -> start -> [(room, variable), ...] in candidate-room order
        self.by_start = {}
        # session -> week -> variables in start, then room, order
        self.weekly_by_week = {}
        # session -> week -> start -> [(room, variable), ...]
        self.weekly_by_start = {}
        self._covering = {}

    def for_week(self, week):
        """Return assignment variables as they stand in one teaching week.

        Movable meetings contribute their week variable. Every other meeting
        contributes its recurring variable when the week is one of its weeks.
        """
        if not self.weekly:
            return self
        view = self.views.get(week)
        if view is None:
            view = {}
            for session_id, session in self.sessions.items():
                if week not in session["weeks"]:
                    continue
                if session["choose_week"]:
                    starts = self.weekly_by_start.get(session_id, {}).get(week, {})
                else:
                    starts = self.by_start.get(session_id, {})
                for start, pairs in starts.items():
                    for room, variable in pairs:
                        view[(session_id, start, room)] = variable
            self.views[week] = view
        return view

    def covering(self, session, slots_per_day, week, rooms):
        """Map each grid slot to the variables of `session` that occupy it.

        Lists follow allowed-start order, and within a start the given `rooms`
        (every candidate room when `rooms` is None). A movable meeting uses the
        variables of `week`; any other meeting uses its recurring variables.
        """
        use_week = week if week is not None and session["choose_week"] else None
        rooms_key = None if rooms is None else tuple(rooms)
        key = (session["id"], slots_per_day, use_week, rooms_key)
        cached = self._covering.get(key)
        if cached is not None:
            return cached

        if use_week is None:
            by_start = self.by_start.get(session["id"], {})
        else:
            by_start = self.weekly_by_start.get(session["id"], {}).get(use_week, {})
        covered = {}
        duration = session["duration_slots"]
        for start in session["allowed_starts"]:
            pairs = by_start.get(start)
            if not pairs:
                continue
            if rooms is None:
                variables = [variable for _room, variable in pairs]
            else:
                found = {room: variable for room, variable in pairs}
                variables = [found[room] for room in rooms if room in found]
            if not variables:
                continue
            day, inner = divmod(start, slots_per_day)
            for offset in range(duration):
                if inner + offset >= slots_per_day:
                    break
                slot_index = day * slots_per_day + inner + offset
                covered.setdefault(slot_index, []).extend(variables)
        self._covering[key] = covered
        return covered


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
        model.add(sum(add_assignment_variables(model, x, session, rooms)) == 1)

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

    warm_assignment = {}
    if all(session_id in current for session_id in sessions_by_id):
        for session_id, placement in current.items():
            key = (session_id, placement["slot_index"], placement["room"])
            if key in x:
                model.add_hint(x[key], 1)
    else:
        warm_assignment = greedy_assignment(spec, x, fixed, current)
        add_assignment_hints(model, x, warm_assignment, current)

    now = time.monotonic()
    build_seconds = now - started
    remaining_time = deadline - now
    if remaining_time <= 0:
        return error_result("UNKNOWN", "time budget exhausted before search", started)

    use_two_phases = bool(base_objective_terms and active_day_objective_terms)
    first_phase_time = remaining_time * 0.4 if use_two_phases else remaining_time
    base_objective = sum(base_objective_terms)
    full_objective = sum(base_objective_terms + active_day_objective_terms)
    model.minimize(base_objective if use_two_phases else full_objective)
    solver = configured_solver(solver_config, first_phase_time)
    if warm_assignment:
        # Partial greedy assignments may need more than the default ten conflicts.
        solver.parameters.hint_conflict_limit = 1000
    status = solver.solve(model)

    # Retry a first phase without a solution using the remaining shared budget.
    if use_two_phases and status == cp_model.UNKNOWN:
        remaining_time = deadline - time.monotonic()
        if remaining_time > 0.01:
            solver = configured_solver(solver_config, remaining_time)
            status = solver.solve(model)

    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        result = {
            "ok": False,
            "status": solver.status_name(status),
            "objective": None,
            "unplaced": [],
            "assignment": {},
            "backend": "cp_sat",
        }
        if status == cp_model.INFEASIBLE:
            result["conflict"] = explain_infeasibility(
                spec,
                explanation_deadline(deadline, float(solver_config["time_limit"])),
                build_seconds,
            )
        result["wall_time"] = round(time.monotonic() - started, 4)
        return result

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


def greedy_assignment(spec, x, fixed, current):
    """Place constrained sessions first in the cheapest free cells."""
    slots_per_day = int(spec["grid"]["slots_per_day"])
    excluded = normalize_excluded_cells(spec.get("excluded_cells", []))
    groups = {sid: [] for sid in x.sessions}
    for index, group in enumerate(
        spec["hard"]["exclusive_groups"] + spec["hard"]["room_groups"]
    ):
        room = str(group["room_id"]) if "room_id" in group else None
        for sid in group["session_ids"]:
            groups[sid].append((index, room))
    choices = {sid: [] for sid in x.sessions}
    for sid, start, room in x:
        choices[sid].append((start, room))
    blocked = {}
    for session in spec["sessions"]:
        blocked[str(session["id"])] = {
            (
                (int(cell["day"]) - 1) * slots_per_day + int(cell["slot"]) - 1,
                normalize_room(cell.get("room")),
                int(cell["week"]) if "week" in cell else None,
            )
            for cell in session.get("blocked_assignments", [])
        }
    order = sorted(
        x.sessions,
        key=lambda sid: (
            sid not in fixed,
            sid not in current,
            len(choices[sid])
            * (len(x.sessions[sid]["weeks"]) if x.sessions[sid]["choose_week"] else 1),
            -len(groups[sid]),
            sid,
        ),
    )
    occupied = {}
    assignment = {}
    costs = GreedyCosts(spec, x, current)
    for sid in order:
        session = x.sessions[sid]
        old = fixed.get(sid, current.get(sid))
        candidates = choices[sid]
        if old is not None:
            preferred = (old["slot_index"], old["room"])
            candidates = sorted(candidates, key=lambda cell: cell != preferred)
            if sid in fixed:
                candidates = [cell for cell in candidates if cell == preferred]
        weeks = sorted(session["weeks"]) if session["choose_week"] else [None]
        if session["choose_week"] and old is not None:
            weeks = sorted(weeks, key=lambda week: week not in old["weeks"])
            if sid in fixed:
                weeks = [week for week in weeks if week in old["weeks"]]
        best = None
        best_cost = None
        best_cells = []
        for start, room in candidates:
            if (start, room, None) in blocked[sid]:
                continue
            resources = [
                index
                for index, target in groups[sid]
                if target is None or target == room
            ]
            mask = ((1 << session["duration_slots"]) - 1) << start
            for week in weeks:
                if week is not None and (
                    (week, start // slots_per_day + 1) in excluded
                    or (start, room, week) in blocked[sid]
                ):
                    continue
                occupied_weeks = session["weeks"] if week is None else [week]
                cells = [(index, w) for index in resources for w in occupied_weeks]
                if any(occupied.get(cell, 0) & mask for cell in cells):
                    continue
                cost = costs.delta(sid, start, room, week)
                if best_cost is None or cost < best_cost:
                    best = (start, room, week)
                    best_cost = cost
                    best_cells = cells
        if best is not None:
            assignment[sid] = best
            mask = ((1 << session["duration_slots"]) - 1) << best[0]
            for cell in best_cells:
                occupied[cell] = occupied.get(cell, 0) | mask
            costs.place(sid, *best)
    return assignment


def mask_gaps(mask):
    """Count empty slots between the first and last occupied slots."""
    if not mask:
        return 0
    return mask.bit_length() - (mask & -mask).bit_length() + 1 - mask.bit_count()


class GreedyCosts:
    """Track soft costs of a partial assignment without changing the model."""

    def __init__(self, spec, x, current):
        self.sessions = x.sessions
        self.slots_per_day = int(spec["grid"]["slots_per_day"])
        days_count = int(spec["grid"]["days_count"])
        soft = spec["soft"]
        self.weights = soft["weights"]
        self.room_buildings = {
            str(room["id"]): str(room["building_id"]) for room in spec["rooms"]
        }
        self.starts = {}
        self.current = {}
        for sid, old in current.items():
            key = (sid, old["slot_index"], old["room"])
            if key in x:
                weeks = old.get("weeks", [])
                week = (
                    weeks[0]
                    if len(weeks) == 1 and (*key, weeks[0]) in x.weekly
                    else None
                )
                self.current[sid] = (*key[1:], week)

        # Identical recurring weeks share state but retain their combined weight.
        grouped = {}
        for index, (field, metric) in enumerate(
            [
                ("gap_groups", "gaps"),
                ("active_day_groups", "active_days"),
                ("building_groups", "building"),
            ]
        ):
            weight = int(self.weights.get(metric, 0))
            if weight <= 0 or (metric == "gaps" and self.slots_per_day < 3):
                continue
            groups = soft.get(
                field, soft["gap_groups"] if metric == "active_days" else []
            )
            for group in groups:
                ids = tuple(sorted(group["session_ids"]))
                if len(ids) < 2:
                    continue
                week = int(group["week"]) if x.weekly else None
                if week is not None and all(
                    week in x.sessions[sid]["weeks"]
                    and not x.sessions[sid]["choose_week"]
                    for sid in ids
                ):
                    week = None
                grouped.setdefault((week, ids), [0, 0, 0])[index] += weight
        self.groups = {sid: [] for sid in x.sessions}
        for (week, ids), weights in grouped.items():
            masks = [0] * days_count
            buildings = [set() for _ in range(days_count)]
            for sid in ids:
                if week is None or week in x.sessions[sid]["weeks"]:
                    self.groups[sid].append((week, weights, masks, buildings))

        self.partners = {sid: [] for sid in x.sessions}
        if int(self.weights.get("sequence", 0)) > 0:
            for pair in soft["sequence_pairs"]:
                self.partners[pair["left"]].append(pair["right"])
                self.partners[pair["right"]].append(pair["left"])
        self.excluded = {}
        for week, day in normalize_excluded_cells(spec.get("excluded_cells", [])):
            self.excluded.setdefault(day - 1, set()).add(week)

        workloads = {}
        for sid, session in x.sessions.items():
            if session["choose_week"]:
                workloads.setdefault(session["workload"], []).append(sid)
        self.balance = {}
        self.positions = {}
        for ids in workloads.values():
            weeks = sorted(set().union(*(x.sessions[sid]["weeks"] for sid in ids)))
            scale, count = len(weeks), len(ids)
            terms = {week: [[0, count]] for week in weeks}
            if 1 < count < scale:
                window_size = max(2, round(scale / count))
                for offset in range(scale - window_size + 1):
                    term = [0, window_size * count]
                    for week in weeks[offset : offset + window_size]:
                        terms[week].append(term)
            positions = set()
            for sid in ids:
                self.balance[sid] = (scale, terms)
                self.positions[sid] = positions

    def delta(self, sid, start, room, week):
        session = self.sessions[sid]
        day, slot = divmod(start, self.slots_per_day)
        mask = ((1 << session["duration_slots"]) - 1) << slot
        building = self.room_buildings.get(room)
        cost = 0
        for group_week, weights, masks, buildings in self.groups[sid]:
            if group_week is not None and week is not None and group_week != week:
                continue
            before = masks[day]
            cost += weights[0] * (mask_gaps(before | mask) - mask_gaps(before))
            cost += weights[1] * (before == 0)
            used = buildings[day]
            if building is not None and used and building not in used:
                cost += weights[2]
        for partner in self.partners[sid]:
            if partner in self.starts:
                cost += int(self.weights["sequence"]) * slot_distance_penalty(
                    start,
                    session["duration_slots"],
                    self.starts[partner],
                    self.sessions[partner]["duration_slots"],
                    self.slots_per_day,
                )
        if sid in self.current:
            old_start, old_room, old_week = self.current[sid]
            moved = (start, room) != (old_start, old_room) or (
                old_week is not None and week != old_week
            )
            cost += max(0, int(self.weights.get("perturbation", 0))) * moved
        if not session["choose_week"]:
            cost += max(0, int(self.weights.get("excluded_days", 0))) * len(
                session["weeks"] & self.excluded.get(day, set())
            )
        if sid in self.balance:
            scale, terms = self.balance[sid]
            cost += int(self.weights.get("weekly_balance", 100)) * sum(
                abs(scale * (count + 1) - target) - abs(scale * count - target)
                for count, target in terms[week]
            )
            cost += (start, room) not in self.positions[sid]
        return cost

    def place(self, sid, start, room, week):
        day, slot = divmod(start, self.slots_per_day)
        mask = ((1 << self.sessions[sid]["duration_slots"]) - 1) << slot
        building = self.room_buildings.get(room)
        for group_week, _weights, masks, buildings in self.groups[sid]:
            if group_week is not None and week is not None and group_week != week:
                continue
            masks[day] |= mask
            if building is not None:
                buildings[day].add(building)
        self.starts[sid] = start
        if sid in self.balance:
            for term in self.balance[sid][1][week]:
                term[0] += 1
            self.positions[sid].add((start, room))


def add_assignment_hints(model, x, assignment, current):
    """Hint every choice of placed sessions, leaving unplaced sessions free."""
    for (sid, start, room), variable in x.items():
        if sid in assignment:
            model.add_hint(variable, int((start, room) == assignment[sid][:2]))
        elif sid in current:
            old = current[sid]
            if (start, room) == (old["slot_index"], old["room"]):
                model.add_hint(variable, 1)
    for (sid, start, room, week), variable in x.weekly.items():
        if sid in assignment:
            model.add_hint(variable, int((start, room, week) == assignment[sid]))


def add_assignment_variables(model, x, session, rooms):
    """Create the session's start/room choices and, for movable meetings, their
    week choices. Return the start/room choices."""
    session_id = session["id"]
    allowed_rooms = [
        room for room in candidate_rooms(session) if room is None or room in rooms
    ]
    variables = []
    # Indexes describe the variables added below. Drop a view cached earlier.
    x.views.clear()
    x._covering.clear()
    by_start = {}
    x.by_start[session_id] = by_start
    if session["choose_week"]:
        weekly_by_week = {}
        weekly_by_start = {}
        x.weekly_by_week[session_id] = weekly_by_week
        x.weekly_by_start[session_id] = weekly_by_start

    for slot_index in session["allowed_starts"]:
        for room in allowed_rooms:
            variable = model.new_bool_var(f"x_{session_id}_{slot_index}_{room}")
            x[(session_id, slot_index, room)] = variable
            by_start.setdefault(slot_index, []).append((room, variable))
            variables.append(variable)
            if session["choose_week"]:
                choices = []
                for week in sorted(session["weeks"]):
                    choice = model.new_bool_var(
                        f"week_{session_id}_{slot_index}_{room}_{week}"
                    )
                    x.weekly[(session_id, slot_index, room, week)] = choice
                    weekly_by_week.setdefault(week, []).append(choice)
                    weekly_by_start.setdefault(week, {}).setdefault(
                        slot_index, []
                    ).append((room, choice))
                    choices.append(choice)
                model.add(sum(choices) == variable)

    return variables


# Conflict search after a proof of infeasibility gets at most this long, at most
# half the time limit, and only the time left before the limit.
EXPLANATION_SECONDS = 30.0
MIN_CHECK_SECONDS = 0.01

# A room without other bookings. It stands in for every room outside a restricted list.
STAND_IN_ROOM = "*"

# Rules that restrict a session's starts. Allowed starts already apply them.
TIME_RULES = ("time_profile", "teacher_availability")

# The term model of the explanation builds in about this share of the main
# model's build time: a fifth to a third on 250- to 1500-session terms.
TERM_BUILD_SHARE = 0.25

# When several conflicts exist, QuickXplain keeps rules listed first. Rules that
# are hardest to change come first, so the explanation names rules that can give
# way. A teacher's load explains a short availability better than a room list.
RULE_PREFERENCE = (
    "teacher_load",
    "group_load",
    "other_terms",
    "non_teaching_dates",
    "teacher_availability",
    "lock",
    "time_profile",
    "allowed_rooms",
)


def explanation_deadline(deadline, time_limit):
    now = time.monotonic()
    return now + max(0.0, min(EXPLANATION_SECONDS, time_limit / 2, deadline - now))


def explain_infeasibility(spec, deadline, build_seconds=0.0):
    """Return a small set of rules that cannot hold together, and their sessions.

    Each rule an administrator can change, and each session's placement, is
    guarded by an assumption literal. CP-SAT returns a sufficient set of
    literals, trying forced local choices before the whole term, with each
    session's allowed starts as in the main model. Among those sessions the time
    rules are guarded too, and QuickXplain (Junker, AAAI 2004) shrinks the rules,
    then the sessions, to a minimal set in preference order. Return None when no
    conflict with a rule is proven within the budget. `build_seconds` is how long
    the main model took to build."""
    started = time.monotonic()
    if deadline - started <= MIN_CHECK_SECONDS:
        return None

    # Locating the conflict gets half of the budget, shrinking it the rest.
    halfway = started + (deadline - started) / 2
    core = None
    # Empty domains and forced room overlaps need only a few sessions to locate.
    for session_ids in forced_conflict_candidates(spec, halfway):
        core = locate_conflict(spec, session_ids, halfway, 0.1)
        if core is not None:
            break
    if core is None:
        *groups, whole_term = conflict_candidates(spec)
        # The term model has the main model's choices without its soft terms.
        if TERM_BUILD_SHARE * build_seconds < halfway - started:
            core = locate_conflict(spec, whole_term, halfway, 1.0)
        # A core over most of the term does not locate the conflict; a crowded set may.
        if core is None or 2 * len(core[0]) > len(whole_term):
            for session_ids in groups:
                if time.monotonic() > halfway:
                    break
                local = locate_conflict(spec, session_ids, deadline, 0.05)
                if local is not None:
                    core = local
                    break
    if core is None:
        return None
    try:
        return explain_sessions(spec, *core, deadline)
    except TimeoutError:
        return None


def forced_conflict_candidates(spec, deadline):
    """Yield empty local domains and sessions forced into the same room cell in
    a shared week.

    These are candidates only: the guarded model must still prove a conflict
    before any rules are reported."""
    grid = spec["grid"]
    days, slots = int(grid["days_count"]), int(grid["slots_per_day"])
    sessions = normalize_sessions(spec["sessions"], days, slots)
    fixed = normalize_placements(spec["fixed"], slots)
    excluded = normalize_excluded_cells(spec.get("excluded_cells", []))
    forced, forced_weeks = {}, {}
    for raw, session in zip(spec["sessions"], sessions):
        if time.monotonic() > deadline:
            return
        sid = session["id"]
        lock = fixed.get(sid)
        choices = (
            [(lock["slot_index"], lock["room"])]
            if lock
            else product(session["allowed_starts"], candidate_rooms(session))
        )
        weeks = lock["weeks"] if lock and session["choose_week"] else session["weeks"]
        blocked = {
            (
                (int(cell["day"]) - 1) * slots + int(cell["slot"]) - 1,
                normalize_room(cell.get("room")),
                int(cell["week"]) if "week" in cell else None,
            )
            for cell in raw.get("blocked_assignments", [])
        }
        usable = []
        for start, room in choices:
            if (start, room, None) in blocked:
                continue
            if session["choose_week"] and not any(
                (week, start // slots + 1) not in excluded
                and (start, room, week) not in blocked
                for week in weeks
            ):
                continue
            usable.append((start, room))
            if len(usable) == 2:
                break
        if not usable:
            yield (sid,)
        elif len(usable) == 1:
            start, room = usable[0]
            if room is not None:
                forced_weeks[sid] = set(weeks)
                for offset in range(session["duration_slots"]):
                    forced.setdefault((start + offset, room), []).append(sid)
    # Sessions in alternate weeks often share a room cell without a conflict.
    yield from sorted(
        {
            tuple(sorted(ids))
            for ids in forced.values()
            if any(forced_weeks[a] & forced_weeks[b] for a, b in combinations(ids, 2))
        },
        key=lambda ids: (len(ids), ids),
    )


def conflict_candidates(spec):
    """Return teacher, group and room session sets, most crowded first, then all sessions.

    Most conflicts stay within one such set, so a set can locate a conflict
    when the whole term cannot be checked in time."""
    grid = spec["grid"]
    sessions = {
        session["id"]: session
        for session in normalize_sessions(
            spec["sessions"], int(grid["days_count"]), int(grid["slots_per_day"])
        )
    }
    rules = (spec.get("explanation") or {}).get("rules", [])
    groups = [
        rule["session_ids"]
        for rule in rules
        if rule["kind"] in ("teacher_load", "group_load")
    ] or [group["session_ids"] for group in spec["hard"]["exclusive_groups"]]
    groups += [group["session_ids"] for group in spec["hard"]["room_groups"]]
    whole_term = tuple(sorted(sessions))

    def crowding(session_ids):
        members = [sessions[session_id] for session_id in session_ids]
        weeks = set().union(*(member["weeks"] for member in members))
        cells = {
            start + offset
            for member in members
            for start in member["allowed_starts"]
            for offset in range(member["duration_slots"])
        }
        demand = sum(
            member["duration_slots"]
            * (1 if member["choose_week"] else len(member["weeks"]))
            for member in members
        )
        return demand / max(1, len(cells) * len(weeks))

    unique = {
        tuple(sorted(str(session_id) for session_id in group))
        for group in groups
        if len(group) > 1
    } - {whole_term}
    local = [
        session_ids
        for session_ids in unique
        if all(session_id in sessions for session_id in session_ids)
    ]
    return sorted(local, key=lambda ids: (-crowding(ids), ids)) + [whole_term]


def locate_conflict(spec, session_ids, deadline, share):
    """Return the sessions and rule keys of a sufficient set of literals when the
    sessions cannot be placed at their allowed starts, or None without a proof.

    Allowed starts keep the time rules, so the model is as small as the main one."""
    try:
        search = ConflictSearch(spec, session_ids, deadline, relax_starts=False)
    except TimeoutError:
        return None
    core = search.infeasible(search.literals, share)
    if core is None:
        return None
    return (
        [
            session_id
            for session_id, literal in search.placed.items()
            if literal.index in core
        ],
        {rule_key(rule) for rule in search.rules if rule["literal"].index in core},
    )


def explain_sessions(spec, session_ids, rule_keys, deadline):
    """Return a minimal conflict among the given sessions, or None without a proof.

    Candidates are the given rules and the time rules of these sessions. Rules
    are shrunk while every session is placed. The other sessions of the rules
    left may conflict with fewer of them, so the rules are shrunk again with
    those sessions placed too. Then sessions are shrunk."""
    search = ConflictSearch(spec, session_ids, deadline)
    keys = search.minimal_rules(
        lambda rule: rule["kind"] in TIME_RULES or rule_key(rule) in rule_keys
    )
    if keys is None:
        return None

    wider = set(session_ids) | rule_sessions(spec, keys)
    if len(wider) > len(session_ids):
        now = time.monotonic()
        try:
            # Half of the time left stays for the conflict found so far.
            wide = ConflictSearch(spec, wider, deadline, now + (deadline - now) / 2)
        except TimeoutError:
            wide = None
        wide_keys = wide and wide.minimal_rules(lambda rule: rule_key(rule) in keys)
        # Without a rule, the wider sessions conflict over room capacity alone.
        if wide_keys:
            search, keys = wide, wide_keys
    return search.minimal_conflict(keys)


def rule_key(rule):
    return (rule["kind"], rule["id"])


def rule_sessions(spec, keys):
    """Return the sessions of the given rules. Term-wide rules list none."""
    return {
        str(session_id)
        for rule in (spec.get("explanation") or {}).get("rules", [])
        if (rule["kind"], str(rule["id"])) in keys
        for session_id in rule["session_ids"]
    }


class ConflictSearch:
    """Run infeasibility checks on the guarded model of some sessions."""

    def __init__(self, spec, session_ids, deadline, built_by=None, relax_starts=True):
        self.model, rules, self.placed = conflict_model(
            restrict_spec(spec, session_ids), relax_starts, built_by or deadline
        )
        self.rules = sorted(rules, key=lambda rule: RULE_PREFERENCE.index(rule["kind"]))
        # QuickXplain keeps earlier literals, so preferred rules come first.
        self.literals = [rule["literal"] for rule in self.rules] + list(
            self.placed.values()
        )
        self.deadline = deadline
        self.minimal = True

    def infeasible(self, literals, share):
        """Return the sufficient literal indices when the assumed literals are proven
        infeasible, otherwise None. An unfinished check counts as feasible: the
        result stays a conflict, but it may not be minimal."""
        remaining = self.deadline - time.monotonic()
        if remaining <= MIN_CHECK_SECONDS:
            self.minimal = False
            return None

        self.model.clear_assumptions()
        self.model.add_assumptions(literals)
        solver = cp_model.CpSolver()
        solver.parameters.max_time_in_seconds = max(
            remaining * share, MIN_CHECK_SECONDS
        )
        # Assumptions force one worker, and presolve would have to keep every
        # solution, which costs more than these checks. Propagation and the LP
        # relaxation prove most conflicts at once.
        solver.parameters.num_workers = 1
        solver.parameters.cp_model_presolve = False
        solver.parameters.cp_model_probing_level = 0
        solver.parameters.symmetry_level = 0
        solver.parameters.linearization_level = 2
        status = solver.solve(self.model)
        if status == cp_model.INFEASIBLE:
            return set(solver.sufficient_assumptions_for_infeasibility())
        if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            self.minimal = False
        return None

    def minimal_rules(self, candidate):
        """Return the keys of a minimal set of candidate rules that conflicts while
        every session is placed, or None without a proof."""
        rules = [rule["literal"] for rule in self.rules if candidate(rule)]
        sessions = list(self.placed.values())
        core = self.infeasible(rules + sessions, 0.5)
        if core is None:
            return None
        kept = {
            literal.index
            for literal in self.quickxplain(
                sessions, False, [literal for literal in rules if literal.index in core]
            )
        }
        return {rule_key(rule) for rule in self.rules if rule["literal"].index in kept}

    def minimal_conflict(self, keys):
        """Describe the given rules, which conflict while every session is placed,
        with a minimal set of their sessions."""
        rules = [rule["literal"] for rule in self.rules if rule_key(rule) in keys]
        sessions = list(self.placed.values())
        core = self.infeasible(rules + sessions, 0.5)
        if core is not None:
            sessions = self.quickxplain(
                rules, False, [literal for literal in sessions if literal.index in core]
            )
        return self.describe(rules + sessions)

    def quickxplain(self, background, added, candidates):
        """Return a minimal subset of candidates that conflicts with the background.

        Background and candidates together must be infeasible. When several
        conflicts exist, the result keeps earlier candidates."""
        if added and self.infeasible(background, 0.25) is not None:
            return []
        if len(candidates) <= 1:
            return candidates

        half = len(candidates) // 2
        first, second = candidates[:half], candidates[half:]
        second_core = self.quickxplain(background + first, True, second)
        first_core = self.quickxplain(
            background + second_core, bool(second_core), first
        )
        return first_core + second_core

    def describe(self, literals):
        indexes = {literal.index for literal in literals}
        session_ids = [
            session_id
            for session_id, literal in sorted(self.placed.items())
            if literal.index in indexes
        ]
        rules = [rule for rule in self.rules if rule["literal"].index in indexes]
        # Without a rule, only the grid and room capacity conflict.
        if not rules:
            return None

        return {
            "minimal": self.minimal,
            "rules": [
                {
                    "kind": rule["kind"],
                    "id": rule["id"],
                    "session_ids": [
                        session_id
                        for session_id in rule["session_ids"]
                        if session_id in session_ids
                    ],
                }
                for rule in rules
            ],
            "session_ids": session_ids,
        }


def restrict_spec(spec, session_ids):
    """Keep the given sessions and the rules, groups and locks that refer to them."""
    keep = {str(session_id) for session_id in session_ids}

    def only(group):
        return {
            **group,
            "session_ids": [
                session_id
                for session_id in group["session_ids"]
                if str(session_id) in keep
            ],
        }

    def among(groups):
        return [group for group in map(only, groups) if group["session_ids"]]

    restricted = {
        **spec,
        "sessions": [
            session for session in spec["sessions"] if str(session["id"]) in keep
        ],
        "fixed": {
            session_id: placement
            for session_id, placement in spec["fixed"].items()
            if str(session_id) in keep
        },
        "hard": {
            "room_groups": among(spec["hard"]["room_groups"]),
            "exclusive_groups": among(spec["hard"]["exclusive_groups"]),
        },
    }
    if "explanation" in spec:
        restricted["explanation"] = {"rules": among(spec["explanation"]["rules"])}
    return restricted


def conflict_model(spec, relax_starts=True, deadline=None):
    """Build the hard rules with one assumption literal per rule an administrator
    can change, and one literal per session that requires its placement.

    With every literal true, the model allows the same placements as the main
    model. A false rule literal removes or loosens its rule: starts may use the
    whole grid, and sessions of a restricted room list may use a stand-in room.
    Looser rules keep every conflict found here a conflict of the real rules.
    Without `relax_starts`, sessions keep their allowed starts and time rules
    get no literal. Raise TimeoutError when building passes the deadline."""
    grid = spec["grid"]
    days_count = int(grid["days_count"])
    slots_per_day = int(grid["slots_per_day"])
    slot_count = days_count * slots_per_day
    rooms = {str(room["id"]) for room in spec["rooms"]} | {STAND_IN_ROOM}
    explanation = spec.get("explanation")
    rule_specs = [] if explanation is None else explanation["rules"]
    restricted_rooms = {
        str(session_id)
        for rule in rule_specs
        if rule["kind"] == "allowed_rooms"
        for session_id in rule["session_ids"]
    }

    raw_sessions = []
    for raw in spec["sessions"]:
        raw = dict(raw)
        if explanation is not None and relax_starts:
            # Time rules are guarded below, so every start that fits the grid is a candidate.
            raw.pop("allowed_starts", None)
        if str(raw["id"]) in restricted_rooms:
            raw["allowed_rooms"] = [*raw["allowed_rooms"], STAND_IN_ROOM]
        raw_sessions.append(raw)

    sessions = normalize_sessions(raw_sessions, days_count, slots_per_day)
    sessions_by_id = {session["id"]: session for session in sessions}
    model = cp_model.CpModel()
    x = AssignmentVariables(sessions)
    placed = {}
    for session in sessions:
        stop_at(deadline)
        variables = add_assignment_variables(model, x, session, rooms)
        literal = model.new_bool_var(f"placed_{session['id']}")
        total = cp_model.LinearExpr.sum(variables) if variables else 0
        model.add(total == 1).only_enforce_if(literal)
        model.add(total == 0).only_enforce_if(~literal)
        placed[session["id"]] = literal

    rules = []

    def guard(kind, rule_id, variables_by_session):
        """Forbid the given choices while the new rule literal is true."""
        if not any(variables_by_session.values()):
            return
        literal = model.new_bool_var(f"rule_{len(rules)}")
        for variables in variables_by_session.values():
            for variable in variables:
                model.add_implication(variable, ~literal)
        rules.append(
            {
                "kind": kind,
                "id": rule_id,
                "session_ids": sorted(
                    session_id
                    for session_id, variables in variables_by_session.items()
                    if variables
                ),
                "literal": literal,
            }
        )

    choices_by_session = {}
    for (session_id, start, room), variable in x.items():
        choices_by_session.setdefault(session_id, []).append((start, room, variable))

    def guard_choices(kind, rule_id, members, forbidden):
        guard(
            kind,
            rule_id,
            {
                session["id"]: [
                    variable
                    for start, room, variable in choices_by_session.get(
                        session["id"], []
                    )
                    if forbidden(session, start, room)
                ]
                for session in members
            },
        )

    for rule in rule_specs:
        stop_at(deadline)
        members = [
            sessions_by_id[str(session_id)]
            for session_id in rule["session_ids"]
            if str(session_id) in sessions_by_id
        ]
        kind = rule["kind"]
        if kind == "time_profile":
            starts = flat_cells(rule["starts"], slots_per_day)
            guard_choices(
                kind,
                str(rule["id"]),
                members,
                lambda _session, start, _room: start not in starts,
            )
        elif kind == "teacher_availability":
            cells = flat_cells(rule["cells"], slots_per_day)
            # Empty availability does not restrict the teacher.
            if cells:
                guard_choices(
                    kind,
                    str(rule["id"]),
                    members,
                    lambda session, start, _room: any(
                        start + offset not in cells
                        for offset in range(session["duration_slots"])
                    ),
                )
        elif kind == "allowed_rooms":
            guard_choices(
                kind,
                str(rule["id"]),
                members,
                lambda _session, _start, room: room == STAND_IN_ROOM,
            )
        elif kind in ("teacher_load", "group_load") and len(members) > 1:
            literal = model.new_bool_var(f"rule_{len(rules)}")
            add_exclusive_group_constraints(
                model,
                x,
                [{"session_ids": [session["id"] for session in members]}],
                sessions_by_id,
                slot_count,
                slots_per_day,
                set(),
                literal,
            )
            rules.append(
                {
                    "kind": kind,
                    "id": str(rule["id"]),
                    "session_ids": sorted(session["id"] for session in members),
                    "literal": literal,
                }
            )

    seen = set()
    for group in spec["hard"]["room_groups"]:
        stop_at(deadline)
        add_room_group_constraints(
            model, x, [group], sessions_by_id, slot_count, slots_per_day, seen
        )
    if explanation is None:
        # Without rule identities, teacher and group overlaps stay fixed.
        add_exclusive_group_constraints(
            model,
            x,
            spec["hard"]["exclusive_groups"],
            sessions_by_id,
            slot_count,
            slots_per_day,
        )

    blocked = {}
    for session in spec["sessions"]:
        for cell in session.get("blocked_assignments", []):
            key = (
                str(session["id"]),
                (int(cell["day"]) - 1) * slots_per_day + int(cell["slot"]) - 1,
                normalize_room(cell.get("room")),
            )
            variable = (
                x.weekly.get((*key, int(cell["week"])))
                if "week" in cell
                else x.get(key)
            )
            if variable is not None:
                blocked.setdefault(key[0], []).append(variable)
    guard("other_terms", None, blocked)

    excluded = normalize_excluded_cells(spec.get("excluded_cells", []))
    dated = {}
    for (session_id, start, _room, week), variable in x.weekly.items():
        if (week, start // slots_per_day + 1) in excluded:
            dated.setdefault(session_id, []).append(variable)
    guard("non_teaching_dates", None, dated)

    for session_id, placement in normalize_placements(
        spec["fixed"], slots_per_day
    ).items():
        key = (session_id, placement["slot_index"], placement["room"])
        if key not in x:
            continue
        variables = [x[key]]
        weeks = placement.get("weeks", [])
        if sessions_by_id[session_id]["choose_week"] and len(weeks) == 1:
            variables.append(x.weekly[(*key, weeks[0])])
        literal = model.new_bool_var(f"rule_{len(rules)}")
        for variable in variables:
            # An unplaced session in the session search does not keep its lock.
            model.add(variable == 1).only_enforce_if([literal, placed[session_id]])
        rules.append(
            {
                "kind": "lock",
                "id": session_id,
                "session_ids": [session_id],
                "literal": literal,
            }
        )

    return model, rules, placed


def stop_at(deadline):
    """Raise TimeoutError once the deadline, if any, has passed."""
    if deadline is not None and time.monotonic() > deadline:
        raise TimeoutError("explanation deadline passed")


def flat_cells(cells, slots_per_day):
    """Convert 1-based day/slot cells to 0-based flattened grid indexes."""
    return {
        (int(cell["day"]) - 1) * slots_per_day + int(cell["slot"]) - 1 for cell in cells
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
        add_overlap_constraints(
            model,
            x,
            sessions,
            [str(group["room_id"])],
            range(slot_count),
            slots_per_day,
            seen,
        )


def add_exclusive_group_constraints(
    model, x, groups, sessions_by_id, slot_count, slots_per_day, seen=None, enforce=None
):
    """Prevent teacher and cohort conflicts in every occupied slot and teaching week.
    Check all rooms."""
    seen = set() if seen is None else seen
    for group in groups:
        sessions = [sessions_by_id[session_id] for session_id in group["session_ids"]]
        add_overlap_constraints(
            model,
            x,
            sessions,
            None,
            range(slot_count),
            slots_per_day,
            seen,
            enforce,
        )


def add_overlap_constraints(
    model, x, sessions, rooms, slots, slots_per_day, seen, enforce=None
):
    """Post one group's at-most-one constraints for every slot in `slots`.

    Week membership is prepared once. Each slot reuses the sessions' covering
    index, in the same start and room order as the per-slot scan.
    """
    if not sessions:
        return
    memberships = overlap_memberships(x, sessions)
    by_id = {session["id"]: session for session in sessions}
    plans = []
    for week, session_ids in memberships:
        plans.append(
            [
                x.covering(by_id[session_id], slots_per_day, week, rooms)
                for session_id in session_ids
            ]
        )
    for slot_index in slots:
        for covers in plans:
            variables = []
            for covered in covers:
                found = covered.get(slot_index)
                if found:
                    variables.extend(found)
            if len(variables) <= 1:
                continue
            key = tuple(sorted(variable.index for variable in variables))
            if key in seen:
                continue
            if enforce is None:
                model.add_at_most_one(variables)
            else:
                model.add(sum(variables) <= 1).only_enforce_if(enforce)
            seen.add(key)


def overlap_memberships(x, sessions):
    """Return (week, session ids) in the order overlap constraints are posted.

    The pairs are the sorted set the per-slot loop used to build. Movable
    meetings keep one pair per week. A repeated pair in which nobody chooses a
    week uses the same variables every time, so later copies are omitted; the
    seen set would have dropped those constraints.
    """
    labelled = bool(x.weekly)
    memberships = sorted(
        {
            (
                week if labelled else None,
                tuple(
                    session["id"] for session in sessions if week in session["weeks"]
                ),
            )
            for week in set().union(*(session["weeks"] for session in sessions))
        }
    )
    if not labelled:
        return memberships

    choosers = {session["id"] for session in sessions if session["choose_week"]}
    kept = []
    seen_ids = set()
    for week, session_ids in memberships:
        if choosers.isdisjoint(session_ids):
            if session_ids in seen_ids:
                continue
            seen_ids.add(session_ids)
            kept.append((None, session_ids))
        else:
            kept.append((week, session_ids))
    return kept


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
                for _room, variable in x.by_start.get(session["id"], {}).get(
                    slot_index, ()
                ):
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
    """Keep week identity when a meeting can move between weeks.

    A week whose sessions all meet in it and none can move has the same
    variables as every other such week, so those weeks share one expression."""
    if not getattr(x, "weekly", {}):
        return [(x, ids, count) for ids, count in weighted_groups(groups)]

    grouped = Counter()
    for group in groups:
        week = int(group["week"])
        ids = tuple(sorted(group["session_ids"]))
        shared = all(
            week in x.sessions[session_id]["weeks"]
            and not x.sessions[session_id]["choose_week"]
            for session_id in ids
        )
        grouped[(None if shared else week, ids)] += 1
    return [
        (x if week is None else x.for_week(week), ids, count)
        for (week, ids), count in sorted(
            grouped.items(), key=lambda item: (item[0][0] or 0, item[0][1])
        )
    ]


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
            variables = []
            for session in group:
                variables.extend(x.weekly_by_week.get(session["id"], {}).get(week, ()))
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
        for session in group:
            by_start = x.by_start.get(session["id"], {})
            for start in session["allowed_starts"]:
                for room, variable in by_start.get(start, ()):
                    positions.setdefault((start, room), []).append(variable)
        for position, variables in positions.items():
            used = model.new_bool_var(f"recurring_{index}_{position}")
            model.add_max_equality(used, variables)
            terms.append(used)
        # A single meeting has no partner to order, so the sums would be unused.
        if (
            len(group) > 1
            and not ids.intersection(existing_ids)
            and all(
                (
                    session["weeks"],
                    session["allowed_starts"],
                    session["allowed_rooms"],
                )
                == (
                    group[0]["weeks"],
                    group[0]["allowed_starts"],
                    group[0]["allowed_rooms"],
                )
                for session in group
            )
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
                variable
                for _room, variable in x.by_start.get(left["id"], {}).get(
                    left_start, ()
                )
            ]
            right_variables = [
                variable
                for _room, variable in x.by_start.get(right["id"], {}).get(
                    right_start, ()
                )
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
