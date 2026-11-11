#!/usr/bin/env python3
"""Collect a bounded, time-limited Hyprland client snapshot."""

import os
import selectors
import signal
import subprocess
import sys
import time


MAX_OUTPUT_BYTES = 2 * 1024 * 1024
PROCESS_TIMEOUT_SECONDS = 0.5
READ_CHUNK_BYTES = 64 * 1024
TERMINATE_GRACE_SECONDS = 0.05


class ProbeError(Exception):
    def __init__(self, message, exit_code):
        super().__init__(message)
        self.exit_code = exit_code


def stop_process(process):
    """Stop and reap the command and any descendants in its private group."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

    try:
        process.wait(timeout=TERMINATE_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def collect_clients():
    process = subprocess.Popen(
        ["hyprctl", "clients", "-j"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        start_new_session=True,
    )
    deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
    selector = selectors.DefaultSelector()
    output = bytearray()
    completed = False

    try:
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("hyprctl clients probe timed out", 3)

            events = selector.select(remaining)
            if not events:
                raise ProbeError("hyprctl clients probe timed out", 3)

            for key, _events in events:
                remaining_bytes = MAX_OUTPUT_BYTES - len(output)
                chunk = os.read(key.fd, min(READ_CHUNK_BYTES,
                                             remaining_bytes + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(chunk) > remaining_bytes:
                    raise ProbeError("hyprctl clients output exceeds size limit", 2)
                output.extend(chunk)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeError("hyprctl clients probe timed out", 3)
        try:
            exit_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise ProbeError("hyprctl clients probe timed out", 3) from error

        if exit_code != 0:
            raise ProbeError("hyprctl clients command failed", 1)
        completed = True
        return bytes(output)
    finally:
        selector.close()
        process.stdout.close()
        if not completed:
            stop_process(process)


def main():
    try:
        output = collect_clients()
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
        return 0
    except ProbeError as error:
        print("workspace navigator: " + str(error), file=sys.stderr)
        return error.exit_code
    except OSError:
        print("workspace navigator: could not run hyprctl clients probe",
              file=sys.stderr)
        return 1


def handle_termination(_signum, _frame):
    raise SystemExit(1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, handle_termination)
    raise SystemExit(main())
