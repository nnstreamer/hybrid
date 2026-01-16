FROM golang:1.25 AS builder

ARG OPENPCC_VERSION=v0.0.80

ENV CGO_ENABLED=0
ENV GOFLAGS="-tags=include_fake_attestation"

RUN go install github.com/openpcc/openpcc/cmd/mem-compute@${OPENPCC_VERSION}

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates socat \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go/bin/mem-compute /usr/local/bin/mem-compute
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3700

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
