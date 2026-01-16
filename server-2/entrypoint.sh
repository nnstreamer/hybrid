#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/openpcc"
COMPUTE_BOOT_CONFIG="${COMPUTE_BOOT_CONFIG:-${CONFIG_DIR}/compute_boot.yaml}"
ROUTER_COM_CONFIG="${ROUTER_COM_CONFIG:-${CONFIG_DIR}/router_com.yaml}"

if [[ "${SKIP_COMPUTE_BOOT:-false}" != "true" ]]; then
  /opt/confidentcompute/bin/compute_boot -config "${COMPUTE_BOOT_CONFIG}" &
fi

exec /opt/confidentcompute/bin/router_com -config "${ROUTER_COM_CONFIG}"
