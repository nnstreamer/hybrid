# Check Status CLI (Ubuntu)

This CLI checks the router health and reports the number of available compute
nodes by calling `/compute-manifests`.
It uses the local/dev anonpay test key to mint an attestation credit, so it
is intended for development environments.

## Prerequisites
- Ubuntu with Go installed
- Router (server-1) reachable on port 3600
- Router configured for local/dev credits (default mem-credithole)

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

## Optional settings
```bash
# Filter compute nodes by tags (comma or space separated)
export NODE_TAGS="model=llama3.2:1b,engine=ollama"

# Limit max nodes returned (1-500)
export MAX_NODES=100

# Show node IDs and tags in output
export SHOW_NODES=true

# Request timeout in seconds
export REQUEST_TIMEOUT_SECONDS=15
```

## Build and run
From this directory:
```bash
go build -o check-statue-client .
./check-statue-client
```

Or run directly:
```bash
go run .
```
