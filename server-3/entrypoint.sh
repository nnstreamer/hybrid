#!/usr/bin/env bash
# Objective: Start server-3 (auth) config service.
# Usage examples:
# - ./entrypoint.sh
# - SERVER3_CONFIG_PATH=/etc/openpcc/server-3.json ./entrypoint.sh
set -euo pipefail

exec python -m server3
