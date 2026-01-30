from __future__ import annotations

import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

from .config import ConfigError, build_api_payload, load_config, parse_config


class ConfigServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_cls: type[BaseHTTPRequestHandler],
        config_path: str,
        config_json: str,
        logger: logging.Logger,
    ) -> None:
        super().__init__(server_address, handler_cls)
        self.config_path = config_path
        self.config_json = config_json
        self.logger = logger

    def build_payload(self) -> dict[str, Any]:
        raw = load_config(self.config_path, self.config_json)
        parsed = parse_config(raw)
        return build_api_payload(parsed)


class ConfigRequestHandler(BaseHTTPRequestHandler):
    server: ConfigServer

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/healthz":
            self._send_json({"status": "ok"}, status=200, cache_control="no-store")
            return
        if path == "/api/config":
            self._handle_config()
            return
        self._send_json({"error": "not_found"}, status=404, cache_control="no-store")

    def _handle_config(self) -> None:
        try:
            payload = self.server.build_payload()
        except ConfigError as exc:
            self.server.logger.warning("Config error: %s", exc)
            self._send_json(
                {"error": "config_error", "detail": str(exc)},
                status=500,
                cache_control="no-store",
            )
            return
        except Exception:
            self.server.logger.exception("Unexpected server error")
            self._send_json(
                {"error": "internal_error"},
                status=500,
                cache_control="no-store",
            )
            return
        self._send_json(payload, status=200, cache_control="no-store")

    def log_message(self, fmt: str, *args: Any) -> None:
        message = fmt % args
        self.server.logger.info("%s - %s", self.address_string(), message)

    def _send_json(self, payload: dict[str, Any], status: int, cache_control: str) -> None:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", cache_control)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    log_level = os.getenv("SERVER3_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=log_level,
        format="[server-3] %(asctime)s %(levelname)s %(message)s",
    )
    logger = logging.getLogger("server-3")

    config_path = os.getenv("SERVER3_CONFIG_PATH", "/etc/openpcc/server-3.json")
    config_json = os.getenv("SERVER3_CONFIG_JSON", "").strip()

    bind_addr = os.getenv("SERVER3_BIND_ADDR", "0.0.0.0")
    port_raw = os.getenv("SERVER3_PORT", "8080")
    try:
        port = int(port_raw)
    except ValueError as exc:
        raise SystemExit(f"SERVER3_PORT must be an integer: {port_raw}") from exc

    try:
        _ = parse_config(load_config(config_path, config_json))
    except ConfigError as exc:
        logger.error("Configuration error: %s", exc)
        raise SystemExit(1) from exc

    server = ConfigServer((bind_addr, port), ConfigRequestHandler, config_path, config_json, logger)
    logger.info("server-3 auth listening on %s:%d", bind_addr, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("server-3 shutting down")


if __name__ == "__main__":
    main()
