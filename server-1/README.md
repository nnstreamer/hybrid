# server-1

Based on TAOS-D, this runs OpenPCC server, relaying clients' requests to server-2 securely.

## Container Image
`Dockerfile` builds a prototype image that runs OpenPCC in-memory services:
- `mem-auth` (3000)
- `ohttp-relay` (3100)
- `mem-gateway` (3200)
- `mem-bank` (3500)
- `mem-credithole` (3501)
- `mem-router` (3600)

Build example:
`docker build -t openpcc-server-1:proto -f server-1/Dockerfile .`
