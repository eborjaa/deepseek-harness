# Real DeepSeek Harness image for the Synapse four-container stack.
# DSH refuses --host 0.0.0.0; the entrypoint proxies 0.0.0.0:8080 → 127.0.0.1:3080
# so Docker can publish BIND_ADDR:8080:8080 on the HOST (127.0.0.1 on a laptop).
#
# Named context `synapse` is the @eborja/synapse engine (plugin talks HTTP to core):
#   docker build --build-context synapse=/path/to/synapse -t synapse-dsh:local .

FROM node:22-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV PNPM_HOME=/usr/local/share/pnpm
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@11.7.0 --activate

COPY . .
# The harness build stamps `git rev-parse HEAD`. We do not copy `.git` (too large);
# a one-commit repo in the image is enough.
RUN git init \
  && git config user.email "synapse@local" \
  && git config user.name "synapse" \
  && git add -A \
  && git commit -m "docker-build" --quiet
ENV LEFTHOOK=0
RUN pnpm install --frozen-lockfile
RUN pnpm run build \
  && chmod +x /app/docker-entrypoint.sh \
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
ENV DSH_PORT=3080
ENV DSH_PROXY_PORT=8080
ENV SYNAPSE_SKILLS_ROOT=/skills
ENV SYNAPSE_MCP_HTTP_URL=http://127.0.0.1:3000/mcp
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint.sh"]
