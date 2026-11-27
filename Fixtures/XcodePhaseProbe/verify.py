"""Run the selected macOS Xcode phase fixture with existing arm64 build artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


FIXTURE = Path(__file__).resolve().parent
ADAPTER = FIXTURE.parents[1] / "scripts/xcode/blueprint-build-phase.sh"
OUTPUTS = ("BlueprintMocks.generated.swift", "BlueprintMockingIndex.generated.swift")
STAMP = "Blueprint Mocking: generated 1 protocol mock(s)"
PROBE = "PASS: DX008 Xcode generated source compiled and ran"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(body):
    return hashlib.sha256(body).hexdigest()


def object_id(number):
    return f"A{number:023}"


def objects(project):
    contents = subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", project], timeout=15)
    return json.loads(contents)["objects"]


def install(project):
    existing = objects(project)
    if object_id(13) in existing:
        return False
    subprocess.run(
        ["/usr/bin/patch", "-p1", "--batch", "--forward", "-i", FIXTURE / "install-phase.patch"],
        cwd=project.parent, check=True, timeout=15,
    )
    return True


def file_state(path):
    return path.read_bytes(), path.stat().st_mtime_ns


def verify_install(project):
    before = objects(project)
    require(install(project), "Expected the initial reviewed phase patch")
    after = objects(project)
    added = {object_id(number) for number in (6, 7, 10, 11, 13)}
    require(set(after) == set(before) | added, "The project patch changed unexpected objects")
    changed = {key for key in before if before[key] != after[key]}
    require(changed == {object_id(number) for number in (2, 3, 14)}, "The project patch touched an existing user phase")
    require(
        after[object_id(2)]["buildPhases"] == [object_id(number) for number in (12, 13, 14, 15, 16)],
        "Generation must precede Compile Sources and preserve user phase order",
    )
    phase = after[object_id(13)]
    for kind in ("input", "output"):
        expected = f"$(SRCROOT)/Source Lists/Blueprint{kind.capitalize()}s.xcfilelist"
        require(phase[f"{kind}FileListPaths"] == [expected], f"Unexpected phase {kind} file list")
    for number, name in zip((6, 7), OUTPUTS):
        reference = after[object_id(number)]
        require(
            reference["sourceTree"] == "TARGET_TEMP_DIR" and reference["path"] == f"Blueprint/{name}",
            "Generated reference is outside the fixed target intermediate paths",
        )
    require(
        after[object_id(14)]["files"] == [object_id(number) for number in (9, 10, 11)],
        "Compile Sources must include both generated files",
    )
    applied = file_state(project)
    require(not install(project) and file_state(project) == applied, "Reinstall rewrote the project")


def stage(work, products, tool, swiftc, sdk, environment):
    project = work / "Original Project é"
    shutil.copytree(FIXTURE / "template", project)
    tools = project / "Tools"
    tools.mkdir()
    shutil.copy2(ADAPTER, tools / "Run Génération.sh")
    shutil.copy2(tool, tools / "blueprint-generate")
    runtime = project / "PreparedRuntime"
    runtime.mkdir()
    shutil.copy2(products / "BlueprintMocking.o", runtime / "BlueprintMocking.o")
    shutil.copytree(products / "BlueprintMocking.swiftmodule", runtime / "BlueprintMocking.swiftmodule")
    with (work / "domain-compile.log").open("wb") as log:
        subprocess.run(
            [swiftc, "-sdk", sdk, "-target", "arm64-apple-macosx13.0", "-swift-version", "6", "-parse-as-library",
             "-emit-object", "-emit-module", "-module-name", "PhaseDomain",
             "-emit-module-path", runtime / "PhaseDomain.swiftmodule",
             "-o", runtime / "PhaseDomain.o", project / "Services/Lookup.swift"],
            env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60,
        )
    return project


def verify(args):
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="Native phase é ", dir=args.evidence_dir.resolve()))
    print(f"DX008 native evidence directory {work}", flush=True)
    developer = args.developer_dir.resolve()
    xcodebuild = developer / "usr/bin/xcodebuild"
    swiftc = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    environment = {**os.environ, "DEVELOPER_DIR": str(developer)}
    derived = work / "Derived Data é"
    sdk = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env=environment, text=True, timeout=20,
    ).strip()
    root = stage(work, args.runtime_products, args.tool, swiftc, sdk, environment)
    installed = root / "Native Consumer.xcodeproj"
    verify_install(installed / "project.pbxproj")

    command = [
        "/usr/bin/nice", "-n", "10", xcodebuild, "-project", installed, "-scheme", "PhaseProbe",
        "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", derived, "-disableAutomaticPackageResolution", "-skipPackageUpdates",
        "-jobs", "1", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build",
    ]
    output_directory = derived / "Build/Intermediates.noindex/Native Consumer.build/Debug/PhaseProbe.build/Blueprint"
    evidence = {}

    def run(label, command):
        log = work / f"{label}.log"
        with log.open("wb") as handle:
            process = subprocess.run(
                command, env=environment, stdout=handle, stderr=subprocess.STDOUT,
                check=False, timeout=150,
            )
        data = log.read_bytes()
        evidence[label] = {"exit": process.returncode, "log": log.name, "sha256": digest(data)}
        return process.returncode, data.decode(errors="replace")

    def build(label, *, succeeds=True, stamp=True):
        code, log = run(label, command)
        require((code == 0) == succeeds and (STAMP in log) == stamp, f"Unexpected {label} result: {code}")
        require("OWNER USER PRE PHASE" in log, f"User pre-build phase was absent in {label}")
        if succeeds:
            require("OWNER USER POST PHASE" in log, f"User post-build phase was absent in {label}")
        return log

    def state():
        return {name: file_state(output_directory / name) for name in OUTPUTS}

    build("native-build")
    code, printed = run("native-probe", [derived / "Build/Products/Debug/PhaseProbe"])
    require(code == 0 and printed.strip() == PROBE, "Generated mock did not work in the native probe")
    baseline = state()
    build("unchanged", stamp=False)
    require(state() == baseline, "The unchanged Xcode build rewrote generated files")

    input_list = root / "Source Lists/BlueprintInputs.xcfilelist"
    authored_list = input_list.read_bytes()
    extra = root / "Services/Extra é.swift"
    with extra.open("x") as file:
        file.write("public struct ExtraMembership: Sendable {}\n")
    try:
        input_list.write_bytes(authored_list + f"$(SRCROOT)/Services/{extra.name}\n".encode())
        build("member-added")
        expanded = state()
        require(expanded[OUTPUTS[0]] == baseline[OUTPUTS[0]], "Membership-only change rewrote the mock shard")
        require(expanded[OUTPUTS[1]][0] != baseline[OUTPUTS[1]][0], "The index did not fingerprint added source membership")
    finally:
        input_list.write_bytes(authored_list)
        extra.unlink()
    build("member-removed")
    restored = state()
    require(
        all(restored[name][0] == baseline[name][0] for name in OUTPUTS),
        "Removing the new source did not restore the original generated pair",
    )

    config_entry = b"$(SRCROOT)/blueprint-mocking.json\n"
    require(authored_list.count(config_entry) == 1, "Expected exactly one configuration list entry")
    try:
        input_list.write_bytes(authored_list.replace(config_entry, b""))
        denied = build("undeclared-input", succeeds=False, stamp=False)
        require("blueprint-mocking.json" in denied and "permission" in denied.lower(), "Expected sandbox input denial")
        require(state() == restored, "The denied input changed the generated pair")
    finally:
        input_list.write_bytes(authored_list)
    build("restored-input")
    require(state() == restored, "Restoring the input declaration rewrote the generated pair")

    adapter = root / "Tools/Run Génération.sh"
    unowned = root / "Unowned Artifact é.txt"
    invocation = b'exec "$BLUEPRINT_MOCKING_TOOL" generate '
    attempt = 'printf "%s\\n" "unowned data" > "$SRCROOT/Unowned Artifact é.txt"\n'.encode()
    script = adapter.read_bytes()
    require(script.count(invocation) == 1, "Cannot instrument the adapter for the sandbox write test")
    try:
        adapter.write_bytes(script.replace(invocation, attempt + invocation))
        denied = build("unowned-write", succeeds=False, stamp=False)
        require("Unowned Artifact é.txt: Operation not permitted" in denied, "Expected sandbox write denial")
        require(not unowned.exists() and state() == restored, "The denied write changed project or generated files")
    finally:
        adapter.write_bytes(script)
    build("restored-script")
    require(state() == restored, "Restoring the phase script rewrote the generated pair")

    xcode = subprocess.check_output([xcodebuild, "-version"], env=environment, text=True, timeout=20)
    swift = subprocess.check_output([swiftc, "--version"], env=environment, text=True, timeout=20)
    report = {
        "xcode": xcode.splitlines(), "swift": swift.splitlines(),
        "hostToolSHA256": digest((root / "Tools/blueprint-generate").read_bytes()),
        "adapterSHA256": digest(script), "projectSHA256": digest((installed / "project.pbxproj").read_bytes()),
        "runtimeObjectSHA256": digest((root / "PreparedRuntime/BlueprintMocking.o").read_bytes()),
        "outputs": {name: digest(restored[name][0]) for name in OUTPUTS}, "results": evidence,
    }
    body = (json.dumps(report, indent=2, sort_keys=True) + "\n").encode()
    (work / "xcode-phase-report.json").write_bytes(body)
    print(f"SHA256 {digest(body)} xcode-phase-report.json")
    print("PASS: DX008 native Xcode phase, repeated install, membership and sandbox controls")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--developer-dir", required=True, type=Path)
    parser.add_argument("--tool", required=True, type=Path)
    parser.add_argument("--runtime-products", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    verify(parser.parse_args())


if __name__ == "__main__":
    main()
