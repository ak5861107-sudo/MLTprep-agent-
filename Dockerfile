# syntax=docker/dockerfile:1.20
FROM node:24-trixie-slim AS base
ARG USER_UID=1000
ARG USER_GID=1000
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates gosu curl gh git wget ripgrep python3 build-essential tini \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable

# Modify the existing node user/group to have the specified UID/GID to match host user
RUN usermod -u $USER_UID --non-unique node \
  && groupmod -g $USER_GID --non-unique node \
  && usermod -g $USER_GID -d /paperclip node

FROM base AS deps
ENV JOBS=1
ENV MAKEFLAGS="-j1"
WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml .npmrc ./
COPY cli/package.json cli/
COPY server/package.json server/
COPY ui/package.json ui/
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/adapter-utils/package.json packages/adapter-utils/
COPY packages/google-sheets-mcp-server/package.json packages/google-sheets-mcp-server/
COPY packages/kv-demo-mcp-server/package.json packages/kv-demo-mcp-server/
COPY packages/mcp-server/package.json packages/mcp-server/
COPY packages/paperclip-eval-kernel/package.json packages/paperclip-eval-kernel/
COPY packages/paperclip-runner/package.json packages/paperclip-runner/
COPY packages/skills-catalog/package.json packages/skills-catalog/
COPY packages/tailscale-https-broker/package.json packages/tailscale-https-broker/
COPY packages/teams-catalog/package.json packages/teams-catalog/
COPY packages/adapters/claude-local/package.json packages/adapters/claude-local/
COPY packages/adapters/codex-local/package.json packages/adapters/codex-local/
COPY packages/adapters/cursor-cloud/package.json packages/adapters/cursor-cloud/
COPY packages/adapters/cursor-local/package.json packages/adapters/cursor-local/
COPY packages/adapters/gemini-local/package.json packages/adapters/gemini-local/
COPY packages/adapters/grok-local/package.json packages/adapters/grok-local/
COPY packages/adapters/kimi-local/package.json packages/adapters/kimi-local/
COPY packages/adapters/hermes/package.json packages/adapters/hermes/
COPY packages/adapters/hermes-gateway/package.json packages/adapters/hermes-gateway/
COPY packages/adapters/openclaw-gateway/package.json packages/adapters/openclaw-gateway/
COPY packages/adapters/opencode-local/package.json packages/adapters/opencode-local/
COPY packages/adapters/pi-local/package.json packages/adapters/pi-local/
COPY packages/plugins/sdk/package.json packages/plugins/sdk/
COPY --parents packages/plugins/sandbox-providers/./*/package.json packages/plugins/sandbox-providers/
COPY packages/plugins/paperclip-plugin-fake-sandbox/package.json packages/plugins/paperclip-plugin-fake-sandbox/
COPY packages/plugins/plugin-llm-wiki/package.json packages/plugins/plugin-llm-wiki/
COPY packages/plugins/plugin-workspace-diff/package.json packages/plugins/plugin-workspace-diff/
COPY patches/ patches/
COPY scripts/link-plugin-dev-sdk.mjs scripts/

RUN pnpm install --frozen-lockfile --child-concurrency=1

FROM base AS rust-toolchain
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends gcc libc6-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) rustTarget="x86_64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_AMD64" ;; \
      arm64) rustTarget="aarch64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustTarget}/rustup-init"; \
    echo "${sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none; \
    rm /tmp/rustup-init
COPY packages/paperclip-runner/rust-toolchain.toml /tmp/runner-toolchain/rust-toolchain.toml
RUN cd /tmp/runner-toolchain && rustup show

FROM rust-toolchain AS rust-chef
RUN cd /tmp/runner-toolchain && cargo install cargo-chef --version 0.1.73 --locked

FROM rust-chef AS runner-plan
WORKDIR /app/packages/paperclip-runner
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
RUN cd runner && cargo chef prepare --recipe-path /tmp/runner-recipe.json

FROM rust-chef AS runner-deps
WORKDIR /app/packages/paperclip-runner/runner
COPY packages/paperclip-runner/rust-toolchain.toml ../
COPY --from=runner-plan /tmp/runner-recipe.json /tmp/runner-recipe.json
RUN cargo chef cook --release --locked --package paperclip-runner-core --bin paperclip-runnerd --recipe-path /tmp/runner-recipe.json \
  && find . -mindepth 1 -maxdepth 1 ! -name target -exec rm -rf {} +

FROM runner-deps AS runner-build
WORKDIR /app/packages/paperclip-runner
COPY packages/paperclip-runner/rust-toolchain.toml ./
COPY packages/paperclip-runner/runner ./runner
COPY packages/paperclip-runner/protocol ./protocol
RUN find runner protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 rust-toolchain.toml \
  && cargo build --release -j 1 --manifest-path runner/Cargo.toml --locked -p paperclip-runner-core --bin paperclip-runnerd

FROM runner-build AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN find packages/paperclip-runner/runner packages/paperclip-runner/protocol -type f -exec touch -d @0 {} + \
  && touch -d @0 packages/paperclip-runner/rust-toolchain.toml
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
ARG PAPERCLIP_BUILD_COMMIT=""
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js || (echo "ERROR: server build output missing" && exit 1)
RUN rm -rf packages/paperclip-runner/runner/target

FROM base AS production
ARG USER_UID=1000
ARG USER_GID=1000
ARG CLI_TOOLS_CACHE_EPOCH=""
WORKDIR /app
RUN echo "cli-tools-epoch: ${CLI_TOOLS_CACHE_EPOCH}" \
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest @moonshot-ai/kimi-code@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip

COPY scripts/docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=node:node --from=build /app /app

ARG PAPERCLIP_BUILD_VERSION=""
ARG PAPERCLIP_BUILD_COMMIT=""
ENV NODE_ENV=production \
  HOME=/paperclip \
  HOST=0.0.0.0 \
  PORT=3100 \
  SERVE_UI=true \
  PAPERCLIP_HOME=/paperclip \
  PAPERCLIP_INSTANCE_ID=default \
  PAPERCLIP_BUILD_VERSION=${PAPERCLIP_BUILD_VERSION} \
  PAPERCLIP_BUILD_COMMIT=${PAPERCLIP_BUILD_COMMIT} \
  USER_UID=${USER_UID} \
  USER_GID=${USER_GID} \
  PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
  PAPERCLIP_DEPLOYMENT_MODE=authenticated \
  PAPERCLIP_DEPLOYMENT_EXPOSURE=private \
  OPENCODE_ALLOW_ALL_MODELS=true \
  GEMINI_SANDBOX=false

EXPOSE 3100
ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
CMD ["node", "--import", "./server/node_modules/tsx/dist/loader.mjs", "server/dist/index.js"]

FROM build AS cloud-plugins
ARG CLOUD_BUNDLED_PLUGINS="daytona"
RUN set -eu; \
  for name in $CLOUD_BUNDLED_PLUGINS; do \
    dir="packages/plugins/sandbox-providers/$name"; \
    test -d "$dir" || { echo "ERROR: unknown sandbox provider '$name'" >&2; exit 1; }; \
    pnpm -C "$dir" install --ignore-workspace --no-lockfile; \
    pnpm -C "$dir" build; \
    test -f "$dir/dist/manifest.js" || { echo "ERROR: $dir is missing dist/manifest.js after build" >&2; exit 1; }; \
  done

FROM build AS cloud-server-deps
WORKDIR /app/.cloud-server-deps
ARG CLOUD_BUNDLED_SERVER_DEPS="@sentry/node"
RUN set -eu; \
  test -n "$CLOUD_BUNDLED_SERVER_DEPS" || { echo "ERROR: CLOUD_BUNDLED_SERVER_DEPS is empty; name at least one optional peer package to install" >&2; exit 1; }; \
  echo '{"name":"paperclip-cloud-server-deps","private":true}' > package.json; \
  specifiers=""; \
  for name in $CLOUD_BUNDLED_SERVER_DEPS; do \
    version="$(node -e "const pkg=require('/app/server/package.json'); const name=process.argv[1]; const version=(pkg.peerDependencies||{})[name]; if(!version){console.error('ERROR: server/package.json declares no peerDependencies version for '+JSON.stringify(name));process.exit(1);} const meta=(pkg.peerDependenciesMeta||{})[name]; if(!meta||meta.optional!==true){console.error('ERROR: '+JSON.stringify(name)+' is not declared as an optional peer dependency in server/package.json; CLOUD_BUNDLED_SERVER_DEPS may name only optional peer packages');process.exit(1);} process.stdout.write(version);" "$name")"; \
    test -n "$version" || { echo "ERROR: could not resolve a version for '$name'" >&2; exit 1; }; \
    specifiers="$specifiers ${name}@${version}"; \
  done; \
  test -n "$specifiers" || { echo "ERROR: CLOUD_BUNDLED_SERVER_DEPS names no package" >&2; exit 1; }; \
  pnpm add --ignore-workspace --no-lockfile $specifiers

FROM production AS cloud
COPY --chown=node:node --from=cloud-plugins /app/packages/plugins/sandbox-providers /app/packages/plugins/sandbox-providers
COPY --chown=node:node --from=cloud-server-deps /app/.cloud-server-deps/node_modules /app/server/node_modules
