FROM golang:1.25 AS builder

ARG OPENPCC_VERSION=v0.0.80

ENV CGO_ENABLED=0

RUN go install github.com/openpcc/openpcc/cmd/mem-auth@${OPENPCC_VERSION} \
    && go install github.com/openpcc/openpcc/cmd/mem-bank@${OPENPCC_VERSION} \
    && go install github.com/openpcc/openpcc/cmd/mem-credithole@${OPENPCC_VERSION} \
    && go install github.com/openpcc/openpcc/cmd/mem-router@${OPENPCC_VERSION} \
    && go install github.com/openpcc/openpcc/cmd/mem-gateway@${OPENPCC_VERSION} \
    && go install github.com/openpcc/openpcc/cmd/ohttp-relay@${OPENPCC_VERSION}

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go/bin/mem-auth /usr/local/bin/mem-auth
COPY --from=builder /go/bin/mem-bank /usr/local/bin/mem-bank
COPY --from=builder /go/bin/mem-credithole /usr/local/bin/mem-credithole
COPY --from=builder /go/bin/mem-router /usr/local/bin/mem-router
COPY --from=builder /go/bin/mem-gateway /usr/local/bin/mem-gateway
COPY --from=builder /go/bin/ohttp-relay /usr/local/bin/ohttp-relay
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000 3100 3200 3500 3501 3600

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
