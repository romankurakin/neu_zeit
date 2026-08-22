# NeuZeit

API-first Phoenix implementation of the university timetable planner domain.

There is intentionally no UI yet. The current surface is the JSON API, Ecto data model, PostgreSQL constraints, and `uv`-managed Python solver integration.

## Administration

The working Russian-language guide for preparing a term, prioritizing constraints,
running the solver, and reviewing whether a generated timetable is logically sound
is available in [`docs/admin-scheduling-guide.ru.md`](docs/admin-scheduling-guide.ru.md).

## Development

Start the development database:

```sh
docker compose up -d db
```

Set up and migrate:

```sh
mix setup
```

Run the API:

```sh
mix phx.server
```

Run tests:

```sh
mix test
```

## API

Generic JSON CRUD resources:

```text
/api/terms
/api/buildings
/api/rooms
/api/courses
/api/courses/:course_id/translations
/api/course_components
/api/teachers
/api/cohorts
/api/sessions
/api/slot_profiles
/api/plans
/api/placements
/api/schedule_exceptions
```

Plan actions:

```text
POST /api/plans/:id/clone
POST /api/plans/:id/publish
GET  /api/plans/:id/checks
GET  /api/plans/:id/advisories
POST /api/plans/:id/solve
GET  /api/terms/:term_id/occurrences
GET  /api/terms/:term_id/courses/:course_id/coverage
POST /api/terms/:term_id/slot_profiles/defaults
GET  /api/terms/:term_id/teachers/:teacher_id/availability
PUT  /api/terms/:term_id/teachers/:teacher_id/availability
```

Payloads may be wrapped by singular key, for example `{ "term": { ... } }`, or sent as a flat JSON object.

`GET /api/courses?locale=ru` returns localized course titles, falling back to
the base title for locales without a translation.

`GET /api/terms/:term_id/occurrences` responds for any existing term: with no
active plan it returns an empty projection, and `meta.active_plan_id` tells
clients whether a plan is published at all.

Term `excluded_dates` are hard non-teaching days. Template occurrences are not
projected on them, and `move`/`add` exceptions may not target them (moving an
occurrence *off* an excluded date stays allowed). Excluding a date that an
active exception targets is rejected the same way.

## Solver

The solver project lives in `priv/solver` and is managed by `uv`.

```sh
uv sync --locked --project priv/solver
uv run --locked --project priv/solver python priv/solver/solve.py spec.json
```

Phoenix calls the same command path through `NeuZeit.Solver.OrToolsPort`.

Sessions may span multiple consecutive cells through `duration_slots`. A
placement stores one start cell and reserves its full duration in the same room.
Reusable, term-owned slot profiles define the allowed start cells for regular
sessions. `POST /api/terms/:term_id/slot_profiles/defaults` idempotently creates
the profiles inferred from the legacy DKU timetable (`DE_EARLY`, `DE_LATE`,
`EN_EARLY`, `EN_LATE`, `EN_SATURDAY`, `KZ_LATE`, `PE_EDGE`, and general
profiles). Administrators can create narrower profiles for guest and fixed-time
classes. Locked placements remain the manual override workflow.

Teacher availability is a term-owned weekly allow-list of occupied day/slot
cells. An empty list means unrestricted. Once cells are configured, both manual
placements, solver starts, and one-off move/add exceptions must fit entirely
inside them, including every cell of a multi-slot session. The `cells` field is
required on replacement; send an explicit empty list to remove the restriction.

`GET /api/plans/:id/advisories` reports simultaneous base-cohort and legacy
language-subgroup placements for human review. These warnings are deliberately
not hard conflicts because the legacy data does not describe actual student
membership.

Phoenix owns the timetable rule model. `NeuZeit.Constraints.Hard` validates
manual and solver-produced placements. `NeuZeit.Constraints.Soft` describes the
soft objective — building clustering, cohort gaps, sequence adjacency, and
minimal perturbation — that the solver optimizes. Cohort gaps and building
clustering are evaluated separately for each teaching week. `NeuZeit.Solver.SpecBuilder`
serializes those Phoenix-owned rules into a strict JSON contract. Python builds
and solves the OR-Tools CP-SAT model; Phoenix validates the returned assignment
against the hard constraints and persists the placements in an Ecto transaction.
Plans carry no score: the solver optimizes the soft objective internally, and
drafts are compared by inspecting their placements.

Scheduling business defaults live in `NeuZeit.Scheduling.Defaults`.
`NeuZeit.Config.load!/0` validates and exposes that policy to checks and solver
spec generation. There is intentionally no TOML or environment-variable source
for scheduling policy; future administrator-editable settings should be modeled
as domain data and exposed through the API.

Concurrent solver processes are capped from the configured CP-SAT worker count
to avoid CPU oversubscription. Deployments may set the positive application
configuration value `:solver_max_concurrency` when they intentionally want a
different operational limit.

## Docker

The `Dockerfile` is generated from Phoenix releases and extended only to include Python, `uv`, and the locked solver environment. Run migrations in a release with:

```sh
/app/bin/migrate
```
