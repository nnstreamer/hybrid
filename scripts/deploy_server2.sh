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
TPM_SUPPORT="${TPM_SUPPORT:-v2.0}"
COMPUTE_IMAGE_SIGSTORE_BUNDLE="${COMPUTE_IMAGE_SIGSTORE_BUNDLE:-}"
COMPUTE_IMAGE_SIGSTORE_BUNDLE_REF="${COMPUTE_IMAGE_SIGSTORE_BUNDLE_REF:-}"

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

load_image_info() {
  local image_id="$1"
  local image_json
  image_json="$(mktemp)"
  aws ec2 describe-images --region "${AWS_REGION}" --image-ids "${image_id}" --output json > "${image_json}"
  local assignments
  assignments="$(python3 - "${image_json}" <<'PY'
import json
import shlex
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

images = data.get("Images") or []
if not images:
    sys.exit(2)

img = images[0]

def q(val: object) -> str:
    if val is None:
        return shlex.quote("")
    return shlex.quote(str(val))

def bool_str(val: object) -> str:
    return "true" if val else "false"

print(f"tpm_support={q(img.get('TpmSupport'))}")
print(f"boot_mode={q(img.get('BootMode'))}")
print(f"root_device_name={q(img.get('RootDeviceName'))}")
print(f"architecture={q(img.get('Architecture'))}")
print(f"virtualization_type={q(img.get('VirtualizationType'))}")
print(f"ena_support={q(bool_str(img.get('EnaSupport')))}")
print(f"sriov_net_support={q(img.get('SriovNetSupport'))}")

root_name = img.get("RootDeviceName")
bdm_json = ""
root_snapshot_id = ""
if root_name:
    for bdm in img.get("BlockDeviceMappings", []):
        if bdm.get("DeviceName") != root_name:
            continue
        ebs = bdm.get("Ebs") or {}
        if not ebs.get("SnapshotId"):
            continue
        allowed = [
            "SnapshotId",
            "VolumeSize",
            "VolumeType",
            "DeleteOnTermination",
            "Iops",
            "Throughput",
        ]
        ebs_filtered = {key: ebs[key] for key in allowed if key in ebs}
        root_snapshot_id = ebs_filtered.get("SnapshotId") or ""
        bdm_json = json.dumps([{"DeviceName": root_name, "Ebs": ebs_filtered}])
        break

print(f"root_bdm_json={q(bdm_json)}")
print(f"root_snapshot_id={q(root_snapshot_id)}")
PY
)"
  rm -f "${image_json}"
  if [[ -z "${assignments}" ]]; then
    echo "Failed to parse AMI metadata for ${image_id}." >&2
    exit 1
  fi
  eval "${assignments}"
}

is_nitrotpm_enabled() {
  local tpm_support="$1"
  local boot_mode="$2"
  if [[ "${tpm_support}" != "v2.0" ]]; then
    return 1
  fi
  if [[ "${boot_mode}" != "uefi" && "${boot_mode}" != "uefi-preferred" ]]; then
    return 1
  fi
  return 0
}

ensure_snapshot_owned() {
  local snapshot_id="$1"
  local account_id
  account_id=$(aws sts get-caller-identity --region "${AWS_REGION}" --query Account --output text)
  local owner_id
  owner_id=$(aws ec2 describe-snapshots \
    --region "${AWS_REGION}" \
    --snapshot-ids "${snapshot_id}" \
    --query 'Snapshots[0].OwnerId' \
    --output text 2>/dev/null || true)
  if [[ -n "${owner_id}" && "${owner_id}" != "None" && "${owner_id}" == "${account_id}" ]]; then
    echo "${snapshot_id}"
    return 0
  fi

  echo "Copying snapshot ${snapshot_id} into account ${account_id}" >&2
  local copy_description
  copy_description="OpenPCC copy of ${snapshot_id}"
  local new_snapshot_id
  new_snapshot_id=$(aws ec2 copy-snapshot \
    --region "${AWS_REGION}" \
    --source-region "${AWS_REGION}" \
    --source-snapshot-id "${snapshot_id}" \
    --description "${copy_description}" \
    --query 'SnapshotId' \
    --output text)
  if [[ -z "${new_snapshot_id}" || "${new_snapshot_id}" == "None" ]]; then
    echo "Failed to copy snapshot ${snapshot_id}." >&2
    exit 1
  fi

  aws ec2 create-tags \
    --region "${AWS_REGION}" \
    --resources "${new_snapshot_id}" \
    --tags "Key=Name,Value=openpcc-copy-${snapshot_id}" \
           "Key=OpenPccSourceSnapshot,Value=${snapshot_id}" \
           "Key=OpenPccNitroTpm,Value=true"

  echo "Waiting for snapshot ${new_snapshot_id} to complete..." >&2
  aws ec2 wait snapshot-completed --region "${AWS_REGION}" --snapshot-ids "${new_snapshot_id}"
  echo "${new_snapshot_id}"
}

resolve_nitrotpm_ami() {
  local source_ami="${COMPUTE_AMI_ID}"
  echo "Checking NitroTPM support for AMI ${source_ami}"
  load_image_info "${source_ami}"
  local source_tpm_support="${tpm_support}"
  local source_boot_mode="${boot_mode}"
  local source_root_device_name="${root_device_name}"
  local source_root_bdm_json="${root_bdm_json}"
  local source_root_snapshot_id="${root_snapshot_id}"
  local source_architecture="${architecture}"
  local source_virtualization_type="${virtualization_type}"
  local source_ena_support="${ena_support}"
  local source_sriov_net_support="${sriov_net_support}"

  if is_nitrotpm_enabled "${source_tpm_support}" "${source_boot_mode}"; then
    echo "Source AMI already NitroTPM-enabled: ${source_ami}"
    return 0
  fi

  local cached_ami
  cached_ami=$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --owners self \
    --filters "Name=tag:OpenPccSourceAmi,Values=${source_ami}" \
              "Name=tag:OpenPccNitroTpm,Values=true" \
              "Name=state,Values=available" \
    --query "Images | sort_by(@,&CreationDate)[-1].ImageId" \
    --output text)

  if [[ -n "${cached_ami}" && "${cached_ami}" != "None" ]]; then
    load_image_info "${cached_ami}"
    if is_nitrotpm_enabled "${tpm_support}" "${boot_mode}"; then
      COMPUTE_AMI_ID="${cached_ami}"
      echo "Using cached NitroTPM AMI: ${COMPUTE_AMI_ID}"
      return 0
    fi
  fi

  if [[ -z "${TPM_SUPPORT}" ]]; then
    echo "TPM_SUPPORT is empty; cannot register NitroTPM AMI." >&2
    exit 1
  fi
  if [[ -z "${source_root_device_name}" || -z "${source_root_bdm_json}" || -z "${source_root_snapshot_id}" ]]; then
    echo "Failed to determine root snapshot for ${source_ami}; cannot register NitroTPM AMI." >&2
    exit 1
  fi
  if [[ -z "${source_architecture}" || -z "${source_virtualization_type}" ]]; then
    echo "Missing AMI metadata (architecture/virtualization_type) for ${source_ami}." >&2
    exit 1
  fi

  local owned_snapshot_id
  owned_snapshot_id="$(ensure_snapshot_owned "${source_root_snapshot_id}")"
  if [[ "${owned_snapshot_id}" != "${source_root_snapshot_id}" ]]; then
    source_root_bdm_json="$(python3 - "${source_root_bdm_json}" "${owned_snapshot_id}" <<'PY'
import json
import sys

raw = sys.argv[1]
new_snapshot_id = sys.argv[2]
bdm = json.loads(raw)
if not isinstance(bdm, list) or not bdm:
    raise SystemExit("invalid block device mapping json")
ebs = bdm[0].get("Ebs")
if not isinstance(ebs, dict):
    raise SystemExit("missing ebs mapping")
ebs["SnapshotId"] = new_snapshot_id
print(json.dumps(bdm))
PY
)"
  fi

  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local ami_name
  ami_name="openpcc-compute-tpm-${source_ami}-${timestamp}"
  local register_args=(
    --region "${AWS_REGION}"
    --name "${ami_name}"
    --description "OpenPCC NitroTPM AMI from ${source_ami}"
    --architecture "${source_architecture}"
    --virtualization-type "${source_virtualization_type}"
    --root-device-name "${source_root_device_name}"
    --block-device-mappings "${source_root_bdm_json}"
    --boot-mode "uefi"
    --tpm-support "${TPM_SUPPORT}"
  )
  if [[ "${source_ena_support}" == "true" ]]; then
    register_args+=(--ena-support)
  fi
  if [[ -n "${source_sriov_net_support}" && "${source_sriov_net_support}" != "None" ]]; then
    register_args+=(--sriov-net-support "${source_sriov_net_support}")
  fi

  echo "Registering NitroTPM AMI for ${source_ami}"
  local new_ami_id
  new_ami_id=$(aws ec2 register-image "${register_args[@]}" --query 'ImageId' --output text)
  if [[ -z "${new_ami_id}" || "${new_ami_id}" == "None" ]]; then
    echo "Failed to register NitroTPM AMI from ${source_ami}." >&2
    exit 1
  fi
  aws ec2 create-tags \
    --region "${AWS_REGION}" \
    --resources "${new_ami_id}" \
    --tags "Key=Name,Value=${ami_name}" \
           "Key=OpenPccSourceAmi,Value=${source_ami}" \
           "Key=OpenPccNitroTpm,Value=true" \
           "Key=OpenPccBootMode,Value=uefi" \
           "Key=OpenPccTpmSupport,Value=${TPM_SUPPORT}"

  echo "Waiting for NitroTPM AMI ${new_ami_id} to be available..."
  aws ec2 wait image-available --region "${AWS_REGION}" --image-ids "${new_ami_id}"
  COMPUTE_AMI_ID="${new_ami_id}"
  echo "NitroTPM AMI ready: ${COMPUTE_AMI_ID}"
}

deploy_compute() {
  require_env COMPUTE_SECURITY_GROUP_ID
  if [[ -z "${ROUTER_ADDRESS}" ]]; then
    echo "Missing required environment variable: ROUTER_ADDRESS" >&2
    echo "Provide ROUTER_ADDRESS when deploying compute without router." >&2
    exit 1
  fi
  if [[ -z "${COMPUTE_IMAGE_SIGSTORE_BUNDLE}" && -z "${COMPUTE_IMAGE_SIGSTORE_BUNDLE_REF}" ]]; then
    echo "Missing COMPUTE_IMAGE_SIGSTORE_BUNDLE or COMPUTE_IMAGE_SIGSTORE_BUNDLE_REF." >&2
    exit 1
  fi
  if [[ -z "${COMPUTE_AMI_ID}" ]]; then
    echo "Missing required environment variable: COMPUTE_AMI_ID or AMI_ID" >&2
    exit 1
  fi
  resolve_nitrotpm_ami
  local user_data
  user_data="$(mktemp)"
  user_data_after_reboot="$(mktemp)"
cat >"${user_data_after_reboot}" <<EOF
#!/bin/bash
export HOME="/root"
mkdir -p "${HOME}"
echo "HOME=${HOME}"
ECM="${ENABLE_COMPUTE_MONITOR}"
SB="${COMPUTE_IMAGE_SIGSTORE_BUNDLE}"
BR="${COMPUTE_IMAGE_SIGSTORE_BUNDLE_REF}"
RA="${ROUTER_ADDRESS}"
RC="${ROUTER_COM_PORT:-8081}"
PH="${ROUTER_PROXY_HOST}"
PP="${ROUTER_PROXY_PORT}"
TC="${TPM_SIMULATOR_CMD_PORT}"
TP="${TPM_SIMULATOR_PLATFORM_PORT}"
EC="${ENCLAVE_CID}"
CPU="${ENCLAVE_CPU_COUNT}"
MEM="${ENCLAVE_MEMORY_MIB}"
NR="${NITRO_RUN_ARGS}"
ES="/opt/openpcc/enclave_scripts"
OV="1.3.0"
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

mkdir -p "\${ES}"
cid=\$(docker create "${compute_image_uri}")
docker cp "\${cid}:/enclave_scripts/." "\${ES}"
docker rm "\${cid}"

EF="/opt/openpcc/compute.eif"
mkdir -p "/opt/openpcc"
if [[ -z "\${SB}" && -n "\${BR}" ]]; then
  echo "Fetching sigstore bundle: \${BR}"
  OT="/tmp/oras.tgz"
  curl -fsSL "https://github.com/oras-project/oras/releases/download/v\${OV}/oras_\${OV}_linux_amd64.tar.gz" -o "\${OT}"
  tar -xzf "\${OT}" -C /usr/local/bin oras
  chmod +x /usr/local/bin/oras
  rm -f "\${OT}"
  oras version
  BD="/opt/openpcc/bundle"
  BF="\${BD}/compute.sigstore.bundle"
  mkdir -p "\${BD}"
  (cd "\${BD}" && oras pull "\${BR}")
  if [[ ! -s "\${BF}" ]]; then
    echo "Bundle missing: \${BF}" >&2
    exit 1
  fi
  echo "Bundle bytes: \$(stat -c %s "\${BF}")"
  sha256sum "\${BF}"
  SB="\$(base64 -w 0 "\${BF}")"
fi
if [[ -z "\${SB}" ]]; then
  echo "Missing sigstore bundle; cannot continue." >&2
  exit 1
fi

TOKEN="\$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
if [[ -n "\${TOKEN}" ]]; then
  CH="\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
else
  CH="\$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
fi
if [[ -z "\${CH}" ]]; then
  CH="\$(hostname -I | awk '{print \$1}' || true)"
fi
if [[ -z "\${CH}" ]]; then
  echo "Failed to determine compute host IP." >&2
  exit 1
fi
PU="http://\${PH}:\${PP}"
if [[ "\${TP}" -ne "\$((TC + 1))" ]]; then
  TP="\$((TC + 1))"
fi
RH="\${RA#http://}"
RH="\${RH#https://}"
RH="\${RH%%/*}"
RP="3600"
if [[ "\${RH}" == *:* ]]; then
  RP="\${RH##*:}"
  RH="\${RH%%:*}"
fi
if [[ -z "\${RH}" ]]; then
  echo "Failed to parse router host from \${RA}" >&2
  exit 1
fi
mkdir -p /etc/nitro_enclaves
export RH RP TC TP
envsubst '\${RH} \${RP} \${TC} \${TP}' < "\${ES}/vsock-proxy.yaml.tmpl" > /etc/nitro_enclaves/vsock-proxy.yaml

TD="/opt/openpcc/ms-tpm-20-ref"
TB="\${TD}/TPMCmd/Simulator/src/tpm2-simulator"
if [[ ! -x "\${TB}" ]]; then
  rm -rf "\${TD}"
  git clone --depth 1 https://github.com/microsoft/ms-tpm-20-ref.git "\${TD}"
  (
    cd "\${TD}/TPMCmd"
    ./bootstrap
    ./configure
    make -j"\$(nproc)"
  )
fi

export TB TC TP PP RH RP RC EC CPU MEM NR
envsubst '\${TB} \${TC}' < "\${ES}/systemd/openpcc-tpm-sim.service.tmpl" > /etc/systemd/system/openpcc-tpm-sim.service
envsubst '\${PP} \${RH} \${RP}' < "\${ES}/systemd/openpcc-vsock-router.service.tmpl" > /etc/systemd/system/openpcc-vsock-router.service
envsubst '\${TC}' < "\${ES}/systemd/openpcc-vsock-tpm-cmd.service.tmpl" > /etc/systemd/system/openpcc-vsock-tpm-cmd.service
envsubst '\${TP}' < "\${ES}/systemd/openpcc-vsock-tpm-platform.service.tmpl" > /etc/systemd/system/openpcc-vsock-tpm-platform.service
envsubst '\${RC} \${EC}' < "\${ES}/systemd/openpcc-enclave-health-proxy.service.tmpl" > /etc/systemd/system/openpcc-enclave-health-proxy.service
envsubst '\${CPU} \${MEM} \${EC} \${NR}' < "\${ES}/systemd/openpcc-enclave.service.tmpl" > /etc/systemd/system/openpcc-enclave.service
cp "\${ES}/systemd/openpcc-enclave-prepare.service.tmpl" /etc/systemd/system/openpcc-enclave-prepare.service

systemctl daemon-reload
systemctl enable --now openpcc-tpm-sim.service
systemctl enable --now openpcc-vsock-router.service openpcc-vsock-tpm-cmd.service openpcc-vsock-tpm-platform.service
systemctl enable --now openpcc-enclave-health-proxy.service
systemctl enable openpcc-enclave-prepare.service
systemctl enable openpcc-enclave.service
if [[ "\${ECM}" == "true" ]]; then
  MONITOR_DIR="/opt/openpcc/compute-monitor"
  mkdir -p "\${MONITOR_DIR}"
  cp "\${ES}/monitor/app.py" "\${MONITOR_DIR}/app.py"
  chmod 755 "\${MONITOR_DIR}/app.py"
  cp "\${ES}/monitor/openpcc-compute-monitor.service" /etc/systemd/system/openpcc-compute-monitor.service
  systemctl daemon-reload
  systemctl enable --now openpcc-compute-monitor.service
fi
export NITRO_CLI_ARTIFACTS=/var/lib/nitro_enclaves/artifacts
mkdir -p "\${NITRO_CLI_ARTIFACTS}"

ELS="\${TPM_EVENT_LOG_SOURCE:-/sys/kernel/security/tpm0/binary_bios_measurements}"
EWS="\${TPM_EVENT_LOG_WAIT_SECONDS:-180}"
EWI="\${TPM_EVENT_LOG_WAIT_INTERVAL:-2}"
ENV_FILE="/etc/openpcc/enclave-prepare.env"
mkdir -p /etc/openpcc
cat > "\${ENV_FILE}" <<EOF_ENV
RC=\${RC}
TC=\${TC}
TP=\${TP}
CH=\${CH}
PU=\${PU}
SB=\${SB}
ES=\${ES}
COMPUTE_IMAGE_URI=${compute_image_uri}
TPM_EVENT_LOG_SOURCE=\${ELS}
TPM_EVENT_LOG_WAIT_SECONDS=\${EWS}
TPM_EVENT_LOG_WAIT_INTERVAL=\${EWI}
EOF_ENV
chmod 600 "\${ENV_FILE}"
chmod +x "\${ES}/openpcc-enclave-prepare.sh"

systemctl start openpcc-enclave.service

if command -v aws >/dev/null 2>&1 && command -v tpm2_readpublic >/dev/null 2>&1; then
  export TPM2TOOLS_TCTI="mssim:host=127.0.0.1,port=\${TC}"
  rek_hash=""
  REK_TAG_MAX_RETRIES=120
  REK_TAG_SLEEP_SECONDS=10
  for i in \$(seq 1 "\${REK_TAG_MAX_RETRIES}"); do
    if tpm2_readpublic -c 0x81000002 -o /tmp/rek.pub >/dev/null 2>&1; then
      rek_hash=\$(sha256sum /tmp/rek.pub | awk '{print \$1}')
      break
    fi
    sleep "\${REK_TAG_SLEEP_SECONDS}"
  done
  if [ -n "\${rek_hash}" ]; then
    TOKEN="\$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
    if [ -n "\${TOKEN}" ]; then
      INSTANCE_ID="\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" http://169.254.169.254/latest/meta-data/instance-id || true)"
      REGION="\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region || true)"
    else
      INSTANCE_ID="\$(curl -s http://169.254.169.254/latest/meta-data/instance-id || true)"
      REGION="\$(curl -s http://169.254.169.254/latest/meta-data/placement/region || true)"
    fi
    if [ -z "\${REGION}" ]; then
      if [ -n "\${TOKEN}" ]; then
        AZ="\$(curl -s -H "X-aws-ec2-metadata-token: \${TOKEN}" http://169.254.169.254/latest/meta-data/placement/availability-zone || true)"
      else
        AZ="\$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone || true)"
      fi
      REGION="\${AZ::-1}"
    fi
    if [ -n "\${INSTANCE_ID}" ] && [ -n "\${REGION}" ]; then
      aws ec2 create-tags \
        --region "\${REGION}" \
        --resources "\${INSTANCE_ID}" \
        --tags "Key=openpcc:rek_hash,Value=sha256:\${rek_hash}" || true
    else
      echo "Failed to resolve instance metadata for tagging." >&2
    fi
  else
    echo "Failed to compute REK hash for tagging." >&2
  fi
else
  echo "awscli or tpm2-tools not installed; skipping REK tag update." >&2
fi

mv \$0 /
reboot now
EOF

script_after_reboot_b64=$(gzip -c "${user_data_after_reboot}" | base64 -w 0)

  cat >"${user_data}" <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io python3 curl git build-essential gcc linux-modules-extra-aws socat autoconf autoconf-archive automake pkg-config libssl-dev gzip awscli tpm2-tools gettext-base

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
