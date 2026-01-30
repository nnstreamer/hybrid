#!/usr/bin/env bash
# Objective: Start OpenPCC oHTTP relay with upstream forwarding.
# Usage examples:
# - RELAY_UPSTREAM_GATEWAY_URL=http://10.0.1.23:3200 ./entrypoint.sh
# Notes:
# - ohttp-relay forwards to http://localhost:3200 (upstream default).
# - This entrypoint binds localhost:3200 to the configured upstream gateway.
set -euo pipefail

log() {
  printf '[entrypoint][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

RELAY_BIN="${RELAY_BIN:-/usr/local/bin/ohttp-relay}"
RELAY_UPSTREAM_GATEWAY_URL="${RELAY_UPSTREAM_GATEWAY_URL:-}"

if [[ ! -x "${RELAY_BIN}" ]]; then
  echo "Relay binary not found at ${RELAY_BIN}" >&2
  exit 1
fi

if [[ -z "${RELAY_UPSTREAM_GATEWAY_URL}" ]]; then
  echo "RELAY_UPSTREAM_GATEWAY_URL is required (e.g. http://server-1:3200)" >&2
  exit 1
fi

if [[ "${RELAY_UPSTREAM_GATEWAY_URL}" != http://* ]]; then
  echo "RELAY_UPSTREAM_GATEWAY_URL must start with http:// (got ${RELAY_UPSTREAM_GATEWAY_URL})" >&2
  exit 1
fi

upstream_hostport="${RELAY_UPSTREAM_GATEWAY_URL#http://}"
upstream_hostport="${upstream_hostport%%/*}"

if [[ -z "${upstream_hostport}" || "${upstream_hostport}" != *:* ]]; then
  echo "RELAY_UPSTREAM_GATEWAY_URL must include host:port (got ${RELAY_UPSTREAM_GATEWAY_URL})" >&2
  exit 1
fi

upstream_host="${upstream_hostport%%:*}"
upstream_port="${upstream_hostport##*:}"

if [[ -z "${upstream_host}" || -z "${upstream_port}" ]]; then
  echo "RELAY_UPSTREAM_GATEWAY_URL must include host and port (got ${RELAY_UPSTREAM_GATEWAY_URL})" >&2
  exit 1
fi

if [[ "${upstream_host}" == "localhost" || "${upstream_host}" == "127.0.0.1" ]]; then
  if [[ "${upstream_port}" == "3200" ]]; then
    log "Upstream already localhost:3200; skipping local forward"
    exec "${RELAY_BIN}"
  fi
fi

log "Forwarding localhost:3200 to ${upstream_host}:${upstream_port}"
socat TCP-LISTEN:3200,reuseaddr,fork TCP:"${upstream_host}":"${upstream_port}" &
forward_pid=$!
log "Upstream forward running (pid=${forward_pid})"

exec "${RELAY_BIN}"
