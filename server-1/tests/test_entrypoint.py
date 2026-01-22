import os
import subprocess
import tempfile
import time
import unittest


ENTRYPOINT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, "entrypoint.sh")
)


def _make_stub(bin_dir: str, name: str, log_file: str) -> str:
    path = os.path.join(bin_dir, name)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'echo "${0} $*" >> "${TEST_LOG_FILE}"\n'
        )
    os.chmod(path, 0o755)
    return path


def _read_log_lines(log_file: str) -> list[str]:
    if not os.path.exists(log_file):
        return []
    with open(log_file, "r", encoding="utf-8") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def _wait_for_lines(log_file: str, count: int, timeout: float = 1.0) -> list[str]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        lines = _read_log_lines(log_file)
        if len(lines) >= count:
            return lines
        time.sleep(0.02)
    return _read_log_lines(log_file)


class EntrypointTests(unittest.TestCase):
    def _run_entrypoint(self, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", ENTRYPOINT],
            env=env,
            cwd=os.path.dirname(ENTRYPOINT),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def _parse_calls(self, lines: list[str], bin_path: str) -> list[list[str]]:
        calls: list[list[str]] = []
        for line in lines:
            tokens = line.split()
            if tokens and tokens[0] == bin_path:
                calls.append(tokens)
        return calls

    def test_default_credithole_invocation(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = os.path.join(tmpdir, "calls.log")
            credithole = _make_stub(tmpdir, "mem-credithole", log_file)
            router = _make_stub(tmpdir, "mem-router", log_file)

            env = os.environ.copy()
            env.update(
                {
                    "MEM_CREDITHOLE_BIN": credithole,
                    "MEM_ROUTER_BIN": router,
                    "TEST_LOG_FILE": log_file,
                }
            )
            env.pop("CREDITHOLE_CONFIG", None)

            result = self._run_entrypoint(env)
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = _wait_for_lines(log_file, 2)
            credithole_calls = self._parse_calls(lines, credithole)
            router_calls = self._parse_calls(lines, router)

            self.assertEqual(len(credithole_calls), 1, lines)
            self.assertEqual(len(credithole_calls[0]), 1, credithole_calls)
            self.assertEqual(len(router_calls), 1, lines)

    def test_custom_credithole_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = os.path.join(tmpdir, "calls.log")
            credithole = _make_stub(tmpdir, "mem-credithole", log_file)
            router = _make_stub(tmpdir, "mem-router", log_file)
            config_path = "/tmp/credithole.yaml"

            env = os.environ.copy()
            env.update(
                {
                    "MEM_CREDITHOLE_BIN": credithole,
                    "MEM_ROUTER_BIN": router,
                    "CREDITHOLE_CONFIG": config_path,
                    "TEST_LOG_FILE": log_file,
                }
            )

            result = self._run_entrypoint(env)
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = _wait_for_lines(log_file, 2)
            credithole_calls = self._parse_calls(lines, credithole)
            router_calls = self._parse_calls(lines, router)

            self.assertEqual(len(credithole_calls), 1, lines)
            self.assertEqual(
                credithole_calls[0],
                [credithole, "-config", config_path],
                credithole_calls,
            )
            self.assertEqual(len(router_calls), 1, lines)


if __name__ == "__main__":
    unittest.main()
