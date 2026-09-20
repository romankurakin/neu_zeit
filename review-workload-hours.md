# Review: semester hours and weekly series

21 September 2026. Review of `plan-workload-hours.md` against the pre-implementation working tree and official scheduling-product documentation. The findings below describe that baseline; the approved MVP implementation is recorded next.

## Implemented MVP

New workload entries now generate weekly series. Required hours remain unchanged; a persisted choice selects the next higher or lower positive whole-meeting count, defaulting upward. The form previews planned hours, the difference and actual weeks. When both parities provide the same count, the administrator can choose odd or even term weeks. Positive requirements smaller than one meeting produce one meeting, with the excess visible before saving.

The same reconciliation builds the preview and saved series. Unchanged valid manual decompositions survive, compatible series retain their identities, and changed masks update draft/active placements through existing schedule validation. Archived placement dates remain unchanged. Removing a series with any placement or exception history rejects the edit transactionally.

Existing automatic workloads retain their mode, identities and plan-specific weeks. The overloaded flag remains for compatibility; removing it and converting old plans are deferred. A one-time migration preserves legacy counts affected by float conversion, without introducing a tolerance for new requirements. No shorter final meeting, automatic holiday compensation or freeform series-pattern editor is introduced in this MVP.

The model and UI checks cover the 45-hour case, saved rounding choices, parity conflicts, manual masks, placement/history preservation, migration compatibility and actual solver runs over 15 weeks for one and five courses. The original exploratory benchmark is separate from these regression tests.

The follow-up code review identified three defects: preview and save used different protection ordering, a capacity error hid a valid lower rounding choice, and a reloaded requirement could calculate with the wrong academic-hour unit. These are fixed through an explicit semester context and one pure distribution proposal, with placement/history protections included in the editing snapshot. Save reloads that context and rejects stale edits. The proposal also rejects missing or foreign snapshots for existing requirements.

The implementation now separates the `Workload` schema, pure `WorkloadDistribution`, `WorkloadSnapshot` read model and transactional `Workloads` service. Requirement metadata no longer impersonates a `Session`; meeting and series counts are computed explicitly. See [the module contracts](docs/workload-model.md).

Final validation on a separate test database: all 497 tests passed, with four exploratory benchmark tests excluded. Compilation with warnings as errors, repository formatting, the diff whitespace check and the interface asset build passed. Localized plural counts, irregular week labels, validation field names and selecting a feasible rounding option are covered by interface tests. Week labels and validation messages reuse the shared components; styling uses the existing Tailwind/DaisyUI theme. The old test expecting a fifth built-in teaching type was corrected to the four types created by the original migration; application behavior did not change. The independent reviewer found no remaining blocker in the revised module boundaries. The change has not been deployed.

## Original design review

The proposed separation of teaching requirements, recurring series, placements and dated occurrences is a sound foundation. The generation policy and migration contract are not ready to implement as written. Several rules contradict each other, and the benchmark supports a narrower conclusion than the plan claims.

## A more accurate problem statement

The administrator enters required academic hours for a semester. The application currently converts those hours directly into identical, indivisible meetings, then asks the solver to choose each meeting's week, day, time and room. This creates two separate problems.

First, some requirements cannot be represented exactly with the selected meeting duration. On a grid with 90 teaching minutes per slot and 45 minutes per academic hour, a one-slot meeting contributes two academic hours. A requirement of 45 hours cannot be represented by an integer number of such meetings. This is a mismatch between the required volume and the available duration units. Weekly series alone do not resolve it; rounding, a shorter meeting, or another explicitly accepted accounting policy is still needed.

Second, the required output is a stable repeating timetable, but the solver searches over independently movable meetings and only encourages repetition through penalties. The existing proof of concept reports failure to find a solution within the budget on small semester examples, while fixed week patterns reduce the search substantially. This is evidence against the current formulation and defaults for this use case. It does not prove that all scheduling models based on individual meetings are unsuitable.

The data model already separates requirements, sessions, placements and dated exceptions. Its main ambiguity is that `automatic_weeks` changes the meaning of a session's week mask and of workload quantity. A series with a fixed set of weeks would give every session one meaning. The remaining design work is to define how the required hours become series, how manual changes survive reconciliation, and how plan variants and dated history survive migration.

## What the current code confirms

- [Workload.count_from_hours](lib/neu_zeit/catalog/workload.ex) rejects non-integral meeting counts. New workloads default to automatic meetings; the public changeset does not accept changing that flag.
- [SpecBuilder](lib/neu_zeit/solver/spec_builder.ex) expands an automatic session into candidate singleton week masks. [The solver](priv/solver/solve.py) creates week-specific assignment variables in addition to day/time/room variables.
- The regularity penalty is one per distinct `(start, room)`, while weekly balance has a default weight of 100. Those are different expressions with different scales, so their weights alone do not quantify the tradeoff.
- [Workload.prepare and check](lib/neu_zeit/catalog/workload.ex) currently require generated sessions to match both the expected row count and the workload attributes, including the same week mask. They must change together when one workload owns several different masks.
- [Curriculum](lib/neu_zeit/curriculum.ex) already distinguishes required, planned and calendar hours. Planned hours include unplaced sessions. Calendar hours are projected from placements and exceptions; they are scheduled hours, not evidence that teaching actually happened.

## Issues to resolve before implementation

### 1. Preserve the original requirement when choosing a rounded result

The plan suggests entering 44 instead of 45 to obtain an even-week remainder. That changes the source requirement. The coverage report would then compare against 44 and lose the original discrepancy.

Keep `contact_hours = 45` when the curriculum says 45. Separately describe the planning choice: 23 meetings and 46 planned hours, or an accepted alternative of 22 meetings and 44 hours. Record or derive the difference from the unchanged requirement. If alternatives are selectable, save enough information to reproduce the chosen target during `prepare/1`.

Rounding needs more than a tie rule. For a four-hour meeting, a positive requirement of one hour rounds to zero meetings. A five-hour requirement rounds down to four. Decide whether underdelivery is permitted and what happens when the target is zero. Do not silently clamp every positive requirement to one meeting.

If exactly 45 hours must be delivered, a uniform 90-minute grid cannot express the final single academic hour. That requires finer time units, a shorter-meeting representation, or a different institution-approved accounting rule. This remains an institution decision, not a technical conclusion from the benchmark.

### 2. Validation and reconciliation currently describe different valid models

The proposed `check/1` accepts any masks whose total meeting count equals the target. The proposed reconciler recognizes only full-mask series and one remainder. Migration can create several singleton series, and a valid manual arrangement can also contain several partial masks. Those arrangements cannot be handled reliably by the proposed matching rule.

For example, a 30-hour requirement over 15 weeks can have one series on weeks 1–7 and another on weeks 8–15. The count is correct, both masks are inside the permitted range, and the arrangement can be necessary when the available time changes mid-semester. The proposed check accepts it. A save that insists on one full-mask series would replace it or fail if its series are already placed.

The invariant must also require each series mask to be a nonempty subset of the workload's allowed weeks. Equal cardinality alone would allow a manual remainder to move outside the allowed range. Validate normalized, unique week numbers before using `length(M)` in generation.

Recommended contract: the default policy proposes an initial decomposition. A valid existing decomposition survives preparation unchanged. Rebuilding its rhythm is an explicit operation. Hour edits retain identifiable compatible series and report a conflict when protected series prevent the requested change. Define separately what happens when duration, allowed weeks or resources change. Do not identify a series solely as “the only mask different from M.”

Useful property: if `check/1` accepts a workload, an unchanged save and `prepare/1` preserve its series IDs, masks, placements and exceptions.

### 3. One session can have different selected weeks in different plans

Currently the session belongs to the semester, while placements belong to plans. The unique placement key is `(plan_id, session_id)`, and an automatic session can be placed in week 1 in one draft and week 2 in another. The proposed migration says to use “its placement week,” but no single week exists in this case.

One global fixed session mask cannot equal both `[1]` and `[2]`. Taking their union would add a meeting to each plan. Cloning sessions without changing ownership also makes each plan responsible for additional sessions.

Decide whether week patterns are shared by all plan variants. Keeping the current term-wide series design is reasonable if that is the intended product rule. Migration must then detect incompatible variants and use an explicit resolution policy. If comparing different week patterns across plans is required, introduce a plan-specific realization of the requirement; simply deleting the flag is insufficient.

The pre-migration audit needs distinct selected masks per session across draft, active and archived plans, locked placements, and active or historical exceptions. Counting placed automatic sessions alone does not establish that regeneration is safe. An unplaced session may still have a dated addition, and deleting it can cascade exception history.

### 4. Do not subtract whole weeks when preserving placed meetings

The migration proposes generating remaining demand on `M` minus weeks containing preserved placements. A week is not used up by one meeting.

Counterexample: four meetings are required over two weeks, with capacity for two per week. One meeting is already placed in week 1. The proposed subtraction leaves only week 2 and puts all three remaining meetings there. A valid completion exists: one more in week 1 and two in week 2.

Subtract preserved meeting counts from demand, and account for their resource occupancy when distributing the remainder. Do not remove a week merely because it contains a retained meeting. If preserving several singletons prevents the usual compact decomposition, preserve the valid decomposition or require an explicit rebalance.

### 5. Defaulting every remainder to odd weeks can create avoidable infeasibility

Over 16 weeks, two courses each need eight meetings and share one available weekly slot. Both on odd weeks is impossible; one on odd and one on even weeks fits exactly.

This was reproduced with the current solver: identical odd masks returned `INFEASIBLE`; changing the second mask to even returned `OPTIMAL`. The conflict is caused by pattern selection before solving, not by insufficient semester capacity.

For a first version, make parity selectable and explain when the chosen patterns cause a conflict. A later extension can let the solver choose among a small set of allowed patterns without returning to an independent week choice for every meeting. [UniTime's alternative date-pattern sets](https://help.unitime.org/date-patterns) provide a relevant example of this distinction.

The bound `k + (r > 0)` is only a coarse necessary capacity check for the default decomposition. With manual or migrated masks, inspect the maximum number of simultaneous series in each week. Neither bound proves feasibility under teacher availability, time profiles or shared rooms.

### 6. An external booking does not automatically cancel an occurrence

The plan says a booking on one date cancels that occurrence of a series. That is not the current behavior. [SharedResources.blocked?](lib/neu_zeit/planning/shared_resources.ex) rejects a candidate if any projected occurrence conflicts with an external booking. [SpecBuilder](lib/neu_zeit/solver/spec_builder.ex) then forbids that day/time/room for the entire series. No cancellation exception is created.

The current rule is coherent: resources must be available for every occurrence of the selected series. Document that rule. Automatic cancellation would be a separate feature affecting calendar hours, conflict checks and exceptions, and would need an explicit contract.

Keep holidays separate from resource conflicts. The current projection excludes term holidays and dates outside the term; that does not imply that it can discard a real meeting whenever another resource booking conflicts.

### 7. The benchmark's regularity metric is invalid for the proposed ownership model

[The series builder](test/neu_zeit/poc_series_vs_meetings_test.exs) calls `session_fixture` once per series. [That fixture](test/support/fixtures.ex) creates a new workload on every call. The metric then groups placements by `workload_id`, so every series workload has exactly one placement and therefore exactly one time.

For the one-group scenario, the meetings version has five workload rows; the series version has six. Under the proposed model, the 46-hour workload has one full-week series and one odd-week series. They overlap on odd weeks and therefore require two distinct times for their shared teacher and group. “One time per workload” is not the correct expected result.

The proof of concept also uses different remainder masks from the proposal. For eight meetings in 15 weeks, its formula generates `[1, 2, 4, 6, 8, 10, 12, 14]`, not odd weeks. For five, it generates `[1, 4, 7, 10, 13]`, not `[2, 5, 8, 11, 14]`.

The reduction from 52 decision entities to six is real and useful. The measured elapsed times remain evidence about those particular instances. They do not validate the exact proposed policy, production scalability or the claimed workload-level regularity.

Before making this a regression test, keep the same logical requirements in both cases, use the actual proposed masks, and group measurements by those requirements. Check stable recurring positions, delivered meeting count, hard constraints, worst weekly load, calendar losses and time to a feasible solution. Test constrained and larger cases as well as the current small example. A short-budget `OPTIMAL` assertion can be retained for a controlled tiny case; it is not a production acceptance criterion.

### 8. Exact arithmetic and reporting need an explicit contract

There is no mathematical requirement that one slot contain an integer number of academic hours. A 45-minute slot with a 60-minute reporting hour contributes 0.75 hours; four slots contribute exactly three. Requiring divisibility may be a product restriction, but it does not solve indivisible demand in general: 45 hours still cannot be expressed exactly in two-hour meetings.

Calculate using teaching minutes and exact decimal or rational arithmetic. The current conversion to a float is unnecessary for the new rounding policy. The term grid already requires equal slot durations and locks time settings once scheduling data exists.

Report three separate differences: generation versus required hours, placed versus generated hours, and calendar projection versus placed template hours. Otherwise an accepted rounding difference and a lost holiday meeting can cancel numerically and appear satisfactory.

The current report aggregates by course and cohort, and its status accepts a difference of one slot. Consequently a missing two-hour meeting may still show an acceptable status; a lecture deficit can also be offset by a seminar surplus. Preserve per-workload or per-component detail when checking the new policy. A positive summary status is not proof that the requirement was delivered exactly.

## Recommended model and invariants

| Object | Meaning | Main invariant |
|---|---|---|
| Workload | Source requirement for a component, teacher and cohorts, with required academic hours and allowed weeks | Required hours remain independent of the generated or scheduled total |
| Series | One recurring meeting at one weekly position on an explicit set of weeks | Nonempty normalized mask within the workload's allowed weeks; positive duration |
| Placement | A series assigned to a day, start and room in a plan | At most one per `(plan, series)`; current placement mask and duration agree with the series |
| Dated occurrence | A projected meeting after term boundaries, holidays and exceptions | Calendar hours are derived from surviving and added occurrences |
| Exception | An explicit change to a dated occurrence or addition | Its session identity and origin remain valid after changes |

This model can represent a one-off meeting as a series with one week. Removing the overloaded flag need not remove one-off scheduling as a domain capability.

For uniform-duration series, let `a` be minutes per academic hour, `s` teaching minutes per slot, `d` slots per meeting, and `W_j` the mask of series j. Then `u = d * s / a`, generated meeting count is `sum(length(W_j))`, and planned hours are `u * sum(length(W_j))`. Apply the chosen rounding policy to the requirement to obtain the target meeting count. If variable-duration final meetings become necessary, validate the sum of each series' own duration instead.

Do not store independent mutable copies of inherited teacher, cohorts, component or duration without a clear synchronization rule. Either inherit them from the workload or retain the existing copies with transactional validation. A duration copied onto a placement must be identified as either current derived data or a historical snapshot; archived placements already have different update behavior from active and draft placements.

Week patterns in this repository use term-relative weeks anchored on Monday. Preserve that convention explicitly; do not substitute ISO week parity or renumber the selected subset. If evenly spaced remainder weeks are retained, specify a deterministic rule on sorted allowed weeks. Selecting zero-based indices `floor((i + 0.5) * m / r)` for `i = 0..r-1` produces the proposal's centered five-of-fifteen example. That is a suggested generation rule, not a feasibility guarantee.

The current sequence preference connects every overlapping pair in a sequence group, not an ordered chain. It filters for common weeks, but the Python penalty is counted once per pair, unlike costs accumulated across weekly groups. Specify whether that is intentional. The plan's reference to removing a weekly branch in `sequence_terms` does not match the current function.

## What the external research supports

The plan's split into an “Untis family” and a “HYPERPLANNING family” should be replaced with specific capabilities.

- [Untis Calendar and full year planning](https://www.untis.at/en/products/untis-basic-software/calendar-and-full-year-planning-1) supports yearly periods that can be distributed across weeks and placed at different weekly positions. It is not restricted to a fixed weekly volume.
- [UniTime Class Duration Types](https://help.unitime.org/class-duration-types) explicitly supports weekly minutes, average weekly minutes, semester minutes/hours and actual meeting minutes/hours. Semester volume and recurring patterns are compatible concepts. Its handling of actual meeting time also makes calendar losses an explicit policy question.
- [HYPERPLANNING Course](https://doc.index-education.com/en/hyperplanning/hyperplanning/C/Course.htm) describes a course containing one or several meetings, with selected weeks and positions that can vary by week. This does not support describing it as having no recurring-course representation.
- [OR-Tools solver statuses](https://developers.google.com/optimization/cp/cp_solver) distinguish `UNKNOWN` from proven infeasibility. The reported timeouts mean that the current run did not produce a solution within its limits, not that the semester has no valid timetable.

These sources support separating required volume, allowed patterns and placements. They do not establish the client's acceptable rounding, holiday compensation or payroll rules. The claims about Scientia, 1C and national practice were not independently established in this review and should not be used as justification without specific sources.

## Acceptance cases for the revised plan

1. Keep 45 required hours visible after selecting either an accepted 44-hour or 46-hour realization.
2. Define the result for a positive requirement below half a meeting, and for rounding down at longer durations.
3. Preserve a valid manual decomposition through unchanged save, preparation and resource-only edits.
4. Reject out-of-range manual masks even when their counts are correct.
5. Preserve weekly-series IDs across compatible hour edits; handle remainder growth, shrinkage, promotion to a full series and removal explicitly.
6. Detect one automatic session placed in different weeks in different plans before migration.
7. Preserve exceptions and history, including dated additions associated with sessions that have no placement.
8. Complete the two-week/four-meeting migration counterexample without discarding week 1's remaining capacity.
9. Demonstrate both the conflicting all-odd choice and feasible odd/even choice for two competing remainders.
10. Verify external bookings, excluded dates and partial boundary weeks separately, including a series that would otherwise project to zero actual meetings.
11. Compare required, generated, placed and calendar hours at component/workload level as well as course totals.
12. Repeat benchmarks with identical workload ownership and the exact generation policy, recording feasibility and timetable quality separately from optimality.

## Validation performed and limits

The focused existing test run passed all 26 tests in `workload_test.exs`, `workload_hour_units_test.exs`, `automatic_weeks_test.exs` and `solver/pure_contract_test.exs`. Two additional temporary database tests passed: the public workload API rejects 45 hours on the default grid, and the same automatic session can be validly placed in week 1 in one draft and week 2 in another.

Direct calls to the current Python solver reproduced the odd/odd versus odd/even counterexample and confirmed that forbidding the only candidate of a series yields infeasibility rather than a cancellation. The proof-of-concept remainder formulas were evaluated directly.

The 40-second and 180-second measurements in the original plan were inspected through their benchmark code, not rerun in this review. No production data was inspected, so the prevalence of migration cases remains unknown. Acceptable rounding remains an open institution decision.
