# Real DeepSeek Harness image for the Synapse four-container stack.
# DSH refuses --host 0.0.0.0; the entrypoint proxies 0.0.0.0:8080 → 127.0.0.1:3080
# so Docker can publish BIND_ADDR:8080:8080 on the HOST (127.0.0.1 on a laptop).
#
# Named context `synapse` is the @eborja/synapse engine (plugin talks HTTP to core):
#   docker build --build-context synapse=/path/to/synapse -t synapse-dsh:local .
#
# THREE STAGES so the runtime layer starts from -slim instead of inheriting the
# full node:22-bookworm base (which alone drags in imagemagick, mysqlclient,
# postgres client libs and a from-source Node build meant for gyp-heavy native
# ecosystems this image never touches), and so the build stage's throwaway
# layers — the fake git-stamp repo above all — never reach the pushed image.
#
#   deps    — full install, cached separately from source edits.
#   build   — compiles, then drops the git-stamp repo. See the long note in
#             that stage for why devDependencies are NOT pruned here.
#   runtime — -slim base. python3/make/g++/git/gh stay in THIS stage on
#             purpose: the agent itself compiles and shells out for the user's
#             project, not just the harness build.

FROM node:22-bookworm AS deps
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ git \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

COPY . .
# The harness build stamps `git rev-parse HEAD`. We do not copy `.git` (too large);
# a one-commit repo is enough, and it is deleted in the build stage below before
# anything is copied into the runtime image.
RUN git init \
  && git config user.email "synapse@local" \
  && git config user.name "synapse" \
  && git add -A \
  && git commit -m "docker-build" --quiet
ENV LEFTHOOK=0
RUN pnpm install --frozen-lockfile

FROM deps AS build
RUN pnpm run build \
  && chmod +x /app/docker-entrypoint.sh
RUN rm -rf .git
# Deploy the RUNTIME CLOSURE, not apps/cli.
#
# Deploying apps/cli directly does not work, and neither does any other
# obvious way of dropping devDependencies:
#
#   pnpm prune --prod      → dropped @deepseek-ai/dsh-app-boot
#   pnpm install --prod    → dropped @deepseek-ai/cordis
#   pnpm deploy (apps/cli) → dropped @deepseek-ai/cordis-plugin-group
#   injectWorkspacePackages: true (what non-legacy deploy requires)
#                          → rewrites every workspace link: to file:, which
#                            breaks the TS build outright: cross-package
#                            typecheck resolves sibling `src/*.ts` THROUGH
#                            those symlinks (dozens of TS2307).
#
# One root cause, several faces: `pnpm peers check` shows this workspace has
# pervasive UNMET peerDependencies that no package.json declares. What
# satisfies them in a normal install is pnpm's hoisted fallback dir
# (node_modules/.pnpm/node_modules, `hoist: true`) — Node walks up and finds
# packages nothing formally depends on. Any --prod pass empties that fallback,
# so resolution breaks at whichever import is reached first.
#
# python/sdk-runtime IS the fix, and it is upstream's, not ours:
# `dsh-python-runtime-closure` is a dependency-only deploy root naming every
# workspace package the dsh runtime actually needs, and
# scripts/build-exe-for-python-sdk.ts already stages exactly this tree for the
# Python wheel. A bare `pnpm deploy` of it is NOT enough — it still needs the
# hoisted node-linker plus two fixups — so docker-stage-runtime.mjs ports that
# script's staging half rather than reinventing it. See its header.
#
# Its layout is upstream's too: the launcher is at
# node_modules/@deepseek-ai/dsh/lib/bin.js (their ENTRY_BIN), which is why
# docker-entrypoint.sh execs that path rather than apps/cli/lib/bin.js.
RUN node docker-stage-runtime.mjs /opt/dsh-runtime

FROM node:22-bookworm-slim AS runtime
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ git ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# GitHub CLI — static binary, not in Debian's repos. dpkg's arch name matches the
# release tarball naming (amd64/arm64), so this covers the multi-arch build as-is.
ARG GH_VERSION=2.98.0
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
    | tar -xz -C /tmp; \
  mv "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh; \
  rm -rf /tmp/gh_*; \
  gh --version

WORKDIR /app
# The deployed closure is self-contained: its node_modules holds every
# workspace package the runtime needs, as real files rather than symlinks into
# a workspace that no longer exists here.
COPY --from=build /opt/dsh-runtime .
COPY --from=build /app/docker-entrypoint.sh /app/docker-loopback-proxy.mjs ./
RUN chmod +x /app/docker-entrypoint.sh \
  && mkdir -p /dsh-home /synapse/vaults /skills \
  && cp /app/docker-loopback-proxy.mjs /usr/local/lib/dsh-loopback-proxy.mjs \
  && cp /app/docker-entrypoint.sh /usr/local/bin/dsh-entrypoint.sh

# The DSH plugin lives here and talks HTTP to synapse-core. Never spawn a second
# synapse-mcp in this container — core is the only writer on the vault DBs.
COPY --from=synapse package.json package-lock.json /opt/synapse/
COPY --from=synapse bin /opt/synapse/bin
COPY --from=synapse lib /opt/synapse/lib
COPY --from=synapse mcp /opt/synapse/mcp
COPY --from=synapse dsh /opt/synapse/dsh
COPY --from=synapse agents.sh /opt/synapse/agents.sh
WORKDIR /opt/synapse
RUN npm ci --omit=dev
WORKDIR /app

ENV DSH_HOME=/dsh-home
# gh reads credentials from here. On the dsh-home volume so they survive recreate, and
# named so the bash tool's /KEY|PASSWORD|SECRET|TOKEN/i env scrub lets it through — that
# scrub is why GH_TOKEN alone cannot reach the agent's shell. Set here (not only in the
# entrypoint) so `docker exec ... gh` finds it too.
ENV GH_CONFIG_DIR=/dsh-home/.config/gh
ENV DSH_PORT=3080
ENV DSH_PROXY_PORT=8080
ENV SYNAPSE_SKILLS_ROOT=/skills
ENV SYNAPSE_MCP_HTTP_URL=http://127.0.0.1:3000/mcp
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint.sh"]
