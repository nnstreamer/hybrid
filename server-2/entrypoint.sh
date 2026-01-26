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

log() {
  printf '[entrypoint][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

log_pid_status() {
  local name="$1"
  local pid="$2"
  if [[ -z "${pid}" ]]; then
    log "${name} pid missing"
    return 0
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    log "${name} running (pid=${pid})"
  else
    log "${name} not running (pid=${pid})"
  fi
}

log_loopback_status() {
  if command -v ip >/dev/null 2>&1; then
    log "Loopback status:"
    ip -brief addr show lo || true
  else
    log "ip command not found; cannot report loopback status"
  fi
}

ensure_loopback_up() {
  if ! command -v ip >/dev/null 2>&1; then
    log "ip command not found; cannot bring loopback up"
    return 0
  fi
  log "Bringing loopback up"
  if ip link set lo up; then
    log "Loopback link up succeeded"
  else
    log "Loopback link up failed"
  fi
  if ip addr add 127.0.0.1/8 dev lo 2>/dev/null; then
    log "Loopback address ensured"
  else
    log "Loopback address already present or failed to add"
  fi
}

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
OLLAMA_BIN="${OLLAMA_BIN:-/usr/local/bin/ollama}"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
if [[ "${OLLAMA_HOST}" == http* ]]; then
  OLLAMA_HOST_URL="${OLLAMA_HOST}"
else
  OLLAMA_HOST_URL="http://${OLLAMA_HOST}"
fi
OLLAMA_MODELS="${OLLAMA_MODELS:-/opt/ollama/models}"
OLLAMA_STARTUP_TIMEOUT="${OLLAMA_STARTUP_TIMEOUT:-30}"

start_vsock_proxies() {
  if [[ "${ENABLE_VSOCK_PROXIES}" != "true" ]]; then
    log "VSOCK proxies disabled (ENABLE_VSOCK_PROXIES=${ENABLE_VSOCK_PROXIES})"
    return 0
  fi

  log "Starting VSOCK proxies (router=${ROUTER_PROXY_PORT}, tpm_cmd=${TPM_SIMULATOR_CMD_PORT}, tpm_platform=${TPM_SIMULATOR_PLATFORM_PORT}, router_com=${ROUTER_COM_PORT})"
  socat TCP-LISTEN:${ROUTER_PROXY_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${ROUTER_PROXY_PORT} &
  local router_proxy_pid=$!
  log_pid_status "socat router proxy" "${router_proxy_pid}"
  socat TCP-LISTEN:${TPM_SIMULATOR_CMD_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${TPM_SIMULATOR_CMD_PORT} &
  local tpm_cmd_pid=$!
  log_pid_status "socat tpm cmd proxy" "${tpm_cmd_pid}"
  socat TCP-LISTEN:${TPM_SIMULATOR_PLATFORM_PORT},reuseaddr,fork \
    VSOCK-CONNECT:${VSOCK_HOST_CID}:${TPM_SIMULATOR_PLATFORM_PORT} &
  local tpm_platform_pid=$!
  log_pid_status "socat tpm platform proxy" "${tpm_platform_pid}"
  socat VSOCK-LISTEN:${ROUTER_COM_PORT},reuseaddr,fork \
    TCP:127.0.0.1:${ROUTER_COM_PORT} &
  local router_com_pid=$!
  log_pid_status "socat router_com proxy" "${router_com_pid}"

  if command -v ss >/dev/null 2>&1; then
    log "Listening TCP sockets snapshot:"
    ss -ltn "( sport = :${ROUTER_PROXY_PORT} or sport = :${TPM_SIMULATOR_CMD_PORT} or sport = :${TPM_SIMULATOR_PLATFORM_PORT} or sport = :${ROUTER_COM_PORT} )" || true
  else
    log "ss command not found; skipping socket snapshot"
  fi
}

start_ollama() {
  if [[ ! -x "${OLLAMA_BIN}" ]]; then
    log "Ollama binary not found at ${OLLAMA_BIN}; skipping"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "${OLLAMA_HOST_URL}/api/tags" >/dev/null 2>&1; then
      log "Ollama already reachable at ${OLLAMA_HOST_URL}; skipping local start"
      return 0
    fi
  fi

  log "Starting Ollama (${OLLAMA_BIN}) with models at ${OLLAMA_MODELS}"
  OLLAMA_HOST="${OLLAMA_HOST}" OLLAMA_MODELS="${OLLAMA_MODELS}" \
    "${OLLAMA_BIN}" serve >/var/log/ollama.log 2>&1 &
  local ollama_pid=$!
  log_pid_status "ollama" "${ollama_pid}"

  if command -v curl >/dev/null 2>&1; then
    local ready="false"
    for i in $(seq 1 "${OLLAMA_STARTUP_TIMEOUT}"); do
      if curl -fsS "${OLLAMA_HOST_URL}/api/tags" >/dev/null 2>&1; then
        ready="true"
        break
      fi
      sleep 1
    done
    if [[ "${ready}" == "true" ]]; then
      log "Ollama ready"
    else
      log "Ollama readiness check timed out (${OLLAMA_STARTUP_TIMEOUT}s)"
    fi
  else
    log "curl not found; skipping Ollama readiness check"
  fi
}

log "Entrypoint starting"
log_loopback_status
ensure_loopback_up
log_loopback_status
start_vsock_proxies
start_ollama

if [[ "${SKIP_COMPUTE_BOOT:-false}" != "true" ]]; then
  log "Starting compute_boot (${COMPUTE_BOOT_BIN}) with config ${COMPUTE_BOOT_CONFIG}"
  "${COMPUTE_BOOT_BIN}" -config "${COMPUTE_BOOT_CONFIG}" &
  compute_boot_pid=$!
  log_pid_status "compute_boot" "${compute_boot_pid}"
else
  log "SKIP_COMPUTE_BOOT is true; skipping compute_boot"
fi

log "Starting router_com (${ROUTER_COM_BIN}) with config ${ROUTER_COM_CONFIG}"
exec "${ROUTER_COM_BIN}" -config "${ROUTER_COM_CONFIG}"
