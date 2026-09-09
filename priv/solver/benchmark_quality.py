"""Compare staged search with an unrestricted weighted objective on exported specs.

Does not connect to the database. JSON output contains assignments and per-stage
bounds. The weighted reference changes priorities and is not a production mode.
"""

import argparse
import copy
import json
import hashlib
import platform
import ortools
import time
from collections import defaultdict
from pathlib import Path
from unittest.mock import patch

import solve
from ortools.sat.python import cp_model


def metrics(spec, assignment):
    """Count costs directly from placements, including each resource/week."""
    sessions = {s["id"]: s for s in spec["sessions"]}
    buildings = {r["id"]: r["building_id"] for r in spec["rooms"]}
    counts = dict(
        gaps=0, active_days=0, building=0, perturbation=0, excluded_days=0, sequence=0
    )
    for field, metric in [
        ("gap_groups", "gaps"),
        ("active_day_groups", "active_days"),
        ("building_groups", "building"),
    ]:
        for group in spec["soft"][field]:
            days = defaultdict(list)
            for sid in group["session_ids"]:
                days[assignment[sid]["day"]].append(sid)
            for ids in days.values():
                if metric == "active_days":
                    counts[metric] += 1
                elif metric == "building":
                    counts[metric] += (
                        len({buildings[assignment[sid]["room"]] for sid in ids}) - 1
                    )
                else:
                    slots = {
                        slot
                        for sid in ids
                        for slot in range(
                            assignment[sid]["slot"],
                            assignment[sid]["slot"]
                            + sessions[sid].get("duration_slots", 1),
                        )
                    }
                    counts[metric] += max(slots) - min(slots) + 1 - len(slots)
    normalized = solve.normalize_sessions(
        spec["sessions"], spec["grid"]["days_count"], spec["grid"]["slots_per_day"]
    )
    domain = {s["id"]: s for s in normalized}
    for sid, old in spec["current"].items():
        start = (old["day"] - 1) * spec["grid"]["slots_per_day"] + old["slot"] - 1
        if (
            start in domain[sid]["allowed_starts"]
            and old["room"] in domain[sid]["allowed_rooms"]
        ):
            counts["perturbation"] += assignment[sid] != old
    for cell in {tuple((c["week"], c["day"])) for c in spec.get("excluded_cells", [])}:
        counts["excluded_days"] += sum(
            cell[0] in s["weeks"] and assignment[sid]["day"] == cell[1]
            for sid, s in sessions.items()
        )
    for pair in spec["soft"]["sequence_pairs"]:
        a, b = pair["left"], pair["right"]
        left, right = assignment[a], assignment[b]
        if left["day"] != right["day"]:
            distance = spec["grid"]["slots_per_day"]
        else:
            end_a = left["slot"] + sessions[a].get("duration_slots", 1)
            end_b = right["slot"] + sessions[b].get("duration_slots", 1)
            if end_a == right["slot"] or end_b == left["slot"]:
                distance = 0
            elif end_a < right["slot"]:
                distance = right["slot"] - end_a + 1
            elif end_b < left["slot"]:
                distance = left["slot"] - end_b + 1
            else:
                distance = 1
        counts["sequence"] += distance
    counts["weighted_cost"] = sum(
        counts[k] * spec["soft"]["weights"].get(k, 0) for k in counts
    )
    return counts


def validate(spec, assignment):
    """Check assignment domains, locks, blocked bookings and overlapping resources."""
    sessions = solve.normalize_sessions(
        spec["sessions"], spec["grid"]["days_count"], spec["grid"]["slots_per_day"]
    )
    assert set(assignment) == {s["id"] for s in sessions}, "missing/extra sessions"
    cells = {}
    for s in sessions:
        p = assignment[s["id"]]
        start = (p["day"] - 1) * spec["grid"]["slots_per_day"] + p["slot"] - 1
        assert start in s["allowed_starts"] and p["room"] in s["allowed_rooms"], (
            "outside domain"
        )
        cells[s["id"]] = {
            (w, p["day"], slot)
            for w in s["weeks"]
            for slot in range(p["slot"], p["slot"] + s["duration_slots"])
        }
    assert all(assignment[sid] == p for sid, p in spec["fixed"].items()), "lock changed"
    for s in spec["sessions"]:
        assert assignment[s["id"]] not in s.get("blocked_assignments", []), (
            "blocked booking"
        )
    for group in spec["hard"]["exclusive_groups"] + spec["hard"]["room_groups"]:
        used = set()
        for sid in group["session_ids"]:
            if "room_id" in group and assignment[sid]["room"] != group["room_id"]:
                continue
            assert not used.intersection(cells[sid]), "resource conflict"
            used.update(cells[sid])


def run(spec, budget, reference=False):
    spec = copy.deepcopy(spec)
    spec["solver"]["time_limit"] = budget
    stages, capture = [], {}
    original_configure, original_active = (
        solve.configured_solver,
        solve.active_day_terms,
    )
    started = time.monotonic()

    def active(*args):
        terms = original_active(*args)
        capture["active"] = terms
        return terms

    class Recorder:
        def __init__(self, config, limit):
            self.solver = original_configure(config, limit)

        def solve(self, model):
            if not stages:
                capture["model"] = model.clone()
                capture["build_seconds"] = time.monotonic() - started
            status = self.solver.solve(model)
            feasible = status in (cp_model.OPTIMAL, cp_model.FEASIBLE)
            stages.append(
                dict(
                    status=self.solver.status_name(status),
                    objective=self.solver.objective_value if feasible else None,
                    lower_bound=self.solver.best_objective_bound,
                    seconds=self.solver.wall_time,
                )
            )
            return status

        def __getattr__(self, key):
            return getattr(self.solver, key)

    with (
        patch.object(solve, "active_day_terms", side_effect=active),
        patch.object(solve, "configured_solver", side_effect=Recorder),
    ):
        result = solve.cp_sat_solve(spec, started)
    result["stages"] = stages
    result["budget"] = budget
    result["build_seconds"] = capture.get("build_seconds")
    if result["ok"]:
        validate(spec, result["assignment"])
        result["metrics"] = metrics(spec, result["assignment"])
    if not reference or "model" not in capture:
        return dict(staged=result)

    model = capture["model"]
    # Stage one omits active days only when both types of objective are present.
    if capture["active"] and not any(
        model.proto.variables[index].name.startswith("active_day_")
        for index in model.proto.objective.vars
    ):
        objective = model.proto.objective
        assert objective.scaling_factor == 1
        full = sum(
            coef * model.get_int_var_from_proto_index(index)
            for index, coef in zip(objective.vars, objective.coeffs)
        ) + int(objective.offset)
        model.minimize(full + sum(capture["active"]))
    solver = original_configure(
        spec["solver"], max(0.01, budget - capture["build_seconds"])
    )
    status = solver.solve(model)
    feasible = status in (cp_model.OPTIMAL, cp_model.FEASIBLE)
    reference_result = dict(
        status=solver.status_name(status),
        objective=solver.objective_value if feasible else None,
        lower_bound=solver.best_objective_bound,
        wall_time=solver.wall_time + capture["build_seconds"],
        assignment={},
    )
    if feasible:
        variables = {
            v.name: model.get_bool_var_from_proto_index(i)
            for i, v in enumerate(model.proto.variables)
            if v.name.startswith("x_")
        }
        for s in solve.normalize_sessions(
            spec["sessions"], spec["grid"]["days_count"], spec["grid"]["slots_per_day"]
        ):
            for start in s["allowed_starts"]:
                for room in s["allowed_rooms"]:
                    v = variables.get(f"x_{s['id']}_{start}_{room}")
                    if v is not None and solver.boolean_value(v):
                        reference_result["assignment"][s["id"]] = (
                            solve.slot_to_day_slot(
                                start, spec["grid"]["slots_per_day"], room
                            )
                        )
        validate(spec, reference_result["assignment"])
        reference_result["metrics"] = metrics(spec, reference_result["assignment"])
    return dict(staged=result, weighted_reference=reference_result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", type=Path)
    parser.add_argument("--budgets", type=float, nargs="+", default=[1, 5, 15])
    parser.add_argument("--reference", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    spec = json.loads(args.spec.read_text())
    report = dict(
        spec=str(args.spec),
        sessions=len(spec["sessions"]),
        solver=spec["solver"],
        solver_sha256=hashlib.sha256(Path(solve.__file__).read_bytes()).hexdigest(),
        spec_sha256=hashlib.sha256(args.spec.read_bytes()).hexdigest(),
        python=platform.python_version(),
        ortools=ortools.__version__,
        runs=[],
    )
    known = spec.get("benchmark", {}).get("known_assignment")
    if known is not None:
        validate(spec, known)
        report["known_metrics"] = metrics(spec, known)
        print(json.dumps({"known_metrics": report["known_metrics"]}), flush=True)
    for budget in args.budgets:
        result = run(spec, budget, args.reference)
        report["runs"].append(result)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        summary = {
            k: {f: v for f, v in r.items() if f != "assignment"}
            for k, r in result.items()
        }
        print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
