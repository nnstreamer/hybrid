#!/usr/bin/env bash
# Objective: Start OpenPCC compute services with config files.
# Usage examples:
# - ./entrypoint.sh
# - SKIP_COMPUTE_BOOT=true ./entrypoint.sh
# - COMPUTE_BOOT_CONFIG=/etc/openpcc/compute_boot.yaml ROUTER_COM_CONFIG=/etc/openpcc/router_com.yaml ./entrypoint.sh
# Notes:
# - compute_boot runs in background unless SKIP_COMPUTE_BOOT=true.
# - router_com runs in foreground and uses ROUTER_COM_CONFIG.
set -euo pipefail

CONFIG_DIR="/etc/openpcc"
COMPUTE_BOOT_CONFIG="${COMPUTE_BOOT_CONFIG:-${CONFIG_DIR}/compute_boot.yaml}"
ROUTER_COM_CONFIG="${ROUTER_COM_CONFIG:-${CONFIG_DIR}/router_com.yaml}"

if [[ "${SKIP_COMPUTE_BOOT:-false}" != "true" ]]; then
  /opt/confidentcompute/bin/compute_boot -config "${COMPUTE_BOOT_CONFIG}" &
fi

exec /opt/confidentcompute/bin/router_com -config "${ROUTER_COM_CONFIG}"
