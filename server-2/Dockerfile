# Objective: Build the OpenPCC compute node image from upstream source.
# Usage examples:
# - docker build -t openpcc-compute -f server-2/Dockerfile server-2
# - docker build --build-arg CONFIDENTCOMPUTE_REF=main -t openpcc-compute server-2
# Notes:
# - Produces a container with compute_boot, router_com, and compute_worker.
ARG GO_VERSION=1.25.4

FROM golang:${GO_VERSION}-bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    libssl-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

ARG CONFIDENTCOMPUTE_REF=main
ARG COMPUTE_BOOT_BUILD_TAGS=
RUN git clone --branch "${CONFIDENTCOMPUTE_REF}" --depth 1 https://github.com/confidentsecurity/confidentcompute.git .

RUN go mod download

RUN if [ -n "${COMPUTE_BOOT_BUILD_TAGS}" ]; then \
      go build -tags="${COMPUTE_BOOT_BUILD_TAGS}" -o /out/compute_boot ./cmd/compute_boot; \
    else \
      go build -o /out/compute_boot ./cmd/compute_boot; \
    fi
RUN go build -o /out/router_com ./cmd/router_com
RUN go build -o /out/compute_worker ./cmd/compute_worker

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
    socat \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/confidentcompute/bin /etc/openpcc

COPY --from=build /out/compute_boot /opt/confidentcompute/bin/compute_boot
COPY --from=build /out/router_com /opt/confidentcompute/bin/router_com
COPY --from=build /out/compute_worker /opt/confidentcompute/bin/compute_worker
COPY config/compute_boot.yaml /etc/openpcc/compute_boot.yaml
COPY config/router_com.yaml /etc/openpcc/router_com.yaml
COPY entrypoint.sh /opt/confidentcompute/bin/entrypoint.sh

RUN chmod +x /opt/confidentcompute/bin/entrypoint.sh

EXPOSE 8081

ENTRYPOINT ["/opt/confidentcompute/bin/entrypoint.sh"]
