#!/usr/bin/env bash
# Objective: Deploy OpenPCC compute node (server-2) to AWS EC2.
# Usage examples:
# - AWS_REGION=us-east-1 ECR_REGISTRY=... SUBNET_ID=... COMPUTE_SECURITY_GROUP_ID=... AMI_ID=... ROUTER_ADDRESS=http://10.0.1.10:3600 ./scripts/deploy_server2.sh
# - Optional: INSTANCE_PROFILE_ARN=... KEY_NAME=...
# Notes:
# - Requires AWS credentials in the environment.
# - Compute instances require Nitro Enclaves enabled instance types.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AWS_REGION="${AWS_REGION:-}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${ROOT_DIR}" rev-parse --short HEAD)}"
ECR_REGISTRY="${ECR_REGISTRY:-}"

COMPUTE_IMAGE_NAME="${COMPUTE_IMAGE_NAME:-openpcc-compute}"

SUBNET_ID="${SUBNET_ID:-}"
COMPUTE_SECURITY_GROUP_ID="${COMPUTE_SECURITY_GROUP_ID:-}"
INSTANCE_PROFILE_ARN="${INSTANCE_PROFILE_ARN:-}"
KEY_NAME="${KEY_NAME:-}"

AMI_ID="${AMI_ID:-}"
COMPUTE_AMI_ID="${COMPUTE_AMI_ID:-${AMI_ID}}"

COMPUTE_INSTANCE_TYPE="${COMPUTE_INSTANCE_TYPE:-c5.2xlarge}"

ROUTER_ADDRESS="${ROUTER_ADDRESS:-}"
ENCLAVE_CPU_COUNT="${ENCLAVE_CPU_COUNT:-2}"
ENCLAVE_MEMORY_MIB="${ENCLAVE_MEMORY_MIB:-2048}"
ENCLAVE_CID="${ENCLAVE_CID:-16}"
ROUTER_PROXY_HOST="${ROUTER_PROXY_HOST:-127.0.0.1}"
ROUTER_PROXY_PORT="${ROUTER_PROXY_PORT:-3600}"
TPM_SIMULATOR_CMD_PORT="${TPM_SIMULATOR_CMD_PORT:-2321}"
TPM_SIMULATOR_PLATFORM_PORT="${TPM_SIMULATOR_PLATFORM_PORT:-2322}"
NITRO_RUN_ARGS="${NITRO_RUN_ARGS:-}"
ENABLE_COMPUTE_MONITOR="${ENABLE_COMPUTE_MONITOR:-true}"

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
if [[ "${ECR_REGISTRY}" != public.ecr.aws/* ]]; then
  echo "ECR_REGISTRY must be a public ECR registry (public.ecr.aws/alias)." >&2
  exit 1
fi
compute_image_uri="${ECR_REGISTRY}/${COMPUTE_IMAGE_NAME}:${IMAGE_TAG}"

make_common_args() {
  local security_group_id="$1"
  local args=(
    --subnet-id "${SUBNET_ID}"
    --security-group-ids "${security_group_id}"
  )

  if [[ -n "${INSTANCE_PROFILE_ARN}" ]]; then
    args+=(--iam-instance-profile "Arn=${INSTANCE_PROFILE_ARN}")
  fi

  if [[ -n "${KEY_NAME}" ]]; then
    args+=(--key-name "${KEY_NAME}")
  fi

  printf '%s\n' "${args[@]}"
}

deploy_compute() {
  require_env COMPUTE_SECURITY_GROUP_ID
  if [[ -z "${ROUTER_ADDRESS}" ]]; then
    echo "Missing required environment variable: ROUTER_ADDRESS" >&2
    echo "Provide ROUTER_ADDRESS when deploying compute without router." >&2
    exit 1
  fi
  if [[ -z "${COMPUTE_AMI_ID}" ]]; then
    echo "Missing required environment variable: COMPUTE_AMI_ID or AMI_ID" >&2
    exit 1
  fi
  local monitor_app_b64=""
  local monitor_service_b64=""
  if [[ "${ENABLE_COMPUTE_MONITOR}" == "true" ]]; then
    local monitor_app_path
    local monitor_service_path
    monitor_app_path="${ROOT_DIR}/server-2/monitor/app.py"
    monitor_service_path="${ROOT_DIR}/server-2/monitor/openpcc-compute-monitor.service"
    if [[ ! -f "${monitor_app_path}" || ! -f "${monitor_service_path}" ]]; then
      echo "Compute monitor assets not found under server-2/monitor." >&2
      exit 1
    fi
    monitor_app_b64=$(base64 -w 0 "${monitor_app_path}")
    monitor_service_b64=$(base64 -w 0 "${monitor_service_path}")
  fi
  local user_data
  user_data="$(mktemp)"
  user_data_after_reboot="$(mktemp)"
  cat >"${user_data_after_reboot}" <<EOF
#!/bin/bash
ENABLE_COMPUTE_MONITOR="${ENABLE_COMPUTE_MONITOR}"
MONITOR_APP_B64="${monitor_app_b64}"
MONITOR_SERVICE_B64="${monitor_service_b64}"
modprobe nitro_enclaves || insmod "/usr/lib/modules/\$(uname -r)/kernel/drivers/virt/nitro_enclaves/nitro_enclaves.ko"
echo "nitro_enclaves" > /etc/modules-load.d/openpcc.conf
systemctl enable --now docker
usermod -aG docker \$(whoami)

git clone https://github.com/nnstreamer/aws-nitro-enclaves-cli.git --depth 1 -b ubuntu-22.04

cd aws-nitro-enclaves-cli
export NITRO_CLI_INSTALL_DIR=/
make nitro-cli
make vsock-proxy
make NITRO_CLI_INSTALL_DIR=/ install
source /etc/profile.d/nitro-cli-env.sh
echo source /etc/profile.d/nitro-cli-env.sh >> ~/.bashrc
nitro-cli-config -i
systemctl enable --now nitro-enclaves-allocator
systemctl start nitro-enclaves-allocator.service
systemctl enable nitro-enclaves-allocator.service
cd ..

docker pull "${compute_image_uri}"

EIF_PATH="/opt/openpcc/compute.eif"
mkdir -p "/opt/openpcc"
R_ADDRESS="${ROUTER_ADDRESS}"
R_COM_PORT="${ROUTER_COM_PORT:-8081}"

TOKEN="\$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
if [[ -n "\${TOKEN}" ]]; then
  COMPUTE_HOST="\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
else
  COMPUTE_HOST="\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
fi
if [[ -z "\${COMPUTE_HOST}" ]]; then
  COMPUTE_HOST="\$(hostname -I | awk '{print \$1}' || true)"
fi
if [[ -z "\${COMPUTE_HOST}" ]]; then
  echo "Failed to determine compute host IP." >&2
  exit 1
fi
R_PROXY_HOST="${ROUTER_PROXY_HOST}"
R_PROXY_PORT="${ROUTER_PROXY_PORT}"
R_PROXY_URL="http://\${R_PROXY_HOST}:\${R_PROXY_PORT}"
TPM_SIM_CMD_PORT="${TPM_SIMULATOR_CMD_PORT}"
TPM_SIM_PLATFORM_PORT="${TPM_SIMULATOR_PLATFORM_PORT}"
ENCLAVE_CID="${ENCLAVE_CID}"
if [[ "\${TPM_SIM_PLATFORM_PORT}" -ne "\$((TPM_SIM_CMD_PORT + 1))" ]]; then
  TPM_SIM_PLATFORM_PORT="\$((TPM_SIM_CMD_PORT + 1))"
fi
router_host="\${R_ADDRESS#http://}"
router_host="\${router_host#https://}"
router_host="\${router_host%%/*}"
router_port="3600"
if [[ "\${router_host}" == *:* ]]; then
  router_port="\${router_host##*:}"
  router_host="\${router_host%%:*}"
fi
if [[ -z "\${router_host}" ]]; then
  echo "Failed to parse router host from \${R_ADDRESS}" >&2
  exit 1
fi
mkdir -p /etc/nitro_enclaves
cat > /etc/nitro_enclaves/vsock-proxy.yaml <<PROXY_EOF
allowlist:
  - address: "\${router_host}"
    port: \${router_port}
  - address: "127.0.0.1"
    port: \${TPM_SIM_CMD_PORT}
  - address: "127.0.0.1"
    port: \${TPM_SIM_PLATFORM_PORT}
PROXY_EOF

TPM_SIM_DIR="/opt/openpcc/ms-tpm-20-ref"
TPM_SIM_BIN="\${TPM_SIM_DIR}/TPMCmd/Simulator/src/tpm2-simulator"
if [[ ! -x "\${TPM_SIM_BIN}" ]]; then
  rm -rf "\${TPM_SIM_DIR}"
  git clone --depth 1 https://github.com/microsoft/ms-tpm-20-ref.git "\${TPM_SIM_DIR}"
  (
    cd "\${TPM_SIM_DIR}/TPMCmd"
    ./bootstrap
    ./configure
    make -j"\$(nproc)"
  )
fi

cat > /etc/systemd/system/openpcc-tpm-sim.service <<UNIT_EOF
[Unit]
Description=OpenPCC TPM simulator (mssim)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=\${TPM_SIM_BIN} \${TPM_SIM_CMD_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/openpcc-vsock-router.service <<UNIT_EOF
[Unit]
Description=OpenPCC vsock proxy to router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vsock-proxy --config /etc/nitro_enclaves/vsock-proxy.yaml \${R_PROXY_PORT} \${router_host} \${router_port}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/openpcc-vsock-tpm-cmd.service <<UNIT_EOF
[Unit]
Description=OpenPCC vsock proxy to TPM simulator (cmd)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vsock-proxy --config /etc/nitro_enclaves/vsock-proxy.yaml \${TPM_SIM_CMD_PORT} 127.0.0.1 \${TPM_SIM_CMD_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/openpcc-vsock-tpm-platform.service <<UNIT_EOF
[Unit]
Description=OpenPCC vsock proxy to TPM simulator (platform)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vsock-proxy --config /etc/nitro_enclaves/vsock-proxy.yaml \${TPM_SIM_PLATFORM_PORT} 127.0.0.1 \${TPM_SIM_PLATFORM_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/openpcc-enclave-health-proxy.service <<UNIT_EOF
[Unit]
Description=OpenPCC TCP to vsock health proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:\${R_COM_PORT},reuseaddr,fork VSOCK-CONNECT:\${ENCLAVE_CID}:\${R_COM_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > /etc/systemd/system/openpcc-enclave.service <<UNIT_EOF
[Unit]
Description=OpenPCC Nitro Enclave
After=network-online.target nitro-enclaves-allocator.service openpcc-vsock-router.service openpcc-vsock-tpm-cmd.service openpcc-vsock-tpm-platform.service openpcc-tpm-sim.service
Wants=network-online.target nitro-enclaves-allocator.service openpcc-vsock-router.service openpcc-vsock-tpm-cmd.service openpcc-vsock-tpm-platform.service openpcc-tpm-sim.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=NITRO_CLI_ARTIFACTS=/var/lib/nitro_enclaves/artifacts
ExecStart=/usr/bin/nitro-cli run-enclave --eif-path "/opt/openpcc/compute.eif" --cpu-count "${ENCLAVE_CPU_COUNT}" --memory "${ENCLAVE_MEMORY_MIB}" --enclave-cid "${ENCLAVE_CID}" ${NITRO_RUN_ARGS}
ExecStop=/usr/bin/nitro-cli terminate-enclave --all

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now openpcc-tpm-sim.service
systemctl enable --now openpcc-vsock-router.service openpcc-vsock-tpm-cmd.service openpcc-vsock-tpm-platform.service
systemctl enable --now openpcc-enclave-health-proxy.service
systemctl enable openpcc-enclave.service
if [[ "${ENABLE_COMPUTE_MONITOR}" == "true" ]]; then
  MONITOR_DIR="/opt/openpcc/compute-monitor"
  mkdir -p "\${MONITOR_DIR}"
  printf '%s' "\${MONITOR_APP_B64}" | base64 -d > "\${MONITOR_DIR}/app.py"
  chmod 755 "\${MONITOR_DIR}/app.py"
  printf '%s' "\${MONITOR_SERVICE_B64}" | base64 -d > /etc/systemd/system/openpcc-compute-monitor.service
  systemctl daemon-reload
  systemctl enable --now openpcc-compute-monitor.service
fi
export NITRO_CLI_ARTIFACTS=/var/lib/nitro_enclaves/artifacts
mkdir -p "\${NITRO_CLI_ARTIFACTS}"

CONFIG_DIR="\$(mktemp -d)"
cat > "\${CONFIG_DIR}/router_com.yaml" <<CONFIG_EOF
http:
  port: "\${R_COM_PORT}"
evidence:
  socket: "\${EVIDENCE_SOCKET:-/tmp/router.sock}"
  timeout: \${EVIDENCE_TIMEOUT:-30s}
models:
  - "\${MODEL_1:-llama3.2:1b}"
router_com:
  check_compute_boot_exit: \${CHECK_COMPUTE_BOOT_EXIT:-false}
  tpm:
    device: "\${TPM_DEVICE:-/dev/tpmrm0}"
    simulate: \${SIMULATE_TPM:-true}
    rek_handle: \${REK_HANDLE:-0x81000002}
    simulator_cmd_address: "\${SIM_CMD_ADDRESS:-127.0.0.1:${TPM_SIMULATOR_CMD_PORT}}"
    simulator_platform_address: "\${SIM_PLATFORM_ADDRESS:-127.0.0.1:${TPM_SIMULATOR_PLATFORM_PORT}}"
  worker:
    binary_path: "\${WORKER_BIN_PATH:-/opt/confidentcompute/bin/compute_worker}"
    llm_base_url: "\${LLM_BASE_URL:-http://127.0.0.1:11434}"
    badge_public_key: "\${BADGE_PUBLIC_KEY_B64:-LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUNvd0JRWURLMlZ3QXlFQTFKNXJhQTdEZTQ0elFSRVpxU21BbkRMK1RObjFPUUROZW1sWmc4eWc3azg9Ci0tLS0tRU5EIFBVQkxJQyBLRVktLS0tLQo=}"
router_agent:
  tags:
    - llm
    - "engine=\${INFERENCE_ENGINE_TYPE:-ollama}"
    - "model=\${MODEL_1:-llama3.2:1b}"
  node_target_url: "http://\${COMPUTE_HOST}:\${R_COM_PORT}/"
  node_healthcheck_url: "http://\${COMPUTE_HOST}:\${R_COM_PORT}/_health"
  router_base_url: "\${R_PROXY_URL}"
CONFIG_EOF

cat > "\${CONFIG_DIR}/compute_boot.yaml" <<CONFIG_EOF
inference_engine:
  type: \${INFERENCE_ENGINE_TYPE:-ollama}
  skip: \${INFERENCE_ENGINE_SKIP:-false}
  models:
    - "\${INFERENCE_ENGINE_MODEL_1:-llama3.2:1b}"
  local_dev: \${INFERENCE_ENGINE_LOCAL_DEV:-true}
  url: "\${INFERENCE_ENGINE_URL:-http://127.0.0.1:11434}"
  systemd_service_name: "\${INFERENCE_ENGINE_SERVICE:-ollama.service}"
tpm:
  primary_key_handle: \${TPM_PRIMARY_KEY_HANDLE:-0x81000001}
  child_key_handle: \${TPM_CHILD_KEY_HANDLE:-0x81000002}
  rek_creation_ticket_handle: \${TPM_REK_TICKET_HANDLE:-0x01c0000A}
  rek_creation_hash_handle: \${TPM_REK_HASH_HANDLE:-0x01c0000B}
  attestation_key_handle: \${TPM_ATTESTATION_KEY_HANDLE:-0x81000003}
  tpm_type: \${TPM_TYPE:-Simulator}
  simulator_cmd_address: "127.0.0.1:${TPM_SIMULATOR_CMD_PORT}"
  simulator_platform_address: "127.0.0.1:${TPM_SIMULATOR_PLATFORM_PORT}"
attestation:
  fake_secret: "\${FAKE_ATTESTATION_SECRET:-123456}"
gpu:
  required: \${GPU_REQUIRED:-false}
  attestation_mode: \${GPU_ATTESTATION_MODE:-none}
transparency:
  image_sigstore_bundle: "\${COMPUTE_IMAGE_SIGSTORE_BUNDLE:-}"
CONFIG_EOF

cat > "\${CONFIG_DIR}/Dockerfile" <<DOCKER_EOF
FROM ${compute_image_uri}
COPY router_com.yaml /etc/openpcc/router_com.yaml
COPY compute_boot.yaml /etc/openpcc/compute_boot.yaml
DOCKER_EOF
docker build -t "${compute_image_uri}-routercfg" "\${CONFIG_DIR}"
nitro-cli build-enclave --docker-uri "${compute_image_uri}-routercfg" --output-file "\${EIF_PATH}"
rm -rf "\${CONFIG_DIR}"

mv \$0 /
reboot now
EOF

script_after_reboot_b64=$(gzip -c "${user_data_after_reboot}" | base64 -w 0)

  cat >"${user_data}" <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io python3 curl git build-essential gcc linux-modules-extra-aws socat autoconf autoconf-archive automake pkg-config libssl-dev gzip

cat >"/var/lib/cloud/scripts/per-boot/initserver.sh.gz.b64" <<'INEOF'
${script_after_reboot_b64}
INEOF
base64 -d "/var/lib/cloud/scripts/per-boot/initserver.sh.gz.b64" > "/var/lib/cloud/scripts/per-boot/initserver.sh.gz"
gzip -d "/var/lib/cloud/scripts/per-boot/initserver.sh.gz"
rm -f "/var/lib/cloud/scripts/per-boot/initserver.sh.gz.b64"
chmod 744 /var/lib/cloud/scripts/per-boot/initserver.sh

reboot now
EOF


  mapfile -t common_args < <(make_common_args "${COMPUTE_SECURITY_GROUP_ID}")

  local instance_ids
  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=openpcc-compute" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
  if [ -n "$instance_ids" ]; then
    aws ec2 terminate-instances --instance-ids $instance_ids
  fi

  ls -l ${user_data}

  local compute_instance_id
  compute_instance_id=$(aws ec2 run-instances \
    --region "${AWS_REGION}" \
    --image-id "${COMPUTE_AMI_ID}" \
    --instance-type "${COMPUTE_INSTANCE_TYPE}" \
    --enclave-options "Enabled=true" \
    --user-data "file://${user_data}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=openpcc-compute}]" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
    --query 'Instances[0].InstanceId' \
    --output text \
    "${common_args[@]}")

  rm -f "${user_data}"

  if [[ -z "${compute_instance_id}" || "${compute_instance_id}" == "None" ]]; then
    echo "Failed to determine compute instance ID." >&2
    exit 1
  fi

  echo "Waiting for compute instance ${compute_instance_id} to be running..."
  aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${compute_instance_id}"

  local compute_public_ip
  local compute_private_ip
  compute_public_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${compute_instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  compute_private_ip=$(aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --instance-ids "${compute_instance_id}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

  if [[ -z "${compute_public_ip}" || "${compute_public_ip}" == "None" ]]; then
    compute_public_ip="none"
  fi
  if [[ -z "${compute_private_ip}" || "${compute_private_ip}" == "None" ]]; then
    compute_private_ip="unknown"
  fi

  echo "Compute deployed: instance=${compute_instance_id} public_ip=${compute_public_ip} private_ip=${compute_private_ip}"
  echo "COMPUTE_PUBLIC_IP=${compute_public_ip}"
}

deploy_compute
