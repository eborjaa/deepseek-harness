#!/usr/bin/env node
// docker-loopback-proxy.mjs — DSH refuses --host 0.0.0.0 (remote code execution).
// Docker can only publish a port the process listens on on the container's
// external interface, so this TCP proxy binds 0.0.0.0:8080 inside the
// container and forwards to DSH on 127.0.0.1:3080. The HOST publish is still
// BIND_ADDR (127.0.0.1 on a laptop) — this is not a host wildcard listen.

import net from "node:net";

const listenPort = Number(process.env.DSH_PROXY_PORT || 8080);
const upstreamPort = Number(process.env.DSH_PORT || 3080);
const upstreamHost = process.env.DSH_HOST || "127.0.0.1";

const server = net.createServer((client) => {
  const upstream = net.connect(upstreamPort, upstreamHost);
  client.pipe(upstream);
  upstream.pipe(client);
  const close = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on("error", close);
  upstream.on("error", close);
});

server.listen(listenPort, "0.0.0.0", () => {
  process.stderr.write(
    `[dsh-proxy] 0.0.0.0:${listenPort} → ${upstreamHost}:${upstreamPort}\n`,
  );
});
