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

**Deploy demonstration host** creates a demo server and serves it over HTTPS at a permanent `IP.sslip.io` address. If the server exists, it returns the same URL without updating the application. Select **Recreate demo** to deploy another revision. This deletes the server and its demonstration database, then creates a new server at the same reserved IP.

**Undeploy demonstration host** deletes the server, database and reserved IP. It releases all billable resources created by these workflows. The old URL is no longer reserved. Before deploying again, reserve a new IPv4 and update `DEMO_RESERVED_IP`. Repeating Undeploy after cleanup is safe.

Both workflows use the `DIGITALOCEAN_ACCESS_TOKEN` secret. No SSH key is required. The token needs permission to list, create and delete droplets, use tags, read actions, and read, assign/unassign and delete reserved IPs.

Reserve an IPv4 address once in DigitalOcean and save it as the repository Actions variable `DEMO_RESERVED_IP`. The workflows always use that address and its region. They refuse to take an address assigned to another server. Use **Recreate demo** to keep the link when deploying another revision. **Undeploy** releases the address to stop its charges.

[Reserved IPv4 pricing](https://docs.digitalocean.com/products/networking/reserved-ips/details/pricing/): free while assigned to a droplet; $0.01/hour, up to $5/month, while unassigned. No domain purchase is needed. GitHub variables, secrets and your local database backup are not billable DigitalOcean resources and are kept.

First boot builds the release, so HTTPS becomes available a few minutes after creation. A demo created before this setup needs one **Recreate demo** run to configure the permanent hostname. The old ordinary droplet IP cannot be converted into a reserved IP, so share the new permanent link once after that run.

## Guides

- [Administrator guide](docs/admin-scheduling-guide.md).
- [Domain language](docs/domain-language.md).
- [Writing skill](.agents/skills/project-writer/SKILL.md).
