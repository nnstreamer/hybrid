# Objective: Build the OpenPCC router image from upstream source.
# Usage examples:
# - docker build -t openpcc-router -f server-1/Dockerfile server-1
# - docker build --build-arg OPENPCC_REF=main -t openpcc-router server-1
# Notes:
# - Produces a container with mem-router and mem-credithole binaries.
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

RUN go build -o /out/mem-router ./cmd/mem-router
RUN go build -o /out/mem-credithole ./cmd/mem-credithole

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/mem-router /usr/local/bin/mem-router
COPY --from=build /out/mem-credithole /usr/local/bin/mem-credithole
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3501 3600

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
