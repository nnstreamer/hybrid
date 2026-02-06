#!/usr/bin/env bash
# Objective: Deploy OpenPCC router (server-1) to AWS EC2.
# Usage examples:
# - AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... ROUTER_SECURITY_GROUP_ID=... AMI_ID=... INSTANCE_PROFILE_ARN=... ./scripts/deploy_server1.sh
# - AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... ROUTER_SECURITY_GROUP_ID=... AMI_ID=... INSTANCE_PROFILE_ARN=... OHTTP_SEEDS_SECRET_REF=... ./scripts/deploy_server1.sh
# - Required: INSTANCE_PROFILE_ARN=... (optional: KEY_NAME=...)
# Notes:
# - Requires AWS credentials in the environment.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWS_REGION="${AWS_REGION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
ECR_REGISTRY="${ECR_REGISTRY:-}"

ROUTER_IMAGE_NAME="${ROUTER_IMAGE_NAME:-openpcc-router}"

SUBNET_ID="${SUBNET_ID:-}"
ROUTER_SECURITY_GROUP_ID="${ROUTER_SECURITY_GROUP_ID:-}"
INSTANCE_PROFILE_ARN="${INSTANCE_PROFILE_ARN:-}"
KEY_NAME="${KEY_NAME:-}"

AMI_ID="${AMI_ID:-}"
ROUTER_AMI_ID="${ROUTER_AMI_ID:-${AMI_ID}}"

ROUTER_INSTANCE_TYPE="${ROUTER_INSTANCE_TYPE:-t3.small}"

ROUTER_ADDRESS="${ROUTER_ADDRESS:-}"
# NOTE: If set, this is used to load gateway OHTTP seeds.
OHTTP_SEEDS_SECRET_REF="${OHTTP_SEEDS_SECRET_REF:-}"
OHTTP_SEEDS_JSON="${OHTTP_SEEDS_JSON:-}"
OHTTP_SEEDS_JSON_B64=""
if [[ -n "${OHTTP_SEEDS_JSON}" ]]; then
  OHTTP_SEEDS_JSON_B64="$(printf '%s' "${OHTTP_SEEDS_JSON}" | base64 -w 0)"
fi

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
require_env INSTANCE_PROFILE_ARN
if [[ "${ECR_REGISTRY}" != public.ecr.aws/* ]]; then
  echo "ECR_REGISTRY must be a public ECR registry (public.ecr.aws/alias)." >&2
  exit 1
fi
router_image_uri="${ECR_REGISTRY}/${ROUTER_IMAGE_NAME}:${IMAGE_TAG}"

make_common_args() {
  local security_group_id="$1"
  local args=(
    --subnet-id "${SUBNET_ID}"
    --security-group-ids "${security_group_id}"
  )

  args+=(--iam-instance-profile "Arn=${INSTANCE_PROFILE_ARN}")

  if [[ -n "${KEY_NAME}" ]]; then
    args+=(--key-name "${KEY_NAME}")
  fi

  printf '%s\n' "${args[@]}"
}

deploy_router() {
  require_env ROUTER_SECURITY_GROUP_ID
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
apt-get install -y docker.io
systemctl enable --now docker
docker pull "${router_image_uri}"
# NOTE: Ensure the router security group allows TCP 3200 (gateway),
# 3501 (credithole), and 3600 (router).
set +x
OHTTP_ENV_ARGS=()
if [[ -n "${OHTTP_SEEDS_SECRET_REF}" ]]; then
  OHTTP_ENV_ARGS+=(-e "OHTTP_SEEDS_SECRET_REF=${OHTTP_SEEDS_SECRET_REF}")
fi
OHTTP_SEEDS_JSON=""
if [[ -n "${OHTTP_SEEDS_JSON_B64}" ]]; then
  OHTTP_SEEDS_JSON="\$(printf '%s' "${OHTTP_SEEDS_JSON_B64}" | base64 -d)"
fi
if [[ -z "\${OHTTP_SEEDS_JSON}" && -n "${OHTTP_SEEDS_SECRET_REF}" ]]; then
  secret_ref="${OHTTP_SEEDS_SECRET_REF}"
  if [[ "\${secret_ref}" == secretsmanager:* ]]; then
    secret_ref="\${secret_ref#secretsmanager:}"
  fi
  if [[ "\${secret_ref}" == arn:* || "\${secret_ref}" == *:secret:* ]]; then
    OHTTP_SEEDS_JSON=\$(aws secretsmanager get-secret-value --region "${AWS_REGION}" --secret-id "\${secret_ref}" --query SecretString --output text)
  elif [[ "\${secret_ref}" == ssm:* ]]; then
    param_name="\${secret_ref#ssm:}"
    OHTTP_SEEDS_JSON=\$(aws ssm get-parameter --region "${AWS_REGION}" --with-decryption --name "\${param_name}" --query Parameter.Value --output text)
  else
    echo "Unsupported OHTTP_SEEDS_SECRET_REF format: ${OHTTP_SEEDS_SECRET_REF}" >&2
    exit 1
  fi
fi
if [[ -n "\${OHTTP_SEEDS_JSON}" ]]; then
  OHTTP_ENV_ARGS+=(-e "OHTTP_SEEDS_JSON=\${OHTTP_SEEDS_JSON}")
fi
docker run -d --restart unless-stopped --name openpcc-router -p 3600:3600 -p 3501:3501 -p 3200:3200 "\${OHTTP_ENV_ARGS[@]}" "${router_image_uri}"
EOF

  mapfile -t common_args < <(make_common_args "${ROUTER_SECURITY_GROUP_ID}")

  local instance_ids
  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=openpcc-router" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  if [ -n "$instance_ids" ]; then
    aws ec2 terminate-instances --instance-ids $instance_ids
  fi

  local router_instance_id
  router_instance_id=$(aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${ROUTER_AMI_ID}" \
    --instance-type "${ROUTER_INSTANCE_TYPE}" \
    --user-data "file://${user_data}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-router}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    "${common_args[@]}")

  rm -f "${user_data}"

  if [[ -z "${router_instance_id}" || "${router_instance_id}" == "None" ]]; then
    echo "Failed to determine router instance ID." >&2
    exit 1
  fi

  echo "Waiting for router instance ${router_instance_id} to be running..."
  aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${router_instance_id}"

  local router_private_ip
  local router_public_ip
  router_private_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${router_instance_id}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)
  router_public_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${router_instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  if [[ -z "${router_private_ip}" || "${router_private_ip}" == "None" ]]; then
    echo "Failed to determine router private IP." >&2
    exit 1
  fi
  if [[ -z "${router_public_ip}" || "${router_public_ip}" == "None" ]]; then
    router_public_ip="none"
  fi

  if [[ -z "${ROUTER_ADDRESS}" ]]; then
    ROUTER_ADDRESS="http://${router_private_ip}:3600"
  fi

  echo "Router deployed: instance=${router_instance_id} public_ip=${router_public_ip} private_ip=${router_private_ip} router_address=${ROUTER_ADDRESS}"
  echo "ROUTER_PUBLIC_IP=${router_public_ip}"
}

deploy_router
