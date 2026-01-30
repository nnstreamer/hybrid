# server-3 (auth)

server-3 provides the v0.002 control-plane endpoint for remote config and
attestation policy distribution.

## Endpoints

- `GET /api/config`: returns v0.002 config payload
- `GET /healthz`: basic health check

## Configuration

Server-3 reads its config from either:

- `SERVER3_CONFIG_JSON` (raw JSON string, highest priority)
- `SERVER3_CONFIG_PATH` (defaults to `/etc/openpcc/server-3.json`)

Required fields when `features.ohttp` is `true`:

- `relay_urls` (list of strings)
- `gateway_url` (string)
- `router_url` (string)
- `ohttp_seeds` (list of objects with `key_id`, `seed_hex`, `active_from`,
  `active_until`)

Required fields when `features.real_attestation` is `true`:

- `attestation.policy_id` (string)

Optional fields:

- `attestation.allowed` (object)
- `attestation.verifier_hints` (object)

See `config/server-3.sample.json` for a concrete example.

### oHTTP key bundle format (v0.002)

`ohttp_key_configs_bundle` is a base64-encoded JSON object:

```
{
  "format": "openpcc.ohttp.keybundle.v0.002",
  "keys": [
    {
      "key_id": "01",
      "public_key_b64": "...",
      "public_key_format": "sha256-seed"
    }
  ]
}
```

`public_key_b64` is derived deterministically from `seed_hex` and `key_id` by
`SHA256(seed || key_id)`. Rotation periods are emitted separately in
`ohttp_key_rotation_periods`.

## Build and run

```
docker build -t openpcc-auth -f server-3/Dockerfile server-3
docker run --rm -p 8080:8080 \
  -v "$(pwd)/server-3/config/server-3.sample.json:/etc/openpcc/server-3.json:ro" \
  openpcc-auth
```

## Environment variables

- `SERVER3_CONFIG_PATH`: config file path (default: `/etc/openpcc/server-3.json`)
- `SERVER3_CONFIG_JSON`: inline config JSON (overrides file path)
- `SERVER3_BIND_ADDR`: bind address (default: `0.0.0.0`)
- `SERVER3_PORT`: listen port (default: `8080`)
- `SERVER3_LOG_LEVEL`: log level (default: `INFO`)
