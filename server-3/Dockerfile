# Objective: Build the OpenPCC server-3 auth image.
# Usage examples:
# - docker build -t openpcc-auth -f server-3/Dockerfile server-3
FROM python:3.13-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

COPY server3 /app/server3
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
