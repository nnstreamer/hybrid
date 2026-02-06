# Fake Attestation CLI (Ubuntu)

This CLI sends a single OpenPCC request using fake attestation.

## Prerequisites
- Ubuntu with Go installed
- Router (server-1) reachable on port 3600
- Compute node built with fake attestation (default secret: `123456`)

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

## Optional settings
```bash
export MODEL_NAME="llama3.2:1b"
export PROMPT_TEXT="Hello from Ubuntu"
export FAKE_ATTESTATION_SECRET="123456"
```

## Build and run
From this directory:
```bash
go build -tags=include_fake_attestation -o fake-attestation-client .
./fake-attestation-client
```

Or run directly:
```bash
go run -tags=include_fake_attestation . -ohttp=disable
```

Example (oHTTP enabled):
```bash
export RELAY_URL="http://<relay-ip>:3100"
export OHTTP_SEEDS_JSON='[{"key_id":"01","seed_hex":"...","active_from":"2026-01-30T00:00:00Z","active_until":"2026-07-30T00:00:00Z"}]'
go run -tags=include_fake_attestation . -ohttp=enable
```
