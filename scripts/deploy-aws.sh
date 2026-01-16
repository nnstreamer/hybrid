#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${root_dir}/dist"
manifest_path="${dist_dir}/manifest.json"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env: ${name}" >&2
    exit 1
  fi
}

require_env AWS_REGION
require_env AWS_ACCOUNT_ID
require_env ECR_REPOSITORY_SERVER1
require_env ECR_REPOSITORY_SERVER2

image_tag="${IMAGE_TAG:-}"
if [[ -z "${image_tag}" ]]; then
  if [[ ! -f "${manifest_path}" ]]; then
    echo "Missing IMAGE_TAG and ${manifest_path}" >&2
    exit 1
  fi
  image_tag="$(
    python - <<'PY'
import json
with open("dist/manifest.json", "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("image_tag", ""))
PY
  )"
fi

if [[ -z "${image_tag}" ]]; then
  echo "IMAGE_TAG is empty" >&2
  exit 1
fi

registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_SERVER1}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPOSITORY_SERVER1}" >/dev/null
aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_SERVER2}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${ECR_REPOSITORY_SERVER2}" >/dev/null

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${registry}"

docker load -i "${dist_dir}/server-1.tar"
docker load -i "${dist_dir}/server-2.tar"

docker tag "openpcc-server-1:${image_tag}" "${registry}/${ECR_REPOSITORY_SERVER1}:${image_tag}"
docker tag "openpcc-server-2:${image_tag}" "${registry}/${ECR_REPOSITORY_SERVER2}:${image_tag}"

docker push "${registry}/${ECR_REPOSITORY_SERVER1}:${image_tag}"
docker push "${registry}/${ECR_REPOSITORY_SERVER2}:${image_tag}"
