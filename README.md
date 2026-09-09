# NeuZeit

Create, check and publish teaching timetables.

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

## Checks and dependencies

```sh
docker compose exec application mix precommit   # Format, Ruff, tests
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

## Guides

- [Administrator guide](docs/admin-scheduling-guide.md).
- [Domain language](docs/domain-language.md).
- [Writing skill](.agents/skills/project-writer/SKILL.md).
