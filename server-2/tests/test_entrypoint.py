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

    def test_default_configs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = os.path.join(tmpdir, "calls.log")
            compute_boot = _make_stub(tmpdir, "compute_boot", log_file)
            router_com = _make_stub(tmpdir, "router_com", log_file)

            env = os.environ.copy()
            env.update(
                {
                    "COMPUTE_BOOT_BIN": compute_boot,
                    "ROUTER_COM_BIN": router_com,
                    "TEST_LOG_FILE": log_file,
                }
            )
            env.pop("SKIP_COMPUTE_BOOT", None)
            env.pop("COMPUTE_BOOT_CONFIG", None)
            env.pop("ROUTER_COM_CONFIG", None)

            result = self._run_entrypoint(env)
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = _wait_for_lines(log_file, 2)
            compute_calls = self._parse_calls(lines, compute_boot)
            router_calls = self._parse_calls(lines, router_com)

            self.assertEqual(len(compute_calls), 1, lines)
            self.assertEqual(
                compute_calls[0],
                [compute_boot, "-config", "/etc/openpcc/compute_boot.yaml"],
                compute_calls,
            )
            self.assertEqual(len(router_calls), 1, lines)
            self.assertEqual(
                router_calls[0],
                [router_com, "-config", "/etc/openpcc/router_com.yaml"],
                router_calls,
            )

    def test_skip_compute_boot(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = os.path.join(tmpdir, "calls.log")
            compute_boot = _make_stub(tmpdir, "compute_boot", log_file)
            router_com = _make_stub(tmpdir, "router_com", log_file)

            env = os.environ.copy()
            env.update(
                {
                    "COMPUTE_BOOT_BIN": compute_boot,
                    "ROUTER_COM_BIN": router_com,
                    "SKIP_COMPUTE_BOOT": "true",
                    "TEST_LOG_FILE": log_file,
                }
            )

            result = self._run_entrypoint(env)
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = _wait_for_lines(log_file, 1)
            compute_calls = self._parse_calls(lines, compute_boot)
            router_calls = self._parse_calls(lines, router_com)

            self.assertEqual(len(compute_calls), 0, lines)
            self.assertEqual(len(router_calls), 1, lines)

    def test_custom_configs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log_file = os.path.join(tmpdir, "calls.log")
            compute_boot = _make_stub(tmpdir, "compute_boot", log_file)
            router_com = _make_stub(tmpdir, "router_com", log_file)
            compute_config = "/tmp/custom_compute.yaml"
            router_config = "/tmp/custom_router.yaml"

            env = os.environ.copy()
            env.update(
                {
                    "COMPUTE_BOOT_BIN": compute_boot,
                    "ROUTER_COM_BIN": router_com,
                    "COMPUTE_BOOT_CONFIG": compute_config,
                    "ROUTER_COM_CONFIG": router_config,
                    "TEST_LOG_FILE": log_file,
                }
            )

            result = self._run_entrypoint(env)
            self.assertEqual(result.returncode, 0, result.stderr)

            lines = _wait_for_lines(log_file, 2)
            compute_calls = self._parse_calls(lines, compute_boot)
            router_calls = self._parse_calls(lines, router_com)

            self.assertEqual(len(compute_calls), 1, lines)
            self.assertEqual(
                compute_calls[0],
                [compute_boot, "-config", compute_config],
                compute_calls,
            )
            self.assertEqual(len(router_calls), 1, lines)
            self.assertEqual(
                router_calls[0],
                [router_com, "-config", router_config],
                router_calls,
            )


if __name__ == "__main__":
    unittest.main()
