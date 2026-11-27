"""Run one scoped legacy compatibility request per POSIX child process."""

from dataclasses import dataclass
import json
import math
import os
import selectors
import signal
import subprocess
import time
from uuid import uuid4


@dataclass(frozen=True)
class LegacyChildResult:
    returncode: int
    payload: object
    stderr: str
    error: str | None


class OutputLimitExceeded(Exception):
    pass


def _capture_output(process, buffers, deadline, maximum_output):
    with selectors.DefaultSelector() as selector:
        for name in buffers:
            selector.register(getattr(process, name), selectors.EVENT_READ, name)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            for key, _ in selector.select(remaining):
                buffer = buffers[key.data]
                room = maximum_output - len(buffer)
                chunk = os.read(key.fd, min(4096, room + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer.extend(chunk[:room])
                if len(chunk) > room:
                    raise OutputLimitExceeded(key.data)


def _unique_fields(pairs):
    fields = dict(pairs)
    if len(fields) != len(pairs):
        raise ValueError("duplicate JSON fields")
    return fields


def _invalid_json_constant(value):
    raise ValueError(f"unsupported JSON constant: {value}")


def _decode_result(stdout, request_id, pid):
    value = json.loads(stdout.decode("utf-8"), object_pairs_hook=_unique_fields,
                       parse_constant=_invalid_json_constant)
    if (type(value) is not dict or value.keys() != {"schema", "requestID", "pid", "result"}
            or type(value["schema"]) is not int or value["schema"] != 1
            or type(value["pid"]) is not int or value["pid"] != pid or value["requestID"] != request_id):
        raise ValueError("envelope does not match the originating child request")
    return value["result"]


def run_legacy_child(command, *, cwd, timeout=10, maximum_output=4096):
    """Run argv directly. Check one request-bound JSON result only after a clean exit."""
    if not math.isfinite(timeout) or timeout <= 0 or type(maximum_output) is not int or maximum_output <= 0:
        raise ValueError("Legacy child requests require a finite positive deadline and output limit")

    request_id = uuid4().hex
    environment = os.environ | {"BLUEPRINT_LEGACY_REQUEST_ID": request_id}
    deadline = time.monotonic() + timeout
    captured = {"stdout": bytearray(), "stderr": bytearray()}
    error = None
    with subprocess.Popen(
        command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    ) as process:
        try:
            _capture_output(process, captured, deadline, maximum_output)
            process.wait(timeout=max(0, deadline - time.monotonic()))
        except (TimeoutError, subprocess.TimeoutExpired):
            error = f"child exceeded the {timeout:g} second deadline"
        except OutputLimitExceeded as exceeded:
            error = f"{exceeded} exceeded {maximum_output} bytes"
        finally:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        returncode, pid = process.returncode, process.pid

    stderr = captured["stderr"].decode("utf-8", errors="replace")
    payload = None
    if error is None and returncode != 0:
        error = f"expected exit 0, got {returncode}"
    if error is None:
        try:
            payload = _decode_result(captured["stdout"], request_id, pid)
        except (ValueError, RecursionError):
            error = "expected one valid result envelope for the originating child request"
    return LegacyChildResult(returncode, payload, stderr, error)
