#!/usr/bin/env bash
# Objective: Start OpenPCC router services in order.
# Usage examples:
# - ./entrypoint.sh
# - CREDITHOLE_CONFIG=/etc/openpcc/credithole.yaml ./entrypoint.sh
# Notes:
# - Starts mem-credithole in background, then runs mem-router in foreground.
# - Use CREDITHOLE_CONFIG to point to a custom YAML config for credithole.
set -euo pipefail

MEM_CREDITHOLE_BIN="${MEM_CREDITHOLE_BIN:-/usr/local/bin/mem-credithole}"
MEM_ROUTER_BIN="${MEM_ROUTER_BIN:-/usr/local/bin/mem-router}"

if [[ -n "${CREDITHOLE_CONFIG:-}" ]]; then
  "${MEM_CREDITHOLE_BIN}" -config "${CREDITHOLE_CONFIG}" &
else
  "${MEM_CREDITHOLE_BIN}" &
fi

exec "${MEM_ROUTER_BIN}"
