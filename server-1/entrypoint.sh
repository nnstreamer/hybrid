#!/usr/bin/env bash
set -euo pipefail

pids=()

start_service() {
  "$@" &
  pids+=("$!")
}

start_service /usr/local/bin/mem-auth
start_service /usr/local/bin/mem-bank
start_service /usr/local/bin/mem-credithole
start_service /usr/local/bin/mem-router
start_service /usr/local/bin/mem-gateway
start_service /usr/local/bin/ohttp-relay

terminate() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait || true
}

trap terminate TERM INT

wait -n
exit_code=$?
terminate
exit "$exit_code"
