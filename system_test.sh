#!/usr/bin/env bash
# Objective:
# - Run an end-to-end local system test for OpenPCC using Ollama + smollm:135m.
# - Build images, start services, send a client request, and print the model response.
#
# Usage:
# - bash ./system_test.sh
# - MODEL_NAME=smollm:135m PROMPT_TEXT="Hello" bash ./system_test.sh
# - IMAGE_TAG=local TPM_CMD_PORT=2321 TPM_PLATFORM_PORT=2322 bash ./system_test.sh
#   (TPM_PLATFORM_PORT defaults to TPM_CMD_PORT+1 for mssim)
# - COMPUTE_BOOT_BUILD_TAGS=include_fake_attestation bash ./system_test.sh
#   (Set COMPUTE_BOOT_BUILD_TAGS="" to require real TEE attestation)
# - PROMPT_TEXTS=$'First prompt\nSecond prompt\nThird prompt' bash ./system_test.sh
#
# Environment:
# - Ubuntu host with sudo privileges (script installs missing packages).
# - Docker daemon must be available; the script uses Docker for isolation.
# - Internet access required (pulls Docker images and the model).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODEL_NAME="${MODEL_NAME:-smollm:135m}"
PROMPT_TEXT="${PROMPT_TEXT:-Explain what a cache is in one sentence.}"
PROMPT_TEXTS="${PROMPT_TEXTS:-}"
IMAGE_TAG="${IMAGE_TAG:-local}"
COMPUTE_BOOT_BUILD_TAGS="${COMPUTE_BOOT_BUILD_TAGS-include_fake_attestation}"

TPM_CMD_PORT="${TPM_CMD_PORT:-2321}"
TPM_PLATFORM_PORT="${TPM_PLATFORM_PORT:-$((TPM_CMD_PORT + 1))}"

TMP_DIR=""
OPENPCC_DIR=""

if [[ "${ELEVATED_RUN:-}" != "true" && "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E env ELEVATED_RUN=true bash "$0" "$@"
  else
    echo "[system-test][ERROR] sudo is required to run this script." >&2
    exit 1
  fi
fi

say() {
  printf "\n[system-test] %s\n" "$*"
}

die() {
  printf "\n[system-test][ERROR] %s\n" "$*" >&2
  exit 1
}

normalize_tpm_ports() {
  local expected_platform_port
  expected_platform_port="$((TPM_CMD_PORT + 1))"
  if [[ "${TPM_PLATFORM_PORT}" -ne "${expected_platform_port}" ]]; then
    say "TPM_PLATFORM_PORT (${TPM_PLATFORM_PORT}) does not match TPM_CMD_PORT+1 (${expected_platform_port}); using ${expected_platform_port}."
    TPM_PLATFORM_PORT="${expected_platform_port}"
  fi
}

diagnose_router_compute() {
  set +e
  say "Diagnostics: router/compute connectivity"

  say "Router /_health response:"
  curl -fsS "http://localhost:3600/_health"
  printf "\n"

  say "Compute /_health response:"
  curl -fsS "http://localhost:8081/_health"
  printf "\n"

  say "Router /compute-manifests response:"
  curl -fsS "http://localhost:3600/compute-manifests"
  printf "\n"

  say "Container status (router/compute):"
  ${DOCKER} ps --filter "name=openpcc-router" --filter "name=openpcc-compute"

  say "Router logs (last 200 lines):"
  ${DOCKER} logs --tail 200 openpcc-router

  say "Compute logs (last 200 lines):"
  ${DOCKER} logs --tail 200 openpcc-compute

  say "Possible reasons to investigate:"
  printf "[system-test] - Compute failed to register with router (registration error or crash).\n"
  printf "[system-test] - Router is unreachable from compute (ROUTER_ADDRESS, network, or DNS issue).\n"
  printf "[system-test] - Compute started but did not finish bootstrapping before client request.\n"
  printf "[system-test] - Router is healthy but compute discovery is misconfigured.\n"
  set -e
}

cleanup() {
  set +e
  if command -v docker >/dev/null 2>&1; then
    docker rm -f openpcc-ollama openpcc-router openpcc-compute openpcc-tpm-sim >/dev/null 2>&1 || true
  fi
  if [[ -n "${OPENPCC_DIR}" && -d "${OPENPCC_DIR}" ]]; then
    rm -rf "${OPENPCC_DIR}"
  fi
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

if [[ ! -f "${ROOT_DIR}/scripts/build_pack.sh" ]]; then
  die "scripts/build_pack.sh not found. Run this script from the repo root."
fi

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "sudo is required to install packages."
  fi
fi

normalize_tpm_ports

ensure_pkg() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    say "Installing ${pkg}..."
    ${SUDO} apt-get update -y >/dev/null
    ${SUDO} apt-get install -y "${pkg}" >/dev/null
  fi
}

ensure_pkg git git
ensure_pkg curl curl

if ! command -v docker >/dev/null 2>&1; then
  say "Installing docker..."
  ${SUDO} apt-get update -y >/dev/null
  ${SUDO} apt-get install -y docker.io >/dev/null
fi

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if ${SUDO} docker info >/dev/null 2>&1; then
    DOCKER="${SUDO} docker"
  else
    say "Starting docker daemon..."
    ${SUDO} systemctl start docker >/dev/null 2>&1 || true
    ${SUDO} service docker start >/dev/null 2>&1 || true
    if ! ${SUDO} docker info >/dev/null 2>&1; then
      die "Docker daemon is not running. Start docker and retry."
    fi
    DOCKER="${SUDO} docker"
  fi
fi

say "Building project images..."
COMPONENT=all IMAGE_TAG="${IMAGE_TAG}" PUSH=false ${SUDO} bash "${ROOT_DIR}/scripts/build_pack.sh"

if [[ -n "${COMPUTE_BOOT_BUILD_TAGS}" ]]; then
  say "Rebuilding compute image with compute_boot tags (${COMPUTE_BOOT_BUILD_TAGS})..."
  ${DOCKER} build \
    --build-arg "COMPUTE_BOOT_BUILD_TAGS=${COMPUTE_BOOT_BUILD_TAGS}" \
    -t "openpcc-compute:${IMAGE_TAG}" \
    -f "${ROOT_DIR}/server-2/Dockerfile" \
    "${ROOT_DIR}/server-2"
fi

TMP_DIR="$(mktemp -d)"

say "Building TPM simulator image (mssim)..."
cat > "${TMP_DIR}/Dockerfile.tpm" <<'EOF'
FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  git autoconf-archive pkg-config build-essential automake gcc libssl-dev \
  && rm -rf /var/lib/apt/lists/*
RUN git config --global http.sslVerify false
WORKDIR /src
RUN git clone --depth 1 https://github.com/microsoft/ms-tpm-20-ref.git /src
WORKDIR /src/TPMCmd
RUN ./bootstrap && ./configure && make -j"$(nproc)"
WORKDIR /tpm
EXPOSE 2321 2322
ENTRYPOINT ["/src/TPMCmd/Simulator/src/tpm2-simulator"]
EOF
${DOCKER} build -t openpcc-tpm-sim:local -f "${TMP_DIR}/Dockerfile.tpm" "${TMP_DIR}" >/dev/null

say "Starting TPM simulator..."
${DOCKER} rm -f openpcc-tpm-sim >/dev/null 2>&1 || true
${DOCKER} run -d --name openpcc-tpm-sim --network host openpcc-tpm-sim:local "${TPM_CMD_PORT}" >/dev/null

say "Starting Ollama and pulling model (${MODEL_NAME})..."
${DOCKER} rm -f openpcc-ollama >/dev/null 2>&1 || true
${DOCKER} run -d --name openpcc-ollama --network host -e OLLAMA_HOST=0.0.0.0 ollama/ollama >/dev/null

say "Waiting for Ollama to be ready..."
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:11434/api/tags" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

say "Pulling model (${MODEL_NAME})..."
${DOCKER} exec openpcc-ollama ollama pull "${MODEL_NAME}" >/dev/null

say "Starting router (server-1)..."
${DOCKER} rm -f openpcc-router >/dev/null 2>&1 || true
${DOCKER} run -d --name openpcc-router --network host openpcc-router:${IMAGE_TAG} >/dev/null

say "Starting compute (server-2)..."
${DOCKER} rm -f openpcc-compute >/dev/null 2>&1 || true
${DOCKER} run -d --name openpcc-compute --network host \
  -e ROUTER_ADDRESS="http://localhost:3600" \
  -e COMPUTE_HOST="localhost" \
  -e LLM_BASE_URL="http://localhost:11434" \
  -e MODEL_1="${MODEL_NAME}" \
  -e INFERENCE_ENGINE_MODEL_1="${MODEL_NAME}" \
  -e INFERENCE_ENGINE_TYPE="ollama" \
  -e INFERENCE_ENGINE_SKIP="false" \
  -e TPM_TYPE="Simulator" \
  -e SIMULATE_TPM="true" \
  -e SIMULATOR_CMD_ADDRESS="127.0.0.1:${TPM_CMD_PORT}" \
  -e SIMULATOR_PLATFORM_ADDRESS="127.0.0.1:${TPM_PLATFORM_PORT}" \
  openpcc-compute:${IMAGE_TAG} >/dev/null

say "Waiting for router and compute health..."
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:3600/_health" >/dev/null 2>&1 && \
     curl -fsS "http://localhost:8081/_health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

say "Preparing local OpenPCC client..."
OPENPCC_DIR="$(mktemp -d)"
git clone --depth 1 https://github.com/openpcc/openpcc.git "${OPENPCC_DIR}" >/dev/null

mkdir -p "${OPENPCC_DIR}/cmd/local-system-test"
cat > "${OPENPCC_DIR}/cmd/local-system-test/main.go" <<'EOF'
package main

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"github.com/openpcc/openpcc"
	"github.com/openpcc/openpcc/ahttp"
	"github.com/openpcc/openpcc/anonpay"
	"github.com/openpcc/openpcc/anonpay/currency"
	"github.com/openpcc/openpcc/anonpay/wallet"
	"github.com/openpcc/openpcc/auth/credentialing"
	authclient "github.com/openpcc/openpcc/auth/client"
	"github.com/openpcc/openpcc/internal/test/anonpaytest"
	"github.com/openpcc/openpcc/inttest"
)

type fakeAuthClient struct {
	badge credentialing.Badge
}

func (f fakeAuthClient) RemoteConfig() authclient.RemoteConfig {
	return authclient.RemoteConfig{}
}

func (f fakeAuthClient) GetAttestationToken(ctx context.Context) (*anonpay.BlindedCredit, error) {
	return anonpaytest.MustBlindCredit(ctx, ahttp.AttestationCurrencyValue), nil
}

func (f fakeAuthClient) GetCredit(ctx context.Context, amountNeeded int64) (*anonpay.BlindedCredit, error) {
	val, err := currency.Rounded(float64(amountNeeded), 1.0)
	if err != nil {
		return nil, err
	}
	return anonpaytest.MustBlindCredit(ctx, val), nil
}

func (f fakeAuthClient) PutCredit(ctx context.Context, finalCredit *anonpay.BlindedCredit) error {
	return nil
}

func (f fakeAuthClient) GetBadge(ctx context.Context) (credentialing.Badge, error) {
	return f.badge, nil
}

func (f fakeAuthClient) Payee() *anonpay.Payee {
	return anonpaytest.MustNewPayee()
}

type fixedPayment struct {
	credit *anonpay.BlindedCredit
}

func (p *fixedPayment) Success(_ *anonpay.UnblindedCredit) error { return nil }
func (p *fixedPayment) Credit() *anonpay.BlindedCredit          { return p.credit }
func (p *fixedPayment) Cancel() error                           { return nil }

type fixedWallet struct{}

func (w *fixedWallet) BeginPayment(ctx context.Context, amount int64) (wallet.Payment, error) {
	val, err := currency.Rounded(float64(amount), 1.0)
	if err != nil {
		return nil, err
	}
	return &fixedPayment{credit: anonpaytest.MustBlindCredit(ctx, val)}, nil
}
func (w *fixedWallet) Status() wallet.Status                     { return wallet.Status{} }
func (w *fixedWallet) SetDefaultCreditAmount(_ int64) error       { return nil }
func (w *fixedWallet) Close(_ context.Context) error              { return nil }

func makeBadge(model string) (credentialing.Badge, error) {
	badgeKey, err := inttest.NewTestBadgeKeyProvider().PrivateKey()
	if err != nil {
		return credentialing.Badge{}, err
	}
	creds := credentialing.Credentials{Models: []string{model}}
	credBytes, err := creds.MarshalBinary()
	if err != nil {
		return credentialing.Badge{}, err
	}
	sig := ed25519.Sign(badgeKey, credBytes)
	return credentialing.Badge{Credentials: creds, Signature: sig}, nil
}

type promptPair struct {
	input  string
	output string
}

func splitPrompts(raw string) []string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil
	}
	var parts []string
	if strings.Contains(trimmed, "\n") {
		parts = strings.Split(trimmed, "\n")
	} else if strings.Contains(trimmed, "||") {
		parts = strings.Split(trimmed, "||")
	} else {
		parts = []string{trimmed}
	}
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		item := strings.TrimSpace(part)
		if item != "" {
			out = append(out, item)
		}
	}
	return out
}

func ensureUniquePrompts(prompts []string) []string {
	seen := make(map[string]int)
	unique := make([]string, 0, len(prompts))
	for _, prompt := range prompts {
		if count, ok := seen[prompt]; ok {
			count++
			seen[prompt] = count
			prompt = fmt.Sprintf("%s (variant %d)", prompt, count)
		} else {
			seen[prompt] = 1
		}
		unique = append(unique, prompt)
	}
	return unique
}

func getPrompts() []string {
	raw := os.Getenv("PROMPT_TEXTS")
	prompts := splitPrompts(raw)
	basePrompt := os.Getenv("PROMPT_TEXT")
	if basePrompt == "" {
		basePrompt = "Explain what a cache is in one sentence."
	}
	defaults := []string{
		basePrompt,
		"Give two key differences between RAM and disk storage.",
		"In one sentence, define a CPU cache hit.",
	}
	if len(prompts) == 0 {
		prompts = defaults
	}
	for len(prompts) < 3 {
		prompts = append(prompts, defaults[len(prompts)%len(defaults)])
	}
	if len(prompts) > 3 {
		prompts = prompts[:3]
	}
	return ensureUniquePrompts(prompts)
}

func main() {
	routerURL := os.Getenv("ROUTER_URL")
	if routerURL == "" {
		routerURL = "http://localhost:3600"
	}
	model := os.Getenv("MODEL_NAME")
	if model == "" {
		model = "smollm:135m"
	}
	prompts := getPrompts()

	badge, err := makeBadge(model)
	if err != nil {
		panic(err)
	}

	cfg := openpcc.DefaultConfig()
	cfg.APIURL = "http://localhost:0000"
	cfg.APIKey = "local-test"
	cfg.PingRouter = false
	policy := inttest.LocalDevIdentityPolicy()
	cfg.TransparencyIdentityPolicy = &policy
	cfg.TransparencyIdentityPolicySource = openpcc.IdentityPolicySourceConfigured

	client, err := openpcc.NewFromConfig(
		context.Background(),
		cfg,
		openpcc.WithAuthClient(fakeAuthClient{badge: badge}),
		openpcc.WithWallet(&fixedWallet{}),
		openpcc.WithRouterURL(routerURL),
		openpcc.WithAnonHTTPClient(&http.Client{}),
		openpcc.WithFakeAttestationSecret("123456"),
	)
	if err != nil {
		panic(err)
	}
	defer client.Close(context.Background())

	pairs := make([]promptPair, 0, len(prompts))
	for _, prompt := range prompts {
		body := fmt.Sprintf(`{"model":"%s","prompt":"%s","stream":false}`, model, prompt)
		req, err := http.NewRequest("POST", "http://confsec.invalid/api/generate", strings.NewReader(body))
		if err != nil {
			panic(err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Confsec-Node-Tags", "model="+model)

		resp, err := client.RoundTrip(req)
		if err != nil {
			panic(err)
		}
		out, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			panic(err)
		}
		pairs = append(pairs, promptPair{input: prompt, output: string(out)})
	}

	fmt.Println("LLM_RESULTS_START")
	for i, pair := range pairs {
		fmt.Printf("PAIR %d\nINPUT: %s\nOUTPUT: %s\n", i+1, pair.input, pair.output)
		fmt.Println("----")
	}
	fmt.Println("LLM_RESULTS_END")
}
EOF

say "Running client request..."
set +e
${DOCKER} run --rm --network host \
  -e ROUTER_URL="http://localhost:3600" \
  -e MODEL_NAME="${MODEL_NAME}" \
  -e PROMPT_TEXT="${PROMPT_TEXT}" \
  -e PROMPT_TEXTS="${PROMPT_TEXTS}" \
  -v "${OPENPCC_DIR}:/src" \
  -w /src \
  golang:1.25.4-bookworm \
  go run -tags=include_fake_attestation ./cmd/local-system-test >/tmp/system_test_output.log
client_status=$?
set -e
if [[ "${client_status}" -ne 0 ]]; then
  say "Client request failed with exit code ${client_status}."
  diagnose_router_compute
  die "Client request failed. See diagnostics above."
fi

say "Response received. Output:"
cat /tmp/system_test_output.log

if ! grep -q "LLM_RESULTS_START" /tmp/system_test_output.log; then
  say "Client did not produce LLM result summary."
  diagnose_router_compute
  die "Client did not produce LLM result summary."
fi

pair_count="$(grep -c "^PAIR " /tmp/system_test_output.log || true)"
if [[ "${pair_count}" -ne 3 ]]; then
  say "Client did not return three LLM response pairs (found ${pair_count})."
  diagnose_router_compute
  die "Client did not return three LLM response pairs."
fi

say "SUCCESS: end-to-end LLM request completed."
