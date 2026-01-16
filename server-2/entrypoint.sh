#!/usr/bin/env bash
set -euo pipefail

router_forward_addr="${ROUTER_FORWARD_ADDR:-}"
if [[ -z "${router_forward_addr}" && -n "${ROUTER_FORWARD_HOST:-}" ]]; then
  router_forward_addr="${ROUTER_FORWARD_HOST}:3600"
fi

if [[ -n "${router_forward_addr}" ]]; then
  socat TCP-LISTEN:3600,reuseaddr,fork "TCP:${router_forward_addr}" &
fi

exec /usr/local/bin/mem-compute
