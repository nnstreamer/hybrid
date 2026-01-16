#!/usr/bin/env bash
# Objective: Start OpenPCC router services in order.
# Usage examples:
# - ./entrypoint.sh
# - CREDITHOLE_CONFIG=/etc/openpcc/credithole.yaml ./entrypoint.sh
# Notes:
# - Starts mem-credithole in background, then runs mem-router in foreground.
# - Use CREDITHOLE_CONFIG to point to a custom YAML config for credithole.
set -euo pipefail

if [[ -n "${CREDITHOLE_CONFIG:-}" ]]; then
  /usr/local/bin/mem-credithole -config "${CREDITHOLE_CONFIG}" &
else
  /usr/local/bin/mem-credithole &
fi

exec /usr/local/bin/mem-router
