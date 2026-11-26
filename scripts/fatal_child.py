"""Run a fatal-result probe with bounded stderr capture and a single deadline."""

from dataclasses import dataclass
import math
import os
import re
import selectors
import signal
import subprocess
import time


@dataclass(frozen=True)
class FatalChildResult:
    returncode: int
    stderr: str
    error: str | None


def _read_stderr(process, deadline, maximum_stderr, captured):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stderr, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(remaining):
                raise TimeoutError
            room = maximum_stderr - len(captured)
            chunk = os.read(process.stderr.fileno(), min(4096, room + 1))
            if not chunk:
                return True
            captured.extend(chunk[:room])
            if len(chunk) > room:
                return False


def check_fatal_child(
    command, *, cwd, issue_pattern, fatal_pattern, expected_signal, timeout=10, maximum_stderr=4096
):
    if not math.isfinite(timeout) or timeout <= 0 or maximum_stderr <= 0:
        raise ValueError("Fatal probes require a finite positive timeout and stderr limit")
    expected_signal = signal.Signals(expected_signal)
    issue = re.compile(issue_pattern)
    fatal = re.compile(fatal_pattern)
    deadline = time.monotonic() + timeout
    captured = bytearray()
    error = None
    with subprocess.Popen(
        command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE, start_new_session=True,
    ) as process:
        try:
            if _read_stderr(process, deadline, maximum_stderr, captured):
                process.wait(timeout=max(0, deadline - time.monotonic()))
            else:
                error = f"stderr exceeded {maximum_stderr} bytes"
        except (TimeoutError, subprocess.TimeoutExpired):
            error = f"child exceeded the {timeout:g} second deadline"
        finally:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

    stderr = captured.decode("utf-8", errors="replace")
    if error is not None:
        return FatalChildResult(process.returncode, stderr, error)
    if process.returncode != -expected_signal:
        error = f"expected {expected_signal.name} ({-expected_signal}), got exit {process.returncode}"
    else:
        lines = stderr.splitlines()
        issue_lines = [index for index, line in enumerate(lines) if issue.search(line)]
        fatal_lines = [index for index, line in enumerate(lines) if fatal.search(line)]
        if len(issue_lines) != 1 or len(fatal_lines) != 1 or issue_lines[0] >= fatal_lines[0]:
            error = "expected one issue diagnostic followed by one fatal diagnostic on separate stderr lines"
    return FatalChildResult(process.returncode, stderr, error)
