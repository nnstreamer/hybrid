#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPONENT="${COMPONENT:-all}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
REGISTRY="${REGISTRY:-}"
PUSH="${PUSH:-false}"
BUILD_EIF="${BUILD_EIF:-false}"
EIF_OUTPUT_DIR="${EIF_OUTPUT_DIR:-${ROOT_DIR}/artifacts}"

ROUTER_IMAGE_NAME="${ROUTER_IMAGE_NAME:-openpcc-router}"
COMPUTE_IMAGE_NAME="${COMPUTE_IMAGE_NAME:-openpcc-compute}"
CLIENT_IMAGE_NAME="${CLIENT_IMAGE_NAME:-openpcc-client}"

build_image() {
  local image_name="$1"
  local dockerfile="$2"
  local context_dir="$3"
  local image_tag="${image_name}:${IMAGE_TAG}"

  if [[ -n "${REGISTRY}" ]]; then
    image_tag="${REGISTRY}/${image_tag}"
  fi

  echo "Building ${image_tag} from ${dockerfile}"
  docker build -f "${dockerfile}" -t "${image_tag}" "${context_dir}"

  if [[ "${PUSH}" == "true" ]]; then
    echo "Pushing ${image_tag}"
    docker push "${image_tag}"
  fi
}

build_router() {
  build_image "${ROUTER_IMAGE_NAME}" "${ROOT_DIR}/server-1/Dockerfile" "${ROOT_DIR}/server-1"
}

build_compute() {
  build_image "${COMPUTE_IMAGE_NAME}" "${ROOT_DIR}/server-2/Dockerfile" "${ROOT_DIR}/server-2"

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

case "${COMPONENT}" in
  all)
    build_client
    build_router
    build_compute
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
  *)
    echo "Unknown component: ${COMPONENT}" >&2
    echo "Valid values: all, client, server-1, server-2" >&2
    exit 1
    ;;
esac
