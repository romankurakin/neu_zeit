# NeuZeit

[![Checks](https://github.com/romankurakin/neu_zeit/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/romankurakin/neu_zeit/actions/workflows/checks.yml?query=branch%3Amain)

Create, check and publish teaching timetables.

The `application` container runs the Phoenix server: the LiveView interface, the JSON API under `/api` and the timetable solver, a Python OR-Tools CP-SAT script that the server starts for each calculation. The `database` container runs PostgreSQL; the application applies migrations on start (development) or through the `migrate` service (production).

## Development

Requires Docker with Compose.

```sh
docker compose up --build --wait --wait-timeout 600 application
```

Open [localhost:4000](http://localhost:4000). [Components](http://localhost:4000/dev/storybook).

```sh
docker compose exec application console                     # IEx on the running server
docker compose exec application bash                        # Container shell
docker compose exec -T application console eval 'EXPRESSION' # Evaluate on the server
docker compose stop                                         # Stop; keep data
```

In VS Code, use **Dev Containers: Reopen in Container**.

To discard local data and start empty:

```sh
docker compose stop application
docker compose run --rm application mix ecto.reset
docker compose up --wait --wait-timeout 600 application
```

To fill an empty database with fictional demonstration data (a term, rooms, teachers, groups, 20 courses, teaching load and a draft plan):

```sh
docker compose exec application mix run priv/repo/seeds.exs
```

## Checks and dependencies

```sh
docker compose exec application mix precommit   # Format, Ruff, tests
docker compose exec application mix test --cover # Tests with a coverage report in cover/
docker compose exec application mix dialyzer    # Elixir type analysis
docker compose exec application mix npm.install # Update npm.lock after package.json edits
```

## Deployment

Copy `.env.example` to `.env`. Set the domain and secrets. Configure an HTTPS proxy to forward the host and protocol to `127.0.0.1:4000`.

```sh
docker compose -f compose.prod.yaml build application
docker compose -f compose.prod.yaml up -d database
docker compose -f compose.prod.yaml run --rm migrate && \
  docker compose -f compose.prod.yaml up -d application
```

`GET /health` answers 200 when the application can query PostgreSQL and 503 when it cannot. Compose health checks use it.

The log records every request except health checks with its duration, and every solver run with its outcome and duration.

## Oracle demonstration host

[Oracle setup and commands](deploy/oracle/README.md). Resource Manager creates Always Free infrastructure; Run Command deploys Docker Compose releases without SSH. Repeat deployments preserve PostgreSQL. Undeploy deletes the Oracle demo and its backups.

## Guides

- [Administrator guide](docs/admin-scheduling-guide.md).
- [Domain language](docs/domain-language.md).
- [Writing skill](.agents/skills/project-writer/SKILL.md).
