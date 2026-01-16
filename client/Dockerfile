# Objective: Package the OpenPCC client smoke test script.
# Usage examples:
# - docker build -t openpcc-client -f client/Dockerfile client
# - docker run --rm -e ROUTER_URL=http://router:3600 openpcc-client
# Notes:
# - Intended for Ubuntu-compatible environments with curl.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

COPY smoke_test.sh /usr/local/bin/smoke_test.sh

RUN chmod +x /usr/local/bin/smoke_test.sh

ENTRYPOINT ["/usr/local/bin/smoke_test.sh"]
