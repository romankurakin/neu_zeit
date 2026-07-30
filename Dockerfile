ARG ELIXIR_VERSION=1.20
ARG OTP_VERSION=29
ARG DEBIAN_VERSION=trixie-slim

ARG BUILDER_IMAGE="docker.io/elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION}-slim"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"
ARG UV_IMAGE="ghcr.io/astral-sh/uv:latest"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

COPY lib lib

RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

FROM ${UV_IMAGE} AS uv

FROM ${RUNNER_IMAGE} AS final

COPY --from=uv /uv /uvx /usr/local/bin/

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates procps \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV HOME=/tmp
ENV UV_CACHE_DIR=/tmp/uv-cache

ENV UV_MANAGED_PYTHON=1
ENV UV_PYTHON_INSTALL_DIR=/app/python

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/neu_zeit ./

RUN uv sync --locked --project /app/lib/neu_zeit-*/priv/solver \
  && chown -R nobody:root /app /tmp/uv-cache

USER nobody

CMD ["/app/bin/server"]
