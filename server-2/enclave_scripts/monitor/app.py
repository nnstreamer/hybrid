#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

TAIL_LINES = 100
MISSING_RECHECK_SECONDS = 10

INDEX_HTML = """<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Compute Log Monitor</title>
  <style>
    body { font-family: monospace; margin: 20px; }
    #log { background: #111; color: #eee; padding: 12px; }
    #status { color: #c00; margin-top: 8px; font-weight: bold; }
  </style>
</head>
<body>
  <h1>Compute Log Monitor</h1>
  <div><a href="/download">Download full log</a></div>
  <pre id="log"></pre>
  <div id="status"></div>
  <script>
    const logEl = document.getElementById('log');
    const statusEl = document.getElementById('status');
    async function refresh() {
      try {
        const res = await fetch('/api/tail', { cache: 'no-store' });
        if (!res.ok) {
          throw new Error('bad response');
        }
        const data = await res.json();
        if (typeof data.lines === 'string') {
          logEl.textContent = data.lines;
        }
        if (data.available) {
          statusEl.textContent = '';
        } else {
          statusEl.textContent = 'file not available';
        }
      } catch (err) {
        statusEl.textContent = 'file not available';
      }
    }
    refresh();
    setInterval(refresh, 3000);
  </script>
</body>
</html>
"""


class LogCache:
    def __init__(self, log_path: str):
        self.log_path = log_path
        self.last_good_lines = ""
        self.last_available = False
        self.next_recheck_at = 0.0
        self.last_updated_at = ""

    def get_tail(self):
        now = time.time()
        if not self.last_available and now < self.next_recheck_at:
            return self.last_good_lines, False

        lines = self._tail_file()
        if lines is None:
            self.last_available = False
            self.next_recheck_at = now + MISSING_RECHECK_SECONDS
            return self.last_good_lines, False

        self.last_good_lines = lines
        self.last_available = True
        self.next_recheck_at = now
        self.last_updated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
        return lines, True

    def _tail_file(self):
        if not os.path.exists(self.log_path):
            return None
        try:
            result = subprocess.run(
                ["tail", "-n", str(TAIL_LINES), self.log_path],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                text=True,
            )
        except Exception:
            return None
        if result.returncode != 0:
            return None
        return result.stdout


class MonitorHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send_index()
            return
        if parsed.path == "/api/tail":
            self._send_tail()
            return
        if parsed.path == "/download":
            self._send_download()
            return
        self.send_error(404, "Not Found")

    def _send_index(self):
        body = INDEX_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_tail(self):
        lines, available = self.server.log_cache.get_tail()
        payload = {
            "available": available,
            "lines": lines,
            "updated_at": self.server.log_cache.last_updated_at,
        }
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_download(self):
        log_path = self.server.log_cache.log_path
        if not os.path.exists(log_path):
            self.send_error(404, "Log file not found")
            return
        try:
            file_size = os.path.getsize(log_path)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header(
                "Content-Disposition", 'attachment; filename="cloud-init-output.log"'
            )
            self.send_header("Content-Length", str(file_size))
            self.end_headers()
            with open(log_path, "rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except OSError:
            self.send_error(404, "Log file not found")

    def log_message(self, format, *args):
        return


class MonitorServer(HTTPServer):
    def __init__(self, server_address, handler_class, log_cache):
        super().__init__(server_address, handler_class)
        self.log_cache = log_cache


def main():
    parser = argparse.ArgumentParser(description="Compute log monitor")
    parser.add_argument(
        "--log-path",
        default="/var/log/cloud-init-output.log",
        help="Path to cloud-init-output.log",
    )
    parser.add_argument("--port", type=int, default=10080, help="HTTP listen port")
    args = parser.parse_args()

    log_cache = LogCache(args.log_path)
    server = MonitorServer(("0.0.0.0", args.port), MonitorHandler, log_cache)
    server.serve_forever()


if __name__ == "__main__":
    main()
