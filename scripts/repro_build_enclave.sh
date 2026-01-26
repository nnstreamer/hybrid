#!/usr/bin/env bash
# Objective: Reproduce compute host build-enclave step and capture logs.
# Usage examples:
# - COMPUTE_IMAGE_URI=123456789012.dkr.ecr.us-east-1.amazonaws.com/openpcc-compute:tag \
#     ROUTER_ADDRESS=http://10.0.1.10:3600 \
#     ./scripts/repro_build_enclave.sh
# - ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com IMAGE_TAG=tag \
#     ./scripts/repro_build_enclave.sh
# Notes:
# - Runs the same config-baking + docker build + nitro-cli build-enclave flow as deploy.sh.
# - Logs are written to LOG_DIR (default: /var/log/openpcc).
set -euo pipefail

require_cmd() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "Missing required command: ${name}" >&2
    exit 1
  fi
}

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${LOG_DIR:-/var/log/openpcc}"
LOG_PREFIX="${LOG_PREFIX:-repro-build-enclave}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}-${timestamp}.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[repro] Log file: ${LOG_FILE}"
require_cmd docker
require_cmd nitro-cli
require_cmd curl

COMPUTE_IMAGE_URI="${COMPUTE_IMAGE_URI:-}"
COMPUTE_IMAGE_NAME="${COMPUTE_IMAGE_NAME:-openpcc-compute}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ECR_REGISTRY="${ECR_REGISTRY:-}"
if [[ -z "${COMPUTE_IMAGE_URI}" ]]; then
  if [[ -n "${ECR_REGISTRY}" ]]; then
    COMPUTE_IMAGE_URI="${ECR_REGISTRY}/${COMPUTE_IMAGE_NAME}:${IMAGE_TAG}"
  else
    COMPUTE_IMAGE_URI="${COMPUTE_IMAGE_NAME}:${IMAGE_TAG}"
  fi
fi

echo "[repro] compute image: ${COMPUTE_IMAGE_URI}"
echo "[repro] docker version:"
docker version || true
echo "[repro] docker info:"
docker info || true
echo "[repro] nitro-cli version:"
nitro-cli --version || true

PULL_COMPUTE_IMAGE="${PULL_COMPUTE_IMAGE:-true}"
if [[ "${PULL_COMPUTE_IMAGE}" == "true" ]]; then
  echo "[repro] pulling compute image..."
  docker pull "${COMPUTE_IMAGE_URI}"
fi

EIF_PATH="${EIF_PATH:-/opt/openpcc/compute.eif}"
mkdir -p "$(dirname "${EIF_PATH}")"
export NITRO_CLI_ARTIFACTS="${NITRO_CLI_ARTIFACTS:-/var/lib/nitro_enclaves/artifacts}"
mkdir -p "${NITRO_CLI_ARTIFACTS}"

R_COM_PORT="${ROUTER_COM_PORT:-8081}"
R_PROXY_HOST="${ROUTER_PROXY_HOST:-127.0.0.1}"
R_PROXY_PORT="${ROUTER_PROXY_PORT:-3600}"
R_PROXY_URL="http://${R_PROXY_HOST}:${R_PROXY_PORT}"
TPM_SIM_CMD_PORT="${TPM_SIMULATOR_CMD_PORT:-2321}"
TPM_SIM_PLATFORM_PORT="${TPM_SIMULATOR_PLATFORM_PORT:-$((TPM_SIM_CMD_PORT + 1))}"

MODEL_1="${MODEL_1:-llama3.2:1b}"
INFERENCE_ENGINE_MODEL_1="${INFERENCE_ENGINE_MODEL_1:-${MODEL_1}}"
INFERENCE_ENGINE_TYPE="${INFERENCE_ENGINE_TYPE:-ollama}"
INFERENCE_ENGINE_SKIP="${INFERENCE_ENGINE_SKIP:-false}"
INFERENCE_ENGINE_LOCAL_DEV="${INFERENCE_ENGINE_LOCAL_DEV:-true}"
INFERENCE_ENGINE_URL="${INFERENCE_ENGINE_URL:-http://localhost:11434}"
INFERENCE_ENGINE_SERVICE="${INFERENCE_ENGINE_SERVICE:-ollama.service}"
LLM_BASE_URL="${LLM_BASE_URL:-http://localhost:11434}"
EVIDENCE_SOCKET="${EVIDENCE_SOCKET:-/tmp/router.sock}"
EVIDENCE_TIMEOUT="${EVIDENCE_TIMEOUT:-30s}"
SIMULATE_TPM="${SIMULATE_TPM:-true}"
TPM_DEVICE="${TPM_DEVICE:-/dev/tpmrm0}"
REK_HANDLE="${REK_HANDLE:-0x81000002}"
TPM_TYPE="${TPM_TYPE:-Simulator}"
TPM_PRIMARY_KEY_HANDLE="${TPM_PRIMARY_KEY_HANDLE:-0x81000001}"
TPM_CHILD_KEY_HANDLE="${TPM_CHILD_KEY_HANDLE:-0x81000002}"
TPM_REK_TICKET_HANDLE="${TPM_REK_TICKET_HANDLE:-0x01c0000A}"
TPM_REK_HASH_HANDLE="${TPM_REK_HASH_HANDLE:-0x01c0000B}"
TPM_ATTESTATION_KEY_HANDLE="${TPM_ATTESTATION_KEY_HANDLE:-0x81000003}"
FAKE_ATTESTATION_SECRET="${FAKE_ATTESTATION_SECRET:-123456}"
GPU_REQUIRED="${GPU_REQUIRED:-false}"
GPU_ATTESTATION_MODE="${GPU_ATTESTATION_MODE:-none}"
COMPUTE_IMAGE_SIGSTORE_BUNDLE="${COMPUTE_IMAGE_SIGSTORE_BUNDLE:-}"
COMPUTE_HOST="${COMPUTE_HOST:-}"

if [[ -z "${COMPUTE_HOST}" ]]; then
  token="$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
  if [[ -n "${token}" ]]; then
    COMPUTE_HOST="$(curl -s -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
  else
    COMPUTE_HOST="$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
  fi
fi
if [[ -z "${COMPUTE_HOST}" ]]; then
  COMPUTE_HOST="$(hostname -I | awk '{print $1}' || true)"
fi
if [[ -z "${COMPUTE_HOST}" ]]; then
  COMPUTE_HOST="127.0.0.1"
fi

CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "${CONFIG_DIR}"' EXIT

cat > "${CONFIG_DIR}/router_com.yaml" <<CONFIG_EOF
http:
  port: "${R_COM_PORT}"
evidence:
  socket: "${EVIDENCE_SOCKET}"
  timeout: ${EVIDENCE_TIMEOUT}
models:
  - "${MODEL_1}"
router_com:
  check_compute_boot_exit: ${CHECK_COMPUTE_BOOT_EXIT:-false}
  tpm:
    device: "${TPM_DEVICE}"
    simulate: ${SIMULATE_TPM}
    rek_handle: ${REK_HANDLE}
    simulator_cmd_address: "127.0.0.1:${TPM_SIM_CMD_PORT}"
    simulator_platform_address: "127.0.0.1:${TPM_SIM_PLATFORM_PORT}"
  worker:
    binary_path: "${WORKER_BIN_PATH:-/opt/confidentcompute/bin/compute_worker}"
    llm_base_url: "${LLM_BASE_URL}"
    badge_public_key: "${BADGE_PUBLIC_KEY_B64:-LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUNvd0JRWURLMlZ3QXlFQTFKNXJhQTdEZTQ0elFSRVpxU21BbkRMK1RObjFPUUROZW1sWmc4eWc3azg9Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo=}"
router_agent:
  tags:
    - llm
    - "engine=${INFERENCE_ENGINE_TYPE}"
    - "model=${MODEL_1}"
  node_target_url: "http://${COMPUTE_HOST}:${R_COM_PORT}/"
  node_healthcheck_url: "http://${COMPUTE_HOST}:${R_COM_PORT}/_health"
  router_base_url: "${R_PROXY_URL}"
CONFIG_EOF

cat > "${CONFIG_DIR}/compute_boot.yaml" <<CONFIG_EOF
inference_engine:
  type: ${INFERENCE_ENGINE_TYPE}
  skip: ${INFERENCE_ENGINE_SKIP}
  models:
    - "${INFERENCE_ENGINE_MODEL_1}"
  local_dev: ${INFERENCE_ENGINE_LOCAL_DEV}
  url: "${INFERENCE_ENGINE_URL}"
  systemd_service_name: "${INFERENCE_ENGINE_SERVICE}"
tpm:
  primary_key_handle: ${TPM_PRIMARY_KEY_HANDLE}
  child_key_handle: ${TPM_CHILD_KEY_HANDLE}
  rek_creation_ticket_handle: ${TPM_REK_TICKET_HANDLE}
  rek_creation_hash_handle: ${TPM_REK_HASH_HANDLE}
  attestation_key_handle: ${TPM_ATTESTATION_KEY_HANDLE}
  tpm_type: ${TPM_TYPE}
  simulator_cmd_address: "127.0.0.1:${TPM_SIM_CMD_PORT}"
  simulator_platform_address: "127.0.0.1:${TPM_SIM_PLATFORM_PORT}"
attestation:
  fake_secret: "${FAKE_ATTESTATION_SECRET}"
gpu:
  required: ${GPU_REQUIRED}
  attestation_mode: ${GPU_ATTESTATION_MODE}
transparency:
  image_sigstore_bundle: "${COMPUTE_IMAGE_SIGSTORE_BUNDLE}"
CONFIG_EOF

cat > "${CONFIG_DIR}/Dockerfile" <<DOCKER_EOF
FROM ${COMPUTE_IMAGE_URI}
COPY router_com.yaml /etc/openpcc/router_com.yaml
COPY compute_boot.yaml /etc/openpcc/compute_boot.yaml
DOCKER_EOF

routercfg_image="${COMPUTE_IMAGE_URI}-routercfg"
build_log="${LOG_DIR}/${LOG_PREFIX}-${timestamp}-docker-build.log"
nitro_log="${LOG_DIR}/${LOG_PREFIX}-${timestamp}-nitro-build.log"

echo "[repro] building routercfg image: ${routercfg_image}"
docker build -t "${routercfg_image}" "${CONFIG_DIR}" 2>&1 | tee "${build_log}"

echo "[repro] running nitro-cli build-enclave (output=${EIF_PATH})"
nitro-cli build-enclave --docker-uri "${routercfg_image}" --output-file "${EIF_PATH}" ${NITRO_CLI_ARGS:-} 2>&1 | tee "${nitro_log}"

echo "[repro] build-enclave complete"
echo "[repro] EIF path: ${EIF_PATH}"
echo "[repro] docker build log: ${build_log}"
echo "[repro] nitro-cli log: ${nitro_log}"
