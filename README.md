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

## Demonstration host

**Deploy demonstration host** creates two kinds of server in a project VPC. The database server is persistent. Application servers contain no database service or database volume. No SSH key is needed.

Deploy builds a new application server with cloud-init and connects it to the existing PostgreSQL server over its private address. PostgreSQL listens only on that private interface; a cloud firewall allows connections only from tagged application servers. The database host is created only for a new installation. If application servers exist but the database host is missing, deployment stops rather than creating an empty replacement.

The candidate runs migrations and passes its container health check before the permanent IP moves. Deploy verifies HTTPS at the new server before deleting old application servers. If candidate startup fails, the old application remains. If HTTPS verification fails after a switch, the IP returns to the old application when one exists. Database migrations are not rolled back automatically and must remain compatible with the old application during the handover.

Set the Actions variable `DEMO_RESERVED_IP` to a reserved IPv4. Set the secrets `DIGITALOCEAN_ACCESS_TOKEN`, `DEMO_DATABASE_PASSWORD` (64 random hexadecimal characters) and `DEMO_SECRET_KEY_BASE` (at least 64 characters). Keep both application secrets stable between deployments. Changing the password secret does not change the existing PostgreSQL password. The API token needs access to project droplets, tags, VPCs, firewalls, reserved IPs, actions and snapshots.

The default sizes are 1 vCPU / 1 GB for the database and 2 vCPU / 2 GB for application builds. Replacement temporarily runs an additional application server. The database server keeps daily PostgreSQL dumps on its own disk. They survive application replacements but not database-server loss. Off-server disaster-recovery backups are not configured by these workflows.

An existing single-server installation is never automatically replaced or attached to a new empty database. Deployment stops before making changes. Export its database, restore it on the dedicated database server, verify the restored records and configure the stable secrets before moving the application. Keep the original server until that migration is verified. This one-time migration requires access to the existing database; subsequent deployments do not require SSH.

**Undeploy demonstration host** is the separate destructive action. It removes the project's servers, databases, retained snapshots, reserved IP, firewall and VPC. Other projects are not touched. These workflows create no separate volumes or managed databases. Successful cleanup stops future charges for its resources; accrued usage is still payable. To install again, reserve an IPv4 and update `DEMO_RESERVED_IP`.

[DigitalOcean documents](https://docs.digitalocean.com/products/droplets/how-to/destroy/) that automatic backups can remain after server deletion until their retention period ends. Manually retained snapshots require explicit deletion; Undeploy removes project snapshots before deleting their servers.

## Guides

- [Administrator guide](docs/admin-scheduling-guide.md).
- [Domain language](docs/domain-language.md).
- [Writing skill](.agents/skills/project-writer/SKILL.md).
