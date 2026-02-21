# Real Attestation CLI (Ubuntu)

This CLI sends a single OpenPCC request using **real attestation verification**.

## Prerequisites
- Ubuntu with Go installed
- Router (server-1) reachable on port 3600
- Compute node running with real attestation enabled
- An **OIDC identity policy** for verifying transparency bundles

## Configure router address
The router (server-1) address can be set in **either** environment variables
or `/etc/nnstreamer/hybrid.ini`.

If both are set, **environment variables take precedence**. If neither is set,
the CLI assumes `http://localhost:3600`.

### Option A) Environment variables (highest priority)
```bash
export ROUTER_URL="http://<router-ip>:3600"
# or
export OPENPCC_ROUTER_URL="http://<router-ip>:3600"
```

### Option B) /etc/nnstreamer/hybrid.ini
```ini
router_url=http://<router-ip>:3600
```

Supported keys: `router_url`, `server1_url`, `server_1_url`.

## oHTTP mode (required flag)
This CLI requires the `-ohttp` flag:

- `-ohttp=disable` (router direct)
- `-ohttp=enable` (relay + gateway)

When `-ohttp=enable`, you must also set:
- `SERVER3_URL` (or `OPENPCC_SERVER3_URL`)

The relay URL can be set directly **or** fetched from server-3 `/api/config`.
The oHTTP **public key bundle** is always fetched from server-3, so `OHTTP_SEEDS_JSON`
is **not required** for this CLI.
`ROUTER_URL` is not required in this mode.

### Option A) Relay URL 직접 지정
```bash
export RELAY_URL="http://<server4-public-ip>:3100"
# or
export OPENPCC_RELAY_URL="http://<server4-public-ip>:3100"
```

### Option B) server-3에서 relay URL 자동 추출
```bash
export SERVER3_URL="http://<server3-public-ip>:8080"
# or
export OPENPCC_SERVER3_URL="http://<server3-public-ip>:8080"
```

또는 `/etc/nnstreamer/hybrid.ini`:
```ini
server3_url=http://<server3-public-ip>:8080
# (auth_url도 허용)
```

이 경우 실행 시 **server-3에서 relay_urls를 가져오는 로그가 출력**됩니다.

### OHTTP 공개키 번들 (server-3에서 자동 획득)
```bash
export SERVER3_URL="http://<server3-public-ip>:8080"
```

## Verification warning (기본 동작)
real-attestation 검증이 실패하면 **5줄 경고를 출력한 뒤 계속 진행**합니다.
이는 개발자 시험/성능 비교 목적의 기본 동작입니다.

## Configure identity policy (required for real attestation)
Real attestation requires an OIDC identity policy. Provide it via env vars
or `/etc/nnstreamer/hybrid.ini`.

### Environment variables (preferred)
```bash
export OPENPCC_OIDC_ISSUER="https://oidc.example.com"
export OPENPCC_OIDC_SUBJECT="user@example.com"

# Optional regex alternatives:
export OPENPCC_OIDC_ISSUER_REGEX="https://oidc\\.example\\.com"
export OPENPCC_OIDC_SUBJECT_REGEX=".*@example\\.com"
```

### /etc/nnstreamer/hybrid.ini
```ini
oidc_issuer=https://oidc.example.com
oidc_subject=user@example.com
# optional:
oidc_issuer_regex=https://oidc\.example\.com
oidc_subject_regex=.*@example\.com
```

At least one of `oidc_issuer`/`oidc_issuer_regex` **and** one of
`oidc_subject`/`oidc_subject_regex` must be set.

## Optional settings
```bash
export MODEL_NAME="llama3.2:1b"
export PROMPT_TEXT="Hello from Ubuntu"

# Sigstore environment (prod or staging)
export TRANSPARENCY_ENV="prod"

# Trusted root cache path (optional)
export SIGSTORE_CACHE_PATH="$HOME/.confsec/.sigstore-cache"
```

## Build and run
From this directory:
```bash
go build -o real-attestation-client .
./real-attestation-client
```

Or run directly:
```bash
go run . -ohttp=disable
```

Example (oHTTP enabled):
```bash
export RELAY_URL="http://<relay-ip>:3100"
export SERVER3_URL="http://<server3-public-ip>:8080"
go run . -ohttp=enable
```
