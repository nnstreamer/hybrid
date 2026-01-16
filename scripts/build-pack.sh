#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${IMAGE_TAG:-${GITHUB_SHA:-local}}"
openpcc_version="${OPENPCC_VERSION:-v0.0.80}"

output_dir="${root_dir}/dist"
mkdir -p "${output_dir}"

docker build --pull \
  -t "openpcc-server-1:${image_tag}" \
  --build-arg OPENPCC_VERSION="${openpcc_version}" \
  -f "${root_dir}/server-1/Dockerfile" "${root_dir}"

docker build --pull \
  -t "openpcc-server-2:${image_tag}" \
  --build-arg OPENPCC_VERSION="${openpcc_version}" \
  -f "${root_dir}/server-2/Dockerfile" "${root_dir}"

docker save "openpcc-server-1:${image_tag}" -o "${output_dir}/server-1.tar"
docker save "openpcc-server-2:${image_tag}" -o "${output_dir}/server-2.tar"

cat > "${output_dir}/manifest.json" <<EOF
{
  "image_tag": "${image_tag}",
  "openpcc_version": "${openpcc_version}",
  "images": {
    "server_1": "openpcc-server-1:${image_tag}",
    "server_2": "openpcc-server-2:${image_tag}"
  }
}
EOF
