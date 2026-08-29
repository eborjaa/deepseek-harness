#!/bin/bash
# Seed DSH_HOME (settings + Synapse plugin) then run the UI behind the loopback proxy.
set -euo pipefail

export DSH_HOME="${DSH_HOME:-/dsh-home}"
export DSH_PORT="${DSH_PORT:-3080}"
export DSH_PROXY_PORT="${DSH_PROXY_PORT:-8080}"
HTTP_URL="${SYNAPSE_MCP_HTTP_URL:-http://127.0.0.1:3000/mcp}"

mkdir -p "$DSH_HOME/profiles/web" \
  "$DSH_HOME/profiles/web/node_modules/@eborja" \
  "$DSH_HOME/profiles/node_modules/@eborja"

# Same resolution trick as `dsh plugin add` on a Mac: the profile sees
# @eborja/synapse as a local package. The token stays in the environment —
# never on the dsh-home volume, never in YAML.
ln -sfn /opt/synapse "$DSH_HOME/profiles/web/node_modules/@eborja/synapse"
ln -sfn /opt/synapse "$DSH_HOME/profiles/node_modules/@eborja/synapse"

if [[ ! -f "$DSH_HOME/settings.yaml" ]]; then
  cat > "$DSH_HOME/settings.yaml" <<'YAML'
# Seeded once. Edit in the UI afterwards — this file is on the dsh-home volume.
llm-pi-ai:
  providers:
    ollama-host:
      displayName: "Ollama (this Mac)"
      api: openai-completions
      baseURL: "http://host.docker.internal:11434/v1"
      headers:
        Authorization: "Bearer unused"
      streamIdleTimeoutMs: 1800000
      timeoutMs: 1800000
      compat:
        supportsStore: false
        supportsDeveloperRole: false
        supportsReasoningEffort: false
        maxTokensField: max_tokens
      models:
        - id: "qwen3-coder-256k:latest"
          contextWindow: 262144
    opencode-go:
      apiKeyEnv: OPENCODE_GO_API_KEY
agent-default-model:
  provider: opencode-go
  model: gpt-5.6-luna
  reasoningEffort: high
YAML
fi

PKG="$DSH_HOME/profiles/web/package.json"
node -e '
const fs = require("node:fs");
const p = process.argv[1];
let j = {};
if (fs.existsSync(p)) {
  try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch { j = {}; }
}
if (!j.name) j.name = "dsh-profile-web";
j.private = true;
j.dependencies = j.dependencies || {};
j.dependencies["@eborja/synapse"] = "file:/opt/synapse";
j.dsh = j.dsh || {};
j.dsh.profile = j.dsh.profile || {};
if (!Array.isArray(j.dsh.profile.bundles) || j.dsh.profile.bundles.length === 0) {
  j.dsh.profile.bundles = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"];
}
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
' "$PKG"

PATCH="$DSH_HOME/profiles/web/cordis.patch.yml"
{
  echo "# Generated at container start. Do not copy a host ~/.dsh into this volume."
  echo "# HTTP plugin → synapse-core. A stdio child here would be a second writer."
  cat <<YAML
- insert:
    - id: mcp-synapse
      name: '@eborja/synapse/dsh-plugin'
      config:
        transport: http
        httpUrl: ${HTTP_URL}
        surface: orchestrator
- id: spill-policy
  config:
    maxInlineBytes: 70000
YAML
} > "$PATCH"

echo "[dsh] waiting for synapse-core on 127.0.0.1:3000"
node --input-type=module -e '
import http from "node:http";
const tryOnce = () => new Promise((resolve) => {
  const req = http.get("http://127.0.0.1:3000/mcp", (res) => { res.resume(); resolve(res.statusCode); });
  req.on("error", () => resolve(0));
  req.setTimeout(1500, () => { req.destroy(); resolve(0); });
});
for (let i = 0; i < 60; i++) {
  const code = await tryOnce();
  if (code > 0) {
    process.stderr.write(`[dsh] synapse-core answered HTTP ${code}\n`);
    process.exit(0);
  }
  await new Promise((r) => setTimeout(r, 1000));
}
process.stderr.write("[dsh] synapse-core did not answer in 60s — starting DSH anyway\n");
'

node /usr/local/lib/dsh-loopback-proxy.mjs &

# DSH checks the Host header of every /api request against a trusted list and answers 403 otherwise
# ("the /api browser-trust fence"). Reaching this container through a proxy on a real domain means
# requests arrive with that domain in Host, so the domain has to be named here or the UI loads and
# then fails on `llm/listProviders` with no clue why. The WebSocket at /api/remote.mux fails the
# same way, because the browser derives it from the page origin.
#
# DSH_TRUSTED_HOSTS is a comma or space separated list of authorities (host, or host:port).
#   DSH_TRUSTED_HOSTS=cerebro.example.com
#
# The two loopback entries are always present: they are how the container is reached without a proxy.
set -- --host 127.0.0.1 --port "$DSH_PORT" --no-open \
  --trusted-host "127.0.0.1:${DSH_PROXY_PORT}" \
  --trusted-host "localhost:${DSH_PROXY_PORT}"

for authority in $(printf '%s' "${DSH_TRUSTED_HOSTS:-}" | tr ',' ' '); do
  [ -n "$authority" ] || continue
  set -- "$@" --trusted-host "$authority"
  echo "[dsh] trusting Host: $authority"
done

exec node /app/apps/cli/lib/bin.js web "$@"
