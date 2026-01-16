#!/usr/bin/env bash
set -euo pipefail

OPENPCC_VERSION="${OPENPCC_VERSION:-v0.0.80}"

go run "github.com/openpcc/openpcc/cmd/test-client@${OPENPCC_VERSION}"
