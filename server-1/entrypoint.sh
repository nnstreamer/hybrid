#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CREDITHOLE_CONFIG:-}" ]]; then
  /usr/local/bin/mem-credithole -config "${CREDITHOLE_CONFIG}" &
else
  /usr/local/bin/mem-credithole &
fi

exec /usr/local/bin/mem-router
