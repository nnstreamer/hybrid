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

FROM debian:bookworm-slim AS ollama-assets

ARG OLLAMA_VERSION="v0.15.1"
ARG OLLAMA_DOWNLOAD_URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst"
ARG OLLAMA_MODEL="llama3.2:1b"
ARG OLLAMA_MODELS_DIR="/opt/ollama/models"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    zstd \
  && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
  mkdir -p "${OLLAMA_MODELS_DIR}"; \
  curl -fsSL "${OLLAMA_DOWNLOAD_URL}" -o /tmp/ollama.tar.zst; \
  tar --zstd -xf /tmp/ollama.tar.zst -C /usr/local; \
  rm -f /tmp/ollama.tar.zst; \
  OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" /usr/local/bin/ollama serve >/tmp/ollama.log 2>&1 & \
  ollama_pid=$!; \
  for i in $(seq 1 60); do \
    if curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then \
      break; \
    fi; \
    sleep 1; \
  done; \
  OLLAMA_HOST="127.0.0.1:11434" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" /usr/local/bin/ollama pull "${OLLAMA_MODEL}"; \
  kill "${ollama_pid}"; \
  wait "${ollama_pid}" || true

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
    curl \
    iproute2 \
    socat \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/confidentcompute/bin /etc/openpcc

ARG OLLAMA_VERSION="v0.15.1"
ARG OLLAMA_MODEL="llama3.2:1b"
ENV OLLAMA_VERSION="${OLLAMA_VERSION}"
ENV OLLAMA_MODEL="${OLLAMA_MODEL}"
ENV OLLAMA_MODELS="/opt/ollama/models"
ENV INFERENCE_ENGINE_MODEL_1="${OLLAMA_MODEL}"
ENV MODEL_1="${OLLAMA_MODEL}"

COPY --from=ollama-assets /usr/local/bin/ollama /usr/local/bin/ollama
COPY --from=ollama-assets /usr/local/lib/ollama /usr/local/lib/ollama
COPY --from=ollama-assets /opt/ollama /opt/ollama

COPY --from=build /out/compute_boot /opt/confidentcompute/bin/compute_boot
COPY --from=build /out/router_com /opt/confidentcompute/bin/router_com
COPY --from=build /out/compute_worker /opt/confidentcompute/bin/compute_worker
COPY config/compute_boot.yaml /etc/openpcc/compute_boot.yaml
COPY config/router_com.yaml /etc/openpcc/router_com.yaml
COPY entrypoint.sh /opt/confidentcompute/bin/entrypoint.sh

RUN chmod +x /opt/confidentcompute/bin/entrypoint.sh

EXPOSE 8081

ENTRYPOINT ["/opt/confidentcompute/bin/entrypoint.sh"]
