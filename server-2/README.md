# server-2

This is a server based on TAOS-D, running ConfidentCompute and serving LLMs.

## Container Image
`Dockerfile` builds a prototype image that runs OpenPCC `mem-compute`.

Build example:
`docker build -t openpcc-server-2:proto -f server-2/Dockerfile .`

Optional router forwarding for multi-host prototype:
`docker run -e ROUTER_FORWARD_HOST=server-1-host openpcc-server-2:proto`
