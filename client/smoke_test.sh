#!/usr/bin/env bash
set -euo pipefail

ROUTER_URL="${ROUTER_URL:-http://localhost:3600}"
COMPUTE_URL="${COMPUTE_URL:-}"

router_health="${ROUTER_URL%/}/_health"
router_ping="${ROUTER_URL%/}/ping"

echo "Checking router health: ${router_health}"
curl -fsS "${router_health}" >/dev/null

echo "Checking router ping: ${router_ping}"
ping_response="$(curl -fsS "${router_ping}")"
if [[ "${ping_response}" != "pong" ]]; then
  echo "Unexpected ping response: ${ping_response}" >&2
  exit 1
fi

if [[ -n "${COMPUTE_URL}" ]]; then
  compute_health="${COMPUTE_URL%/}/_health"
  echo "Checking compute health: ${compute_health}"
  curl -fsS "${compute_health}" >/dev/null
fi

echo "Smoke test completed."
