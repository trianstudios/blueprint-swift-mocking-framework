#!/usr/bin/env python3
"""Compile and link BlueprintMocking at each Apple deployment floor.

Requires Xcode with all five platform SDKs installed. Optionally exercise the
fallback on an existing iOS 16 or 17 simulator without booting the device.
"""

import argparse
import json
import platform
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".build" / "apple-deployment"
PLATFORMS = (
    ("macos", "macosx", "macosx", "MACOS", ("arm64", "x86_64")),
    ("ios", "iphoneos", "ios", "IOS", ("arm64",)),
    ("tvos", "appletvos", "tvos", "TVOS", ("arm64",)),
    ("watchos", "watchos", "watchos", "WATCHOS", ("arm64_32",)),
    ("visionos", "xros", "xros", "VISIONOS", ("arm64",)),
)


def tool_output(*command):
    return subprocess.check_output(
        [str(arg) for arg in command], cwd=ROOT, text=True, timeout=180
    ).strip()


def check_artifact(artifact, floor, platform):
    build = tool_output("xcrun", "vtool", "-show-build", artifact)
    if not re.search(rf"^\s*minos\s+{re.escape(floor)}\s*$", build, re.MULTILINE):
        raise RuntimeError(f"{artifact.name} does not record deployment floor {floor}")
    if not re.search(rf"^\s*platform\s+{platform}\s*$", build, re.MULTILINE):
        raise RuntimeError(f"{artifact.name} does not record platform {platform}")

    load_commands = tool_output("xcrun", "otool", "-l", artifact)
    synchronization = [
        command for command in load_commands.split("Load command ")
        if re.search(r"^\s*name\s+\S*libswiftSynchronization\.dylib\b", command, re.MULTILINE)
    ]
    if any("LC_LOAD_WEAK_DYLIB" not in command for command in synchronization):
        raise RuntimeError(f"{artifact.name} requires Synchronization at load time")


def check_pre_mutex_simulator(swiftc, sources, floor, simulator):
    sdk_path = tool_output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    target = f"{platform.machine()}-apple-ios{floor}-simulator"
    executable = OUTPUT / "ios-pre-mutex-smoke"
    probe = ROOT / "Fixtures" / "AppleDeployment" / "PreMutexProbe.swift"
    subprocess.run(
        [swiftc, "-swift-version", "6", "-sdk", sdk_path, "-target", target,
         "-module-name", "BlueprintMockingPreMutexProbe", *sources, probe, "-o", executable],
        cwd=ROOT, check=True, timeout=180,
    )
    check_artifact(executable, floor, "IOSSIMULATOR")
    subprocess.run(
        ["xcrun", "simctl", "spawn", "--standalone", simulator, str(executable)],
        cwd=ROOT, check=True, timeout=120,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pre-mutex-ios-simulator", metavar="DEVICE",
        help="run a smoke test on an existing iOS 16 or 17 simulator by name or identifier",
    )
    args = parser.parse_args()
    swift = tool_output("xcrun", "--find", "swift")
    swiftc = tool_output("xcrun", "--find", "swiftc")
    if Path(swift).parent.resolve() != Path(swiftc).parent.resolve():
        raise RuntimeError("xcrun selected Swift and swiftc from different toolchains")
    manifest = json.loads(tool_output(swift, "package", "dump-package"))
    versions = {
        platform["platformName"]: platform["version"] for platform in manifest["platforms"]
    }
    sources = sorted((ROOT / "Sources" / "BlueprintMocking").glob("*.swift"))
    OUTPUT.mkdir(parents=True, exist_ok=True)

    for name, sdk, target_os, artifact_platform, architectures in PLATFORMS:
        sdk_path = tool_output("xcrun", "--sdk", sdk, "--show-sdk-path")
        sdk_version = tool_output("xcrun", "--sdk", sdk, "--show-sdk-version")
        for architecture in architectures:
            target = f"{architecture}-apple-{target_os}{versions[name]}"
            artifact = OUTPUT / f"{target}.dylib"
            subprocess.run(
                [swiftc, "-swift-version", "6", "-sdk", sdk_path, "-target", target,
                 "-module-name", "BlueprintMocking", "-emit-library",
                 *sources, "-o", artifact],
                cwd=ROOT, check=True, timeout=180,
            )
            check_artifact(artifact, versions[name], artifact_platform)
            print(f"PASS {target} compiled and linked with SDK {sdk_version}", flush=True)

    print("All Apple deployment-target compile checks passed.", flush=True)
    if args.pre_mutex_ios_simulator:
        check_pre_mutex_simulator(swiftc, sources, versions["ios"], args.pre_mutex_ios_simulator)
    else:
        print("No native runtime checks were run.")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Apple deployment check failed: {error}", file=sys.stderr)
        sys.exit(1)
