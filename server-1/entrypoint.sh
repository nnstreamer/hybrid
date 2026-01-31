#!/usr/bin/env bash
# Objective: Start OpenPCC router services in order.
# Usage examples:
# - ./entrypoint.sh
# - CREDITHOLE_CONFIG=/etc/openpcc/credithole.yaml ./entrypoint.sh
# Notes:
# - Starts mem-credithole and mem-gateway in background, then runs mem-router in foreground.
# - Use CREDITHOLE_CONFIG to point to a custom YAML config for credithole.
set -euo pipefail

MEM_CREDITHOLE_BIN="${MEM_CREDITHOLE_BIN:-/usr/local/bin/mem-credithole}"
MEM_GATEWAY_BIN="${MEM_GATEWAY_BIN:-/usr/local/bin/mem-gateway}"
MEM_ROUTER_BIN="${MEM_ROUTER_BIN:-/usr/local/bin/mem-router}"

if [[ -n "${CREDITHOLE_CONFIG:-}" ]]; then
  "${MEM_CREDITHOLE_BIN}" -config "${CREDITHOLE_CONFIG}" &
else
  "${MEM_CREDITHOLE_BIN}" &
fi

"${MEM_GATEWAY_BIN}" &

exec "${MEM_ROUTER_BIN}"
