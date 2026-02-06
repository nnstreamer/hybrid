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
- `RELAY_URL` (or `OPENPCC_RELAY_URL`)
- `OHTTP_SEEDS_JSON` (or `OPENPCC_OHTTP_SEEDS_JSON`)

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
export OHTTP_SEEDS_JSON='[{"key_id":"01","seed_hex":"...","active_from":"2026-01-30T00:00:00Z","active_until":"2026-07-30T00:00:00Z"}]'
go run . -ohttp=enable
```
