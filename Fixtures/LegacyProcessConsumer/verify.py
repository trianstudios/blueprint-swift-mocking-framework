#!/usr/bin/env python3
"""Exercise real Swift global accessors in two simultaneously scoped children."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import selectors
import sys
import tempfile
import time


def overlap(run_legacy_child, executable, second_status):
    specifications = [("first scope", 149, 0), ("second scope", 703, second_status)]
    with tempfile.TemporaryDirectory(prefix="blueprint-legacy-swift-") as temporary:
        directory = Path(temporary)
        channels = []
        try:
            for index in range(len(specifications)):
                paths = [directory / f"{index}-{role}" for role in ("ready", "release")]
                descriptors = []
                channels.append((paths, descriptors))
                for path in paths:
                    os.mkfifo(path)
                    descriptors.append(os.open(path, os.O_RDWR | os.O_NONBLOCK))

            with ThreadPoolExecutor(max_workers=2) as pool, selectors.DefaultSelector() as ready:
                children = []
                for (paths, descriptors), (catalog, cents, status) in zip(channels, specifications):
                    ready.register(descriptors[0], selectors.EVENT_READ)
                    command = [str(executable), catalog, str(cents), *map(str, paths), str(status)]
                    children.append(pool.submit(run_legacy_child, command, cwd=directory, timeout=12))

                deadline = time.monotonic() + 8
                try:
                    while ready.get_map():
                        pending = ready.select(max(0, deadline - time.monotonic()))
                        if not pending:
                            raise RuntimeError("Both Swift scopes must become active before either is released")
                        for key, _ in pending:
                            if os.read(key.fd, 1) != b"1":
                                raise RuntimeError("Unexpected Swift scope-ready signal")
                            ready.unregister(key.fd)
                finally:
                    for _, descriptors in channels:
                        os.write(descriptors[1], b"1")

                return [child.result() for child in children]
        finally:
            for _, descriptors in channels:
                for descriptor in descriptors:
                    os.close(descriptor)


def check_success(result, catalog, cents):
    if result.error is not None or result.returncode != 0:
        raise RuntimeError(f"Swift scope {catalog!r} failed: {result}")
    payload = result.payload
    pid = payload.get("child") if isinstance(payload, dict) else None
    if type(pid) is not int or pid <= 0 or pid == os.getpid():
        raise RuntimeError(f"Missing independent Swift child process: {result}")
    expected = {
        "child": pid,
        "during": {"catalog": catalog, "cents": cents},
        "clearedBefore": True,
        "clearedAfterReturn": True,
        "clearedAfterThrow": True,
        "rejectedNestedScope": True,
    }
    if payload != expected:
        raise RuntimeError(f"Unexpected Swift scope result: {payload!r}, expected {expected!r}")
    return pid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--scripts-directory", type=Path, default=Path(__file__).resolve().parents[2] / "scripts")
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    sys.path.insert(0, str(args.scripts_directory.resolve(strict=True)))
    from legacy_process import run_legacy_child

    first, second = overlap(run_legacy_child, executable, second_status=0)
    if check_success(first, "first scope", 447) == check_success(second, "second scope", 2109):
        raise RuntimeError("The concurrently active Swift scopes shared a process")

    first, second = overlap(run_legacy_child, executable, second_status=23)
    check_success(first, "first scope", 447)
    if second.returncode != 23 or second.error is None or second.payload is not None:
        raise RuntimeError(f"Nonzero native child was accepted as a success: {second}")
    print("PASS overlapping Swift legacy scopes, detached access, cleanup and independent exit results")


if __name__ == "__main__":
    main()
