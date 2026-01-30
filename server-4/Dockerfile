# Objective: Build the OpenPCC oHTTP relay image from upstream source.
# Usage examples:
# - docker build -t openpcc-relay -f server-4/Dockerfile server-4
# - docker build --build-arg OPENPCC_REF=main -t openpcc-relay server-4
# Notes:
# - Produces a container with the ohttp-relay binary.
ARG GO_VERSION=1.25.4

FROM golang:${GO_VERSION}-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

ARG OPENPCC_REF=main
RUN git clone --branch "${OPENPCC_REF}" --depth 1 https://github.com/openpcc/openpcc.git .

RUN go mod download

RUN go build -o /out/ohttp-relay ./cmd/ohttp-relay

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
    socat \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ohttp-relay /usr/local/bin/ohttp-relay
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3100

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
