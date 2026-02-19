#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[openpcc-enclave-prepare][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "Missing required environment: ${name}"
    exit 1
  fi
}

require_env RC
require_env TC
require_env TP
require_env CH
require_env PU
require_env SB
require_env ES
require_env COMPUTE_IMAGE_URI

EVENT_LOG_SOURCE="${TPM_EVENT_LOG_SOURCE:-/sys/kernel/security/tpm0/binary_bios_measurements}"
EVENT_LOG_WAIT_SECONDS="${TPM_EVENT_LOG_WAIT_SECONDS:-180}"
EVENT_LOG_WAIT_INTERVAL="${TPM_EVENT_LOG_WAIT_INTERVAL:-2}"

CONFIG_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${CONFIG_DIR}"
}
trap cleanup EXIT

EVENT_LOG_DEST="${CONFIG_DIR}/binary_bios_measurements"
log "Waiting for TPM event log at ${EVENT_LOG_SOURCE}"
start_ts="$(date +%s)"
while true; do
  if [[ -r "${EVENT_LOG_SOURCE}" ]]; then
    dd if="${EVENT_LOG_SOURCE}" of="${EVENT_LOG_DEST}" bs=1M status=none || true
    if [[ -s "${EVENT_LOG_DEST}" ]]; then
      log "TPM event log captured at ${EVENT_LOG_DEST}"
      break
    fi
  fi
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed >= EVENT_LOG_WAIT_SECONDS )); then
    log "TPM event log not ready after ${EVENT_LOG_WAIT_SECONDS}s: ${EVENT_LOG_SOURCE}"
    exit 1
  fi
  sleep "${EVENT_LOG_WAIT_INTERVAL}"
done

if ! command -v envsubst >/dev/null 2>&1; then
  log "envsubst not found; cannot render configs"
  exit 1
fi

export RC TC TP CH PU SB
envsubst '${RC} ${TC} ${TP} ${CH} ${PU}' < "${ES}/config/router_com.yaml.tmpl" > "${CONFIG_DIR}/router_com.yaml"
envsubst '${TC} ${TP} ${SB}' < "${ES}/config/compute_boot.yaml.tmpl" > "${CONFIG_DIR}/compute_boot.yaml"

cat > "${CONFIG_DIR}/Dockerfile" <<DOCKER_EOF
FROM ${COMPUTE_IMAGE_URI}
COPY router_com.yaml /etc/openpcc/router_com.yaml
COPY binary_bios_measurements /etc/openpcc/binary_bios_measurements
COPY compute_boot.yaml /etc/openpcc/compute_boot.yaml
DOCKER_EOF

log "Building enclave config image"
docker build -t "${COMPUTE_IMAGE_URI}-routercfg" "${CONFIG_DIR}"

EIF_PATH="/opt/openpcc/compute.eif"
log "Building EIF at ${EIF_PATH}"
nitro-cli build-enclave --docker-uri "${COMPUTE_IMAGE_URI}-routercfg" --output-file "${EIF_PATH}"
