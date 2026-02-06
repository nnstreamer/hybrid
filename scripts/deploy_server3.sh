#!/usr/bin/env bash
# Objective: Deploy OpenPCC server-3 (auth) to AWS EC2.
# Usage examples:
# - AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... AUTH_SECURITY_GROUP_ID=... \
#   AMI_ID=... INSTANCE_PROFILE_ARN=... SERVER3_CONFIG_PATH=server-3/config/server-3.sample.json \
#   ./scripts/deploy_server3.sh
# - AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... AUTH_SECURITY_GROUP_ID=... \
#   AUTH_AMI_ID=... INSTANCE_PROFILE_ARN=... ./scripts/deploy_server3.sh /path/to/server-3.json
# - Required: INSTANCE_PROFILE_ARN=... (optional: KEY_NAME=...)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWS_REGION="${AWS_REGION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
ECR_REGISTRY="${ECR_REGISTRY:-}"

AUTH_IMAGE_NAME="${AUTH_IMAGE_NAME:-openpcc-auth}"

SUBNET_ID="${SUBNET_ID:-}"
AUTH_SECURITY_GROUP_ID="${AUTH_SECURITY_GROUP_ID:-}"
INSTANCE_PROFILE_ARN="${INSTANCE_PROFILE_ARN:-}"
KEY_NAME="${KEY_NAME:-}"

AMI_ID="${AMI_ID:-}"
AUTH_AMI_ID="${AUTH_AMI_ID:-${AMI_ID}}"
AUTH_INSTANCE_TYPE="${AUTH_INSTANCE_TYPE:-t3.small}"

SERVER3_PORT="${SERVER3_PORT:-8080}"
SERVER3_BIND_ADDR="${SERVER3_BIND_ADDR:-0.0.0.0}"
SERVER3_LOG_LEVEL="${SERVER3_LOG_LEVEL:-INFO}"
SERVER3_CONFIG_PATH="${SERVER3_CONFIG_PATH:-}"
SERVER3_CONFIG_ARG=""

usage() {
  echo "Usage: $0 [server-3-config.json]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config|-c)
      shift
      if [[ $# -eq 0 || -z "${1:-}" ]]; then
        echo "Missing value for --config/-c" >&2
        usage
        exit 1
      fi
      SERVER3_CONFIG_ARG="$1"
      ;;
    *)
      SERVER3_CONFIG_ARG="$1"
      ;;
  esac
  shift || true
done

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
require_env AUTH_SECURITY_GROUP_ID
require_env INSTANCE_PROFILE_ARN
if [[ "${ECR_REGISTRY}" != public.ecr.aws/* ]]; then
  echo "ECR_REGISTRY must be a public ECR registry (public.ecr.aws/alias)." >&2
  exit 1
fi
if [[ -z "${AUTH_AMI_ID}" ]]; then
  echo "Missing required environment variable: AUTH_AMI_ID or AMI_ID" >&2
  exit 1
fi

if [[ -n "${SERVER3_CONFIG_ARG}" ]]; then
  SERVER3_CONFIG_PATH="${SERVER3_CONFIG_ARG}"
fi

if [[ -z "${SERVER3_CONFIG_PATH}" ]]; then
  echo "Missing required config: pass server-3 JSON file path (arg or SERVER3_CONFIG_PATH)" >&2
  usage
  exit 1
fi

if [[ ! -f "${SERVER3_CONFIG_PATH}" ]]; then
  echo "SERVER3_CONFIG_PATH not found: ${SERVER3_CONFIG_PATH}" >&2
  exit 1
fi

python3 - <<'PY' "${SERVER3_CONFIG_PATH}"
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except FileNotFoundError:
    print(f"server-3 config file not found: {path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as exc:
    print(f"server-3 config file is not valid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print("server-3 config JSON must be an object", file=sys.stderr)
    sys.exit(1)
PY

config_b64="$(base64 -w 0 "${SERVER3_CONFIG_PATH}")"

auth_image_uri="${ECR_REGISTRY}/${AUTH_IMAGE_NAME}:${IMAGE_TAG}"

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

user_data="$(mktemp)"
cat >"${user_data}" <<EOF
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io
systemctl enable --now docker
docker pull "${auth_image_uri}"
mkdir -p /etc/openpcc
echo "${config_b64}" > /etc/openpcc/server-3.json.b64
base64 -d /etc/openpcc/server-3.json.b64 > /etc/openpcc/server-3.json
rm -f /etc/openpcc/server-3.json.b64
docker run -d --restart unless-stopped --name openpcc-auth \
  -p ${SERVER3_PORT}:${SERVER3_PORT} \
  -e SERVER3_CONFIG_PATH=/etc/openpcc/server-3.json \
  -e SERVER3_PORT=${SERVER3_PORT} \
  -e SERVER3_BIND_ADDR=${SERVER3_BIND_ADDR} \
  -e SERVER3_LOG_LEVEL=${SERVER3_LOG_LEVEL} \
  "${auth_image_uri}"
EOF

mapfile -t common_args < <(make_common_args "${AUTH_SECURITY_GROUP_ID}")

instance_ids=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=openpcc-auth" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)
if [ -n "${instance_ids}" ]; then
  aws ec2 terminate-instances --instance-ids ${instance_ids}
fi

auth_instance_id=$(aws ec2 run-instances \
  --region "${AWS_REGION}" \
  --image-id "${AUTH_AMI_ID}" \
  --instance-type "${AUTH_INSTANCE_TYPE}" \
  --user-data "file://${user_data}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-auth}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  "${common_args[@]}")

rm -f "${user_data}"

if [[ -z "${auth_instance_id}" || "${auth_instance_id}" == "None" ]]; then
  echo "Failed to determine auth instance ID." >&2
  exit 1
fi

echo "Waiting for auth instance ${auth_instance_id} to be running..."
aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${auth_instance_id}"

auth_private_ip=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${auth_instance_id}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)
auth_public_ip=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${auth_instance_id}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [[ -z "${auth_private_ip}" || "${auth_private_ip}" == "None" ]]; then
  echo "Failed to determine auth private IP." >&2
  exit 1
fi
if [[ -z "${auth_public_ip}" || "${auth_public_ip}" == "None" ]]; then
  auth_public_ip="none"
fi

echo "Auth deployed: instance=${auth_instance_id} public_ip=${auth_public_ip} private_ip=${auth_private_ip}"
echo "AUTH_PUBLIC_IP=${auth_public_ip}"
