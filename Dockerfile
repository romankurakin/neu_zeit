ARG ELIXIR_IMAGE=elixir:1.20-slim
ARG UV_IMAGE=ghcr.io/astral-sh/uv:latest
ARG RUNNER_IMAGE=debian:trixie-slim
ARG NODE_IMAGE=node:24-bookworm-slim

FROM ${UV_IMAGE} AS uv
FROM ${NODE_IMAGE} AS node

FROM ${ELIXIR_IMAGE} AS toolchain
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git curl inotify-tools procps \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 UV_LINK_MODE=copy
WORKDIR /app

FROM toolchain AS development
RUN useradd --create-home --shell /bin/bash dev \
    && mkdir -p /app/_build /app/deps /app/node_modules /app/assets/colocated /app/priv/solver/.venv /app/priv/static/assets \
    && chown -R dev:dev /app
COPY --chmod=755 .devcontainer/start .devcontainer/console /usr/local/bin/
USER dev
RUN mix local.hex --force && mix local.rebar --force
CMD ["start"]

FROM toolchain AS builder
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile
COPY package.json npm.lock ./
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup && mix assets.deploy
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS production
COPY --from=uv /uv /usr/local/bin/
RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 ca-certificates curl procps \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 HOME=/tmp UV_CACHE_DIR=/tmp/uv-cache \
    UV_PYTHON_INSTALL_DIR=/opt/python UV_PROJECT_ENVIRONMENT=/opt/solver-venv \
    UV_LINK_MODE=copy UV_MANAGED_PYTHON=1
WORKDIR /app
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/neu_zeit ./
RUN uv sync --locked --no-dev --project /app/lib/neu_zeit-*/priv/solver \
    && chown -R nobody:root /opt/python /opt/solver-venv /tmp/uv-cache
ENV UV_OFFLINE=1 UV_NO_SYNC=1
USER nobody
CMD ["/app/bin/server"]
