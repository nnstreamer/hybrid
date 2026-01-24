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
COMPUTE_BOOT_BIN="${COMPUTE_BOOT_BIN:-/opt/confidentcompute/bin/compute_boot}"
ROUTER_COM_BIN="${ROUTER_COM_BIN:-/opt/confidentcompute/bin/router_com}"
ENABLE_VSOCK_PROXIES="${ENABLE_VSOCK_PROXIES:-true}"
VSOCK_HOST_CID="${VSOCK_HOST_CID:-3}"
ROUTER_PROXY_PORT="${ROUTER_PROXY_PORT:-3600}"
TPM_SIMULATOR_CMD_PORT="${TPM_SIMULATOR_CMD_PORT:-2321}"
TPM_SIMULATOR_PLATFORM_PORT="${TPM_SIMULATOR_PLATFORM_PORT:-2322}"
ROUTER_COM_PORT="${ROUTER_COM_PORT:-8081}"

start_vsock_proxies() {
  if [[ "${ENABLE_VSOCK_PROXIES}" != "true" ]]; then
    return 0
  fi

  socat TCP-LISTEN:${ROUTER_PROXY_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${ROUTER_PROXY_PORT} &
  socat TCP-LISTEN:${TPM_SIMULATOR_CMD_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${TPM_SIMULATOR_CMD_PORT} &
  socat TCP-LISTEN:${TPM_SIMULATOR_PLATFORM_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${TPM_SIMULATOR_PLATFORM_PORT} &
  socat VSOCK-LISTEN:${ROUTER_COM_PORT},reuseaddr,fork \
    TCP:127.0.0.1:${ROUTER_COM_PORT} &
}

start_vsock_proxies

if [[ "${SKIP_COMPUTE_BOOT:-false}" != "true" ]]; then
  "${COMPUTE_BOOT_BIN}" -config "${COMPUTE_BOOT_CONFIG}" &
fi

exec "${ROUTER_COM_BIN}" -config "${ROUTER_COM_CONFIG}"
