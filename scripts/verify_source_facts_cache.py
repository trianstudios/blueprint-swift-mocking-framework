#!/usr/bin/env python3
"""Verify persistent source classification with independent network-denied CLI processes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from verify_offline_runtime import NETWORK_BLOCK, probe_network


TRACE = "BLUEPRINT_TEST_OBSERVE_SOURCE_PARSE"
LABEL = b"Blueprint Mocking: generated 1 protocol mock(s)\n"
OUTPUTS = ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")
CACHE_RECORD = "no-indexable-source-facts-v1.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(contents):
    return hashlib.sha256(contents).hexdigest()


def verify(tool, evidence, swiftc, sdk, runtime):
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("BLUEPRINT_TEST_", "DYLD_"))}
    network = probe_network(environment)
    trace_env = environment | {TRACE: "1"}
    records = {}
    with tempfile.TemporaryDirectory(prefix="Persistent Source Facts ", dir=evidence) as temporary:
        root = Path(temporary)
        cache = root / "Source Facts"
        config = root / "blueprint-mocking.json"
        config.write_text(json.dumps({"schemaVersion": 1, "selections": [
            {"module": "Domain", "type": "Lookup", "kind": "protocol"}
        ]}) + "\n")
        parent = root / "Parent.swift"
        parent.write_text("public protocol Parent: Sendable { func label() -> String }\n")
        selected = root / "Selected.swift"
        selected.write_text("public protocol Lookup: Parent { func value() -> Int }\n")
        helper = root / "Free Helper.swift"
        valid_helper = b'public func helper(_ input: Int) -> Int { input + 1 }\n'
        helper.write_bytes(valid_helper)
        extension = root / "Support Extension.swift"
        extension.write_text("extension Parent { public func extraLabel() -> String { label() } }\n")
        files = sorted([selected, parent, helper, extension])
        arguments = ["--config", config]
        sources = [item for path in files for item in ("--source", "Domain", path)]
        args_cache = ["--source-facts-cache", cache]

        def run(label, command, *, traced=False):
            completed = subprocess.run(
                [*NETWORK_BLOCK, *command], cwd=root, env=trace_env if traced else environment,
                stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=60,
            )
            observation = {"exit": completed.returncode}
            for stream in ("stdout", "stderr"):
                data = getattr(completed, stream)
                log = evidence / f"{label}.{stream}.log"
                log.write_bytes(data)
                observation[stream] = {"file": log.name, "sha256": sha(data)}
            records[label] = observation
            return completed

        def generation(label, destinations=None, cache_option=args_cache):
            output = root / label if destinations is None else destinations
            result = run(label, [
                tool, "generate", *arguments, "--output", output, "--input-set-id", "a012", *sources,
                *cache_option,
            ], traced=True)
            return output, result

        def event(path):
            return f"DX012 fixture: parse Domain {path}\n".encode()

        def pair(path):
            return {name: (path / name).read_bytes() for name in OUTPUTS}

        def success(label, parses, *, cache_option=args_cache):
            output, result = generation(label, cache_option=cache_option)
            expected = b"".join(event(path) for path in sorted(parses))
            require((result.returncode, result.stdout, result.stderr) == (0, LABEL, expected),
                    f"{label}: unexpected exit or parser trace. See {label}.stderr.log")
            exact = pair(output)
            records[label]["outputs"] = {name: sha(data) for name, data in exact.items()}
            return output, exact

        # Fresh processes and fresh output directories prevent a publication skip from being the cache hit.
        _, reference = success("uncached", files, cache_option=[])
        _, cold_pair = success("cold", files)
        require(cold_pair == reference, "Cold cache changed generated source")
        record = cache / CACHE_RECORD
        canonical = record.read_bytes()
        warm, warm_pair = success("warm", [parent, selected, extension])
        require(warm_pair == reference and record.read_bytes() == canonical, "Warm cache changed recorded bytes")

        stale = json.loads(canonical)
        stale["profile"] = "0" * 64
        stale["checksum"] = sha("\n".join([stale["profile"], *stale["noIndexableSources"]]).encode())
        wrong_profile = json.dumps(stale, sort_keys=True, separators=(",", ":")).encode()
        changed_fact = canonical.replace(sha(valid_helper).encode(), sha(selected.read_bytes()).encode())
        for name, damaged in (
            ("truncated", canonical[:len(canonical) // 2]),
            ("incompatible-schema", canonical.replace(b'"schema":1', b'"schema":2')),
            ("oversize", b" " * 32_769),
            ("incompatible-profile", wrong_profile),
            ("altered-fact", changed_fact),
        ):
            require(damaged != canonical, "Expected a distinct cache corruption input")
            record.write_bytes(damaged)
            _, recomputed = success(f"recompute-{name}", files)
            require(recomputed == reference and record.read_bytes() == canonical,
                    f"The {name} record did not cold-recompute and recover")

        cache_alias = root / "Unowned Cache Alias"
        cache_alias.symlink_to(cache, target_is_directory=True)
        prior_cache = record.stat()
        _, cold_alias = success("ignore-cache-symlink", files, cache_option=["--source-facts-cache", cache_alias])
        require(cold_alias == reference and cache_alias.is_symlink() and record.read_bytes() == canonical
                and record.stat().st_ino == prior_cache.st_ino and record.stat().st_mtime_ns == prior_cache.st_mtime_ns,
                "The cache followed an aliased directory")
        before = helper.stat()
        malformed = valid_helper.replace(b"}", b"]")
        require(len(malformed) == before.st_size, "The source mutation must keep the original file size")
        helper.write_bytes(malformed)
        os.utime(helper, ns=(before.st_atime_ns, before.st_mtime_ns))
        require((helper.stat().st_size, helper.stat().st_mtime_ns) == (before.st_size, before.st_mtime_ns),
                "Could not restore original source stat metadata")
        prior = {name: (warm / name).stat().st_mtime_ns for name in OUTPUTS}
        _, rejected = generation("reject-source-mutation", destinations=warm)
        expected = f"{helper}:1:1: error: BPM001: Malformed Swift source. Fix parser errors before generation\n".encode()
        require((rejected.returncode, rejected.stdout, rejected.stderr) == (1, b"", event(helper) + expected),
                "Equal-size/equal-time source mutation did not reach the real parser")
        require(pair(warm) == reference and {name: (warm / name).stat().st_mtime_ns for name in OUTPUTS} == prior,
                "Malformed source replaced the previous generated pair")
        require(record.read_bytes() == canonical, "Rejected generation wrote new cache data")
        helper.write_bytes(valid_helper)

        native = root / "Native.swift"
        native.write_text("""
import BlueprintMocking
import Domain
@main enum Native {
    static func main() {
        let mock = LookupMock(failureReporter: FailureReporter { fatalError($0.message) }) {
            $0.label().willReturn("root")
            $0.value().willReturn(42)
        }
        let dependency: any Lookup = mock
        precondition(dependency.label() == "root" && dependency.value() == 42)
        precondition(mock.verify.label().wasCalled(.once).passed)
        print("PASS: DX012 warm generated mock executed")
    }
}
""".lstrip())
        compiler = [swiftc, "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx13.0", "-swift-version", "6", "-parse-as-library"]
        domain = run("compile-domain", [*compiler, "-module-name", "Domain", "-emit-module", "-emit-library",
                                     "-emit-module-path", root / "Domain.swiftmodule", "-o", root / "libDomain.dylib",
                                     *files])
        require(domain.returncode == 0, "Independent domain compilation failed")
        binary = root / "native"
        consumer = run("compile-warm-consumer", [
            *compiler, "-I", root, "-I", runtime, "-L", root, "-lDomain", "-Xlinker", "-rpath", "-Xlinker", root,
            native, *(warm / name for name in OUTPUTS), runtime / "BlueprintMocking.o", "-o", binary,
        ])
        require(consumer.returncode == 0, "Warm configured consumer compilation failed")
        result = run("run-warm-consumer", [binary])
        require(result.returncode == 0 and result.stdout == b"PASS: DX012 warm generated mock executed\n",
                "Warm configured consumer did not run the typed workflow")
    return {"network": network, "parserToolSHA256": sha(tool.read_bytes()), "checks": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("fault-tool", "swiftc", "sdk", "runtime-products", "evidence-dir"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        evidence = arguments.evidence_dir.resolve()
        evidence.mkdir(parents=True, exist_ok=True)
        report = evidence / "source-facts-cache-report.json"
        report.unlink(missing_ok=True)
        results = verify(arguments.fault_tool.resolve(strict=True), evidence, arguments.swiftc,
                         arguments.sdk, arguments.runtime_products.resolve(strict=True))
        body = (json.dumps(results, sort_keys=True, indent=2) + "\n").encode()
        report.write_bytes(body)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
    print(f"EVIDENCE: {report.name} SHA-256 {sha(body)}")
    print("PASS: DX012 persistent source facts bypassed the parser across offline processes")


if __name__ == "__main__":
    main()
