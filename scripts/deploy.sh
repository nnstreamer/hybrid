#!/usr/bin/env bash
# Objective: Deploy OpenPCC router and compute nodes to AWS EC2.
# Usage examples:
# - COMPONENT=server-1 AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... SECURITY_GROUP_ID=... INSTANCE_PROFILE_ARN=... AMI_ID=... ./scripts/deploy.sh
# - COMPONENT=server-2 AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... SECURITY_GROUP_ID=... INSTANCE_PROFILE_ARN=... AMI_ID=... COMPUTE_EIF_S3_URI=s3://bucket/compute.eif ./scripts/deploy.sh
# - COMPONENT=all AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... SECURITY_GROUP_ID=... INSTANCE_PROFILE_ARN=... AMI_ID=... ./scripts/deploy.sh
# Notes:
# - Requires AWS credentials in the environment.
# - Compute instances require Nitro Enclaves enabled instance types.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPONENT="${COMPONENT:-all}"
AWS_REGION="${AWS_REGION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
ECR_REGISTRY="${ECR_REGISTRY:-}"

ROUTER_IMAGE_NAME="${ROUTER_IMAGE_NAME:-openpcc-router}"
COMPUTE_IMAGE_NAME="${COMPUTE_IMAGE_NAME:-openpcc-compute}"

SUBNET_ID="${SUBNET_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
INSTANCE_PROFILE_ARN="${INSTANCE_PROFILE_ARN:-}"
KEY_NAME="${KEY_NAME:-}"

AMI_ID="${AMI_ID:-}"
ROUTER_AMI_ID="${ROUTER_AMI_ID:-${AMI_ID}}"
COMPUTE_AMI_ID="${COMPUTE_AMI_ID:-${AMI_ID}}"

ROUTER_INSTANCE_TYPE="${ROUTER_INSTANCE_TYPE:-t3.small}"
COMPUTE_INSTANCE_TYPE="${COMPUTE_INSTANCE_TYPE:-c5.2xlarge}"

COMPUTE_EIF_S3_URI="${COMPUTE_EIF_S3_URI:-}"
ENCLAVE_CPU_COUNT="${ENCLAVE_CPU_COUNT:-2}"
ENCLAVE_MEMORY_MIB="${ENCLAVE_MEMORY_MIB:-2048}"
NITRO_RUN_ARGS="${NITRO_RUN_ARGS:-}"

require_env() {
  local name="$1"
  if [[ -z "${!name}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require_env AWS_REGION
require_env ECR_REGISTRY
require_env SUBNET_ID
require_env SECURITY_GROUP_ID
require_env INSTANCE_PROFILE_ARN

router_image_uri="${ECR_REGISTRY}/${ROUTER_IMAGE_NAME}:${IMAGE_TAG}"
compute_image_uri="${ECR_REGISTRY}/${COMPUTE_IMAGE_NAME}:${IMAGE_TAG}"

make_common_args() {
  local args=(
    --subnet-id "${SUBNET_ID}"
    --security-group-ids "${SECURITY_GROUP_ID}"
    --iam-instance-profile "Arn=${INSTANCE_PROFILE_ARN}"
  )

  if [[ -n "${KEY_NAME}" ]]; then
    args+=(--key-name "${KEY_NAME}")
  fi

  printf '%s\n' "${args[@]}"
}

deploy_router() {
  if [[ -z "${ROUTER_AMI_ID}" ]]; then
    echo "Missing required environment variable: ROUTER_AMI_ID or AMI_ID" >&2
    exit 1
  fi
  local user_data
  user_data="$(mktemp)"
  cat >"${user_data}" <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io awscli
systemctl enable --now docker
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker pull "${router_image_uri}"
docker run -d --restart unless-stopped --name openpcc-router -p 3600:3600 -p 3501:3501 "${router_image_uri}"
EOF

  mapfile -t common_args < <(make_common_args)

  aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${ROUTER_AMI_ID}" \
    --instance-type "${ROUTER_INSTANCE_TYPE}" \
    --user-data "file://${user_data}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-router}]" \
    "${common_args[@]}"

  rm -f "${user_data}"
}

deploy_compute() {
  if [[ -z "${COMPUTE_AMI_ID}" ]]; then
    echo "Missing required environment variable: COMPUTE_AMI_ID or AMI_ID" >&2
    exit 1
  fi
  local user_data
  user_data="$(mktemp)"
  cat >"${user_data}" <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io awscli aws-nitro-enclaves-cli
systemctl enable --now docker
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker pull "${compute_image_uri}"

EIF_PATH="/opt/openpcc/compute.eif"
mkdir -p "/opt/openpcc"

if [[ -n "${COMPUTE_EIF_S3_URI}" ]]; then
  aws s3 cp "${COMPUTE_EIF_S3_URI}" "\${EIF_PATH}"
else
  nitro-cli build-enclave --docker-uri "${compute_image_uri}" --output-file "\${EIF_PATH}"
fi

nitro-cli run-enclave --eif-path "\${EIF_PATH}" --cpu-count "${ENCLAVE_CPU_COUNT}" --memory "${ENCLAVE_MEMORY_MIB}" ${NITRO_RUN_ARGS}
EOF

  mapfile -t common_args < <(make_common_args)

  aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${COMPUTE_AMI_ID}" \
    --instance-type "${COMPUTE_INSTANCE_TYPE}" \
    --enclave-options "Enabled=true" \
    --user-data "file://${user_data}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-compute}]" \
    "${common_args[@]}"

  rm -f "${user_data}"
}

case "${COMPONENT}" in
  all)
    deploy_router
    deploy_compute
    ;;
  server-1)
    deploy_router
    ;;
  server-2)
    deploy_compute
    ;;
  *)
    echo "Unknown component: ${COMPONENT}" >&2
    echo "Valid values: all, server-1, server-2" >&2
    exit 1
    ;;
esac
