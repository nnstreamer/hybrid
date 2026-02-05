#!/usr/bin/env bash
# Objective: Deploy OpenPCC oHTTP relay (server-4) to AWS EC2.
# Usage examples:
# - RELAY_UPSTREAM_GATEWAY_URL=http://10.0.1.23:3200 AWS_REGION=us-east-1 \
#   ECR_REGISTRY=... SUBNET_ID=... RELAY_SECURITY_GROUP_ID=... \
#   INSTANCE_PROFILE_ARN=... AMI_ID=... ./scripts/deploy_server4.sh
# Notes:
# - Requires AWS credentials in the environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWS_REGION="${AWS_REGION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
ECR_REGISTRY="${ECR_REGISTRY:-}"

RELAY_IMAGE_NAME="${RELAY_IMAGE_NAME:-${SERVER4_IMAGE_NAME:-openpcc-relay}}"

SUBNET_ID="${SUBNET_ID:-}"
RELAY_SECURITY_GROUP_ID="${RELAY_SECURITY_GROUP_ID:-}"
INSTANCE_PROFILE_ARN="${INSTANCE_PROFILE_ARN:-}"
KEY_NAME="${KEY_NAME:-}"

AMI_ID="${AMI_ID:-}"
RELAY_AMI_ID="${RELAY_AMI_ID:-${AMI_ID}}"
RELAY_INSTANCE_TYPE="${RELAY_INSTANCE_TYPE:-t3.small}"

RELAY_UPSTREAM_GATEWAY_URL="${RELAY_UPSTREAM_GATEWAY_URL:-}"

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
require_env RELAY_SECURITY_GROUP_ID
require_env INSTANCE_PROFILE_ARN
require_env RELAY_UPSTREAM_GATEWAY_URL

if [[ -z "${RELAY_AMI_ID}" ]]; then
  echo "Missing required environment variable: RELAY_AMI_ID or AMI_ID" >&2
  exit 1
fi

relay_image_uri="${ECR_REGISTRY}/${RELAY_IMAGE_NAME}:${IMAGE_TAG}"

make_common_args() {
  local security_group_id="$1"
  local args=(
    --subnet-id "${SUBNET_ID}"
    --security-group-ids "${security_group_id}"
    --iam-instance-profile "Arn=${INSTANCE_PROFILE_ARN}"
  )

  if [[ -n "${KEY_NAME}" ]]; then
    args+=(--key-name "${KEY_NAME}")
  fi

  printf '%s\n' "${args[@]}"
}

deploy_relay() {
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
docker pull "${relay_image_uri}"
# NOTE: Ensure the relay security group allows TCP 3100 (relay).
docker run -d --restart unless-stopped --name openpcc-relay -p 3100:3100 \
  -e "RELAY_UPSTREAM_GATEWAY_URL=${RELAY_UPSTREAM_GATEWAY_URL}" \
  "${relay_image_uri}"
EOF

  mapfile -t common_args < <(make_common_args "${RELAY_SECURITY_GROUP_ID}")

  local instance_ids
  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=openpcc-relay" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  if [ -n "$instance_ids" ]; then
    aws ec2 terminate-instances --instance-ids $instance_ids
  fi

  local relay_instance_id
  relay_instance_id=$(aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${RELAY_AMI_ID}" \
    --instance-type "${RELAY_INSTANCE_TYPE}" \
    --associate-public-ip-address \
    --user-data "file://${user_data}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-relay}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    "${common_args[@]}")

  rm -f "${user_data}"

  if [[ -z "${relay_instance_id}" || "${relay_instance_id}" == "None" ]]; then
    echo "Failed to determine relay instance ID." >&2
    exit 1
  fi

  echo "Waiting for relay instance ${relay_instance_id} to be running..."
  aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${relay_instance_id}"

  local relay_private_ip
  local relay_public_ip
  relay_private_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${relay_instance_id}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)
  relay_public_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${relay_instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  if [[ -z "${relay_private_ip}" || "${relay_private_ip}" == "None" ]]; then
    echo "Failed to determine relay private IP." >&2
    exit 1
  fi
  if [[ -z "${relay_public_ip}" || "${relay_public_ip}" == "None" ]]; then
    relay_public_ip="none"
  fi

  echo "Relay deployed: instance=${relay_instance_id} public_ip=${relay_public_ip} private_ip=${relay_private_ip}"
  echo "RELAY_PUBLIC_IP=${relay_public_ip}"
}

deploy_relay
