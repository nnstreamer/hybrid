#!/usr/bin/env bash
# Objective: Build and optionally package OpenPCC component images.
# Usage examples:
# - COMPONENT=all ./scripts/build_pack.sh
# - COMPONENT=server-1 IMAGE_TAG=dev ./scripts/build_pack.sh
# - COMPONENT=server-2 BUILD_EIF=true ./scripts/build_pack.sh
# - COMPONENT=all REGISTRY=public.ecr.aws/alias PUSH=true ./scripts/build_pack.sh
# Notes:
# - BUILD_EIF=true requires nitro-cli on the runner.
# - Set IMAGE_TAG, REGISTRY, and PUSH to control tagging and pushing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPONENT="${COMPONENT:-all}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
REGISTRY="${REGISTRY:-}"
PUSH="${PUSH:-false}"
BUILD_EIF="${BUILD_EIF:-false}"
EIF_OUTPUT_DIR="${EIF_OUTPUT_DIR:-${ROOT_DIR}/artifacts}"

if [[ "${PUSH}" == "true" ]]; then
  if [[ -z "${REGISTRY}" ]]; then
    echo "REGISTRY is required when PUSH=true." >&2
    exit 1
  fi
  if [[ "${REGISTRY}" != public.ecr.aws/* ]]; then
    echo "REGISTRY must be a public ECR registry (public.ecr.aws/alias)." >&2
    exit 1
  fi
fi

ROUTER_IMAGE_NAME="${ROUTER_IMAGE_NAME:-openpcc-router}"
COMPUTE_IMAGE_NAME="${COMPUTE_IMAGE_NAME:-openpcc-compute}"
CLIENT_IMAGE_NAME="${CLIENT_IMAGE_NAME:-openpcc-client}"
AUTH_IMAGE_NAME="${AUTH_IMAGE_NAME:-openpcc-auth}"

build_image() {
  local image_name="$1"
  local dockerfile="$2"
  local context_dir="$3"
  shift 3
  local build_args=("$@")
  local image_tag="${image_name}:${IMAGE_TAG}"

  if [[ -n "${REGISTRY}" ]]; then
    image_tag="${REGISTRY}/${image_tag}"
  fi

  echo "Building ${image_tag} from ${dockerfile}"
  docker build -f "${dockerfile}" -t "${image_tag}" "${build_args[@]}" "${context_dir}"

  if [[ "${PUSH}" == "true" ]]; then
    echo "Pushing ${image_tag}"
    docker push "${image_tag}"
  fi
}

build_router() {
  build_image "${ROUTER_IMAGE_NAME}" "${ROOT_DIR}/server-1/Dockerfile" "${ROOT_DIR}/server-1"
}

build_compute() {
  local build_args=()
  if [[ -n "${COMPUTE_BOOT_BUILD_TAGS:-}" ]]; then
    build_args+=(--build-arg "COMPUTE_BOOT_BUILD_TAGS=${COMPUTE_BOOT_BUILD_TAGS}")
  fi
  if [[ -n "${OLLAMA_MODEL:-}" ]]; then
    build_args+=(--build-arg "OLLAMA_MODEL=${OLLAMA_MODEL}")
  fi
  if [[ -n "${OLLAMA_VERSION:-}" ]]; then
    build_args+=(--build-arg "OLLAMA_VERSION=${OLLAMA_VERSION}")
  fi
  if [[ -n "${OLLAMA_DOWNLOAD_URL:-}" ]]; then
    build_args+=(--build-arg "OLLAMA_DOWNLOAD_URL=${OLLAMA_DOWNLOAD_URL}")
  fi
  if [[ -n "${OLLAMA_STRIP_GPU_LIBS:-}" ]]; then
    build_args+=(--build-arg "OLLAMA_STRIP_GPU_LIBS=${OLLAMA_STRIP_GPU_LIBS}")
  fi
  if [[ -n "${OLLAMA_MODELS_DIR:-}" ]]; then
    build_args+=(--build-arg "OLLAMA_MODELS_DIR=${OLLAMA_MODELS_DIR}")
  fi
  build_image "${COMPUTE_IMAGE_NAME}" "${ROOT_DIR}/server-2/Dockerfile" "${ROOT_DIR}/server-2" "${build_args[@]}"

  if [[ "${BUILD_EIF}" == "true" ]]; then
    if ! command -v nitro-cli >/dev/null 2>&1; then
      echo "nitro-cli is required for BUILD_EIF=true" >&2
      exit 1
    fi
    mkdir -p "${EIF_OUTPUT_DIR}"
    local compute_tag="${COMPUTE_IMAGE_NAME}:${IMAGE_TAG}"
    if [[ -n "${REGISTRY}" ]]; then
      compute_tag="${REGISTRY}/${compute_tag}"
    fi
    echo "Building EIF from ${compute_tag}"
    nitro-cli build-enclave --docker-uri "${compute_tag}" \
      --output-file "${EIF_OUTPUT_DIR}/compute.eif" \
      ${NITRO_CLI_ARGS:-}
  fi
}

build_client() {
  build_image "${CLIENT_IMAGE_NAME}" "${ROOT_DIR}/client/Dockerfile" "${ROOT_DIR}/client"
}

build_auth() {
  build_image "${AUTH_IMAGE_NAME}" "${ROOT_DIR}/server-3/Dockerfile" "${ROOT_DIR}/server-3"
}

case "${COMPONENT}" in
  all)
    build_client
    build_router
    build_compute
    build_auth
    ;;
  client)
    build_client
    ;;
  server-1)
    build_router
    ;;
  server-2)
    build_compute
    ;;
  server-3)
    build_auth
    ;;
  *)
    echo "Unknown component: ${COMPONENT}" >&2
    echo "Valid values: all, client, server-1, server-2, server-3" >&2
    exit 1
    ;;
esac
