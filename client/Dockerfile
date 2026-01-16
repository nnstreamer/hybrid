FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
  && rm -rf /var/lib/apt/lists/*

COPY smoke_test.sh /usr/local/bin/smoke_test.sh

RUN chmod +x /usr/local/bin/smoke_test.sh

ENTRYPOINT ["/usr/local/bin/smoke_test.sh"]
