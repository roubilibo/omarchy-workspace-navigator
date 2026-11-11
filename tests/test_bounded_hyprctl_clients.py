import os
import pathlib
import stat
import subprocess
import tempfile
import time
import unittest


PLUGIN_ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = PLUGIN_ROOT / "bin" / "bounded-hyprctl-clients.py"
MAX_OUTPUT_BYTES = 2 * 1024 * 1024


class BoundedHyprctlClientsTests(unittest.TestCase):
    def run_probe(self, command):
        with tempfile.TemporaryDirectory() as directory:
            fake_hyprctl = pathlib.Path(directory) / "hyprctl"
            fake_hyprctl.write_text("#!/bin/sh\n" + command + "\n")
            fake_hyprctl.chmod(fake_hyprctl.stat().st_mode | stat.S_IXUSR)
            environment = os.environ.copy()
            environment["PATH"] = directory + os.pathsep + environment["PATH"]
            return subprocess.run(
                ["python3", str(HELPER)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                timeout=3,
                check=False,
            )

    def test_success_returns_complete_client_json(self):
        expected = b'[{"address":"0x123","at":[1,2]}]\n'
        result = self.run_probe("printf '%s' '" + expected.decode().strip() + "'")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, expected.rstrip(b"\n"))

    def test_oversized_output_fails_without_forwarding_partial_json(self):
        result = self.run_probe(
            "exec python3 -c 'import sys; "
            "sys.stdout.buffer.write(b\"x\" * "
            + str(MAX_OUTPUT_BYTES + 1) + ")'"
        )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")

    def test_hung_command_is_stopped_before_helper_returns(self):
        started = time.monotonic()
        result = self.run_probe("exec sleep 10")
        elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, b"")
        self.assertLess(elapsed, 1.5)

    def test_failed_command_does_not_forward_stdout(self):
        result = self.run_probe("printf 'partial'; exit 7")

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
