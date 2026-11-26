#!/usr/bin/env python3
"""One entry point for the supported local prototype profile; no network dependencies."""
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "Evidence"
EVIDENCE.mkdir(exist_ok=True)
RESULTS = []

def run(name, command, *, fails=False, patterns=(), env=None, timeout=120):
    completed = subprocess.run(
        [str(x) for x in command], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = completed.stdout
    log = EVIDENCE / (name + ".log")
    log.write_text(output, encoding="utf-8")
    valid = (completed.returncode != 0) if fails else (completed.returncode == 0)
    valid = valid and all(re.search(pattern, output) for pattern in patterns)
    RESULTS.append({"check": name, "passed": bool(valid), "exit": completed.returncode,
                    "expected_failure": fails, "log": log.name,
                    "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
    print(("PASS " if valid else "FAIL ") + name, flush=True)
    if not valid:
        print(output[-10000:], flush=True)
        raise RuntimeError(name)
    return output

def generate(tool, source, output, selected="UserRepository", projections=(), *,
             module="ConsumerDomain", forwarding=()):
    arguments = [tool, "--input", source, "--module", module,
                 "--protocol", selected, "--output", output]
    for projection in projections:
        arguments.extend(["--project", projection])
    for method in forwarding:
        arguments.extend(["--forward-variadic", method])
    return arguments

def xcrun(*arguments):
    return subprocess.check_output(["xcrun", *arguments], text=True).strip()

def checkout_state():
    def git(*arguments):
        return subprocess.check_output(
            ["git", *arguments], cwd=ROOT, stderr=subprocess.DEVNULL, text=True,
            env=os.environ | {"GIT_OPTIONAL_LOCKS": "0"}, timeout=20,
        ).strip()

    try:
        if Path(git("rev-parse", "--show-toplevel")).resolve() != ROOT:
            return None
        return {
            "revision": git("rev-parse", "--verify", "HEAD"),
            "clean": not git("status", "--porcelain", "--untracked-files=normal"),
        }
    except (OSError, subprocess.SubprocessError):
        return None


def result_document():
    return (json.dumps(RESULTS, indent=2) + "\n").encode("utf-8")


def main():
    source_before = checkout_state()
    swift = Path(xcrun("--find", "swift"))
    swiftc = Path(xcrun("--find", "swiftc"))
    if any(not executable.is_absolute() or not os.access(executable, os.X_OK)
           for executable in (swift, swiftc)):
        raise RuntimeError("xcrun must select executable Swift and swiftc files")
    if swift.parent.resolve() != swiftc.parent.resolve():
        raise RuntimeError("xcrun selected Swift and swiftc from different toolchains")
    sdk = xcrun("--sdk", "macosx", "--show-sdk-path")
    sdk_version = xcrun("--sdk", "macosx", "--show-sdk-version")
    if not Path(sdk).is_dir():
        raise RuntimeError("xcrun must select an installed macOS SDK")
    deployment_target = (ROOT / "scripts/macos-deployment-target").read_text().strip()
    swift_environment = os.environ | {"SWIFT_EXEC": str(swiftc), "SDKROOT": sdk}
    swift_version = subprocess.check_output(
        [str(swift), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()
    compiler_version = subprocess.check_output(
        [str(swiftc), "--version"], text=True, stderr=subprocess.STDOUT, env=swift_environment
    ).strip()

    def run_swift(name, arguments, *, extra_environment=None, **expectations):
        return run(name, [swift, *arguments],
                   env=swift_environment | (extra_environment or {}), **expectations)

    matrix = ROOT / "Docs/Acceptance-Status.csv"
    with matrix.open(encoding="utf-8") as roadmap:
        rows = list(csv.DictReader(roadmap))
    ids = [row["Feature ID"] for row in rows]
    if len(ids) < 125 or len(ids) != len(set(ids)):
        raise ValueError("The acceptance roadmap must retain the original 125 unique contracts")
    source = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDomain/UserRepository.swift"
    generated = ROOT / "Fixtures/ProtocolConsumer/Sources/ConsumerDoubles/UserRepositoryMock.swift"
    generation_environment = swift_environment | {
        "BLUEPRINT_VERIFY_SWIFTC": str(swiftc),
        "BLUEPRINT_VERIFY_SDK_PATH": sdk,
    }
    run("generation", [
        "bash", "scripts/generate.sh", "--input", source, "--module", "ConsumerDomain",
        "--protocol", "UserRepository", "--output", generated], env=generation_environment)
    tool = ROOT / ".build/prototype-tooling/generate"
    baseline = generated.read_bytes()
    actor_source = source.with_name("MainActorDirectory.swift")
    actor_generated = generated.with_name("MainActorDirectoryMock.swift")
    run("main-actor-generation", generate(tool, actor_source, actor_generated, "MainActorDirectory"))
    actor_baseline = actor_generated.read_bytes()

    effect_source = source.with_name("EffectDirectory.swift")
    effect_generated = generated.with_name("EffectDirectoryMock.swift")
    run("effects-generation", generate(tool, effect_source, effect_generated, "EffectDirectory"))

    edge_source = source.with_name("EffectEdges.swift")
    edge_generated = generated.with_name("EffectEdgesMock.swift")
    run("effect-edges-generation", generate(tool, edge_source, edge_generated, "EffectEdges"))

    parameter_source = source.with_name("LookupParameters.swift")
    parameter_generated = generated.with_name("LookupParametersMock.swift")
    run("parameter-list-generation",
        generate(tool, parameter_source, parameter_generated, "LookupParameters"))

    structural_generated = generated.with_name("ValueDirectoryMock.swift")
    run("structural-types-generation",
        generate(tool, parameter_source, structural_generated, "ValueDirectory"))

    property_source = source.with_name("PropertyDirectory.swift")
    property_generated = generated.with_name("PropertyDirectoryMock.swift")
    run("property-accessors-generation",
        generate(tool, property_source, property_generated, "PropertyDirectory"))
    subscript_source = source.with_name("SubscriptDirectory.swift")
    subscript_generated = generated.with_name("SubscriptDirectoryMock.swift")
    run("subscript-generation", generate(tool, subscript_source, subscript_generated, "SubscriptDirectory"))
    effectful_subscript_source = source.with_name("EffectfulSubscriptDirectory.swift")
    effectful_subscript_generated = generated.with_name("EffectfulSubscriptDirectoryMock.swift")
    run("effectful-subscript-generation", generate(
        tool, effectful_subscript_source, effectful_subscript_generated, "EffectfulSubscriptDirectory"))
    variadic_subscript_source = source.with_name("VariadicSubscriptDirectory.swift")
    variadic_subscript_generated = generated.with_name("VariadicSubscriptDirectoryMock.swift")
    variadic_subscript_forwarding = ("get_subscript(field:_:)", "set_subscript(field:_:newValue:)",
                                    "get_subscript(remote:_:)")
    run("variadic-subscript-generation", generate(
        tool, variadic_subscript_source, variadic_subscript_generated, "VariadicSubscriptDirectory",
        forwarding=variadic_subscript_forwarding))
    variadic_source = source.with_name("VariadicDirectory.swift")
    variadic_generated = generated.with_name("VariadicDirectoryMock.swift")
    variadic_forwarding = ("sample(_:)", "names(in:ids:fallback:)")
    run("variadic-generation", generate(
        tool, variadic_source, variadic_generated, "VariadicDirectory", forwarding=variadic_forwarding))
    variadic_projected = generated.with_name("VariadicDirectoryProjectedMock.swift")
    run("projected-variadic-forwarding-generation", generate(
        tool, variadic_source, variadic_projected, "VariadicDirectory",
        projections=("sample(_:)",), forwarding=("sample(_:)",)))
    temp = ROOT / ".build/verification"
    temp.mkdir(parents=True, exist_ok=True)
    run("generation-repeat", generate(tool, source, temp / "Repeated.swift"))
    assert baseline == (temp / "Repeated.swift").read_bytes()
    actor_repeated = temp / "RepeatedMainActor.swift"
    run("main-actor-generation-repeat",
        generate(tool, actor_source, actor_repeated, "MainActorDirectory"))
    assert actor_baseline == actor_repeated.read_bytes()
    relocated = temp / "relocated"
    relocated.mkdir(exist_ok=True)
    relocated_source = relocated / source.name
    relocated_source.write_text(source.read_text().replace(
        "func greeting(for name: String)", "func   greeting( for name : String )"))
    run("generation-whitespace", generate(tool, relocated_source, temp / "Whitespace.swift"))
    assert baseline == (temp / "Whitespace.swift").read_bytes()
    relocated_subscript = relocated / subscript_source.name
    relocated_subscript.write_text(subscript_source.read_text().replace(
        "subscript(row: Int, column: Int)", "subscript(_ renamedRow: Int, _ renamedColumn: Int)"))
    repeated_subscript = temp / "RepeatedSubscript.swift"
    run("subscript-label-normalization", generate(
        tool, relocated_subscript, repeated_subscript, "SubscriptDirectory"))
    assert subscript_generated.read_bytes() == repeated_subscript.read_bytes()
    repeated_variadic_subscript = temp / "RepeatedVariadicSubscript.swift"
    run("variadic-subscript-generation-repeat", generate(
        tool, variadic_subscript_source, repeated_variadic_subscript, "VariadicSubscriptDirectory",
        forwarding=reversed(variadic_subscript_forwarding)))
    assert variadic_subscript_generated.read_bytes() == repeated_variadic_subscript.read_bytes()
    repeated_variadic = temp / "RepeatedVariadic.swift"
    run("variadic-generation-repeat", generate(
        tool, variadic_source, repeated_variadic, "VariadicDirectory",
        forwarding=reversed(variadic_forwarding)))
    assert variadic_generated.read_bytes() == repeated_variadic.read_bytes()
    projection_protocol = "GeneratedProjectionDirectory"
    projection_source = source.with_name(projection_protocol + ".swift")
    projection_output = generated.with_name(projection_protocol + "ProjectedMock.swift")
    projection_members = ("fetch(id:)", "read(id:)")
    run("projection-generation", generate(
        tool, projection_source, projection_output, projection_protocol, projection_members))
    repeated_projection = temp / "RepeatedProjection.swift"
    run("projection-generation-repeat", generate(
        tool, projection_source, repeated_projection, projection_protocol, reversed(projection_members)))
    assert projection_output.read_bytes() == repeated_projection.read_bytes()

    ambiguous = temp / "AmbiguousProjection.swift"
    ambiguous.write_text(
        "public protocol AmbiguousProjection: Sendable {\n"
        "    func fetch(id: Int) -> String\n"
        "    func fetch(id: String) -> String\n"
        "}\n"
    )
    projection_rejections = (
        ("unknown", projection_source, projection_protocol, ("missing(id:)",), "Unknown projection selector"),
        ("duplicate", projection_source, projection_protocol, (projection_members[0],) * 2,
         "Duplicate projection selector"),
        ("actor", actor_source, "MainActorDirectory", ("display(id:)",), "require a Sendable protocol"),
        ("effect", effect_source, "EffectDirectory", ("refreshedName(id:)",),
         "requires a synchronous nonthrowing or async-throwing method"),
        ("ambiguous", ambiguous, "AmbiguousProjection", ("fetch(id:)",), "Ambiguous projection selector"),
    )
    for label, input_path, protocol, selectors, pattern in projection_rejections:
        rejected = temp / "RejectedProjection.swift"
        previous = "sentinel: preserve the previous projection generation\n"
        rejected.write_text(previous)
        run("projection-reject-" + label, generate(tool, input_path, rejected, protocol, selectors),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == previous
    canonical = "schema1|ConsumerDomain.AmbiguousProjection|fetch(id:Int)->String|Sendable"
    disambiguated = temp / "DisambiguatedProjection.swift"
    run("projection-canonical-selector", generate(
        tool, ambiguous, disambiguated, "AmbiguousProjection", (canonical,)))
    assert "ProjectedSyncEndpoint<Int, String," in disambiguated.read_text()
    forwarding_ambiguity = temp / "ForwardingAmbiguity.swift"
    forwarding_ambiguity.write_text(
        "public protocol ForwardingAmbiguity: Sendable {\n"
        "    func sample(_ values: Int...) -> String\n"
        "    func sample(_ values: String...) -> String\n"
        "}\n"
    )
    actor_forwarding = temp / "IsolatedForwarding.swift"
    actor_forwarding.write_text(
        "@MainActor public protocol IsolatedForwarding {\n"
        "    func sample(_ values: Int...) -> String\n"
        "}\n"
    )
    forwarding_rejections = (
        ("nonvariadic", source, "UserRepository", ("greeting(for:)",), "requires a variadic instance method"),
        ("nonvariadic-subscript", subscript_source, "SubscriptDirectory", ("get_subscript(slot:)",),
         "requires a variadic instance method or subscript accessor"),
        ("unknown", variadic_source, "VariadicDirectory", ("missing(_:)",), "Unknown variadic forwarding selector"),
        ("duplicate", variadic_source, "VariadicDirectory", ("sample(_:)",) * 2,
         "Duplicate variadic forwarding selector"),
        ("actor", actor_forwarding, "IsolatedForwarding", ("sample(_:)",), "adapters require a Sendable protocol"),
        ("ambiguous", forwarding_ambiguity, "ForwardingAmbiguity", ("sample(_:)",),
         "Ambiguous variadic forwarding selector"),
    )
    for label, input_path, protocol, selectors, pattern in forwarding_rejections:
        rejected = temp / "RejectedForwarding.swift"
        previous = "sentinel: preserve the previous forwarding generation\n"
        rejected.write_text(previous)
        run("forwarding-reject-" + label, generate(
            tool, input_path, rejected, protocol, forwarding=selectors),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == previous
    selected_forward = "schema1|ConsumerDomain.ForwardingAmbiguity|sample(_:Int...)->String|Sendable"
    disambiguated_forward = temp / "DisambiguatedForwarding.swift"
    run("forwarding-canonical-selector", generate(
        tool, forwarding_ambiguity, disambiguated_forward, "ForwardingAmbiguity",
        forwarding=(selected_forward,)))
    assert "@escaping @Sendable ([Int]) -> String" in disambiguated_forward.read_text()
    assert "@escaping @Sendable ([String]) -> String" not in disambiguated_forward.read_text()
    expected_rejections = {
        "DescriptorCollision": r"Overloads that differ only by effects or result type",
        "UnsupportedEffect": r"Rethrows requires a callback-derived error",
        "EffectfulSetter": r"Effectful getters require read-only properties",
        "GenericSubscript": r"Generic subscripts require explicit specialization support",
        "StaticSubscript": r"Static and class subscripts require a scoped type-level adapter",
        "EffectfulSubscriptSetter": r"Effectful subscript getters require read-only subscripts",
        "BorrowingSubscript": r"Subscript indices require.*without ownership",
        "VariadicSubscript": r"Static and class subscripts require a scoped type-level adapter",
        "VariadicSubscriptDescriptorCollision": r"Variadic overloads with identical lowered matcher signatures",
        "VariadicDescriptorCollision": r"Variadic overloads with identical lowered matcher signatures",
        "SubscriptDescriptorCollision": r"methods that collide with accessor descriptors",
    }
    for rejection in sorted((ROOT / "Fixtures/GeneratorRejections").glob("*.swift")):
        output = temp / "Rejected.swift"
        output.write_text("sentinel: preserve the previous generation\n")
        rejection_patterns = [r"BPM001", r":\d+:\d+: error:"]
        if rejection.stem in expected_rejections:
            rejection_patterns.append(expected_rejections[rejection.stem])
        run("reject-" + rejection.stem, generate(tool, rejection, output, rejection.stem),
            fails=True, patterns=rejection_patterns)
        assert output.read_text() == "sentinel: preserve the previous generation\n"
    mapper_fixture = ROOT / "Fixtures/FailureMappingConsumer"
    mapper_tests = "Tests/FailureMappingProbeTests/FailureMappingTests.swift"
    baseline_probe = (mapper_fixture / "Variants/A/Probe.swift").read_text()
    updated_probe = (mapper_fixture / "Variants/B/Probe.swift").read_text()
    inserted_member = "    func alpha() throws(ProbeFailure) -> String\n"
    assert updated_probe.count(inserted_member) == 1
    assert updated_probe.replace(inserted_member, "", 1) == baseline_probe
    for label in ("A", "B"):
        package = temp / ("failure-mapping-" + label)
        probe = package / "Sources/ProbeDomain/Probe.swift"
        double = package / "Sources/ProbeDoubles/ProbeMock.swift"
        test_code = package / mapper_tests
        for path in (probe, double, test_code):
            path.parent.mkdir(parents=True, exist_ok=True)
        (package / "Package.swift").write_bytes((mapper_fixture / "Package.swift").read_bytes())
        probe.write_bytes((mapper_fixture / "Variants" / label / "Probe.swift").read_bytes())
        test_code.write_bytes((mapper_fixture / mapper_tests).read_bytes())
        run("failure-mapping-generation-" + label, generate(tool, probe, double, "Probe", module="ProbeDomain"))
        assert not re.search(r"failureMapping[0-9]+:", double.read_text())
        run_swift("failure-mapping-consumer-" + label, ["test", "--jobs", "4", "--package-path", package],
                  extra_environment={"BLUEPRINT_FAILURE_MAPPING_FRAMEWORK_PATH": str(ROOT)},
                  patterns=[r"GEN007_namedFailureMappingKeepsTheOriginalEndpointAcrossRegeneration\(\) passed",
                            r"GEN007_failureMappingsSelectOverloadsByArgumentType\(\) passed"])
    run_swift("runtime-tests", ["test"], patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run_swift("consumer-tests", ["test", "--package-path", "Fixtures/ProtocolConsumer"],
        patterns=[r"\b[1-9]\d* tests?\b.*\bpassed\b"])
    run_swift("consumer-demo", ["run", "--package-path", "Fixtures/ProtocolConsumer", "consumer-demo"],
        patterns=[r"PASS: generated protocol"])
    modules = Path(run_swift("consumer-bin-path", [
        "build", "--package-path", "Fixtures/ProtocolConsumer", "--show-bin-path"]).strip())
    patterns = {
        "MainActorAssertionAccess": r"main actor-isolated.*'wasCalled",
        "MainActorAsyncTransport": r"sending 'entry' risks causing data races",
        "MainActorStubbingAccess": r"main actor-isolated.*'display",
        "MainActorVerificationAccess": r"main actor-isolated.*'display",
        "MainActorWitnessAccess": r"main actor-isolated.*'display",
        "WrongResult": r"cannot convert value of type 'Int'",
        "WrongError": r"cannot convert value of type 'Other'",
        "GeneratedWrongError": r"cannot convert value of type 'UnrelatedError'",
        "GeneratedOrdinalFailureMapping": r"incorrect argument label.*failureMapping0.*failureMappings",
        "GeneratedWrongFailureMappingResult": r"'WrongFailureMappingError'.*'RepositoryError'",
        "AsyncAnswerForSync": r"cannot pass function of type.*async",
        "InvalidSendablePayload": r"type 'DirectoryEntry' does not conform to the 'Sendable' protocol",
        "NonSendableCapture": r"capture of 'box'.*non-[Ss]endable",
        "SchemaMismatch": r"cannot find type 'BlueprintRuntimeSchemaV999'",
        "ThrowForSync": r"has no member 'willThrow'",
        "ThrowForAsync": r"has no member 'willThrow'",
        "ThrowingAnswerForAsync": r"to non-throwing function type",
        "ThrowForNever": r"has no member 'willThrow'",
        "ValueForNever": r"cannot convert value of type 'String'.*'Never'",
        "AsyncAnswerForSyncThrowing": r"to parameter expecting synchronous function type",
        "SubscriptWrongIndex": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "SubscriptWrongNewValue": r"cannot convert value of type 'Int' to expected argument type 'String'",
        "SubscriptWrongGetterResult": r"cannot convert value of type 'Int' to expected argument type 'String'",
        "SubscriptThrowForSetter": r"has no member 'willThrow'",
        "SubscriptWrongTypedError": r"cannot convert value of type 'WrongSubscriptFailure' to expected argument type 'EffectfulSubscriptFailure'",
        "SubscriptWriteReadonly": r"subscript is get-only",
        "VariadicSubscriptForwardingWrongValue": r"cannot convert value of type 'Int.Type' to expected argument type 'String.Type'",
        "VariadicSubscriptWrongIndex": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "VariadicSubscriptArraySplat": r"cannot pass array of type '\[Int\]' as variadic arguments of type 'Int'",
        "VariadicWrongElement": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "VariadicForwardingWrongArray": r"cannot convert value of type 'Int.Type' to expected argument type '\[Int\].Type'",
        "VariadicForwardingWrongError": r"invalid conversion of thrown error type 'ForeignAdapterFailure' to 'VariadicFailure'",
        "VariadicArraySplat": r"cannot pass array of type '\[Int\]' as variadic arguments of type 'Int'",
    }
    for fixture in sorted((ROOT / "Fixtures/CompileFailures").glob("*.swift")):
        compiler_stage = ["-typecheck"]
        diagnostic_patterns = [patterns[fixture.stem]]
        if fixture.stem == "MainActorAsyncTransport":
            # Swift checks unsafe region transfers during SIL generation.
            compiler_stage = ["-emit-sil", "-o", os.devnull]
            diagnostic_patterns.append(r"non-Sendable 'DirectoryEntry'-typed result.*main actor-isolated")
        compiler_command = [
            swiftc, "-swift-version", "6", "-target",
            f"{platform.machine()}-apple-macos{deployment_target}", "-sdk", sdk, *compiler_stage,
            "-I", modules,
        ]
        check_name = "compile-reject-" + fixture.stem
        run(check_name, [*compiler_command, fixture], env=swift_environment,
            fails=True, patterns=diagnostic_patterns)
        if fixture.stem in {"MainActorWitnessAccess", "MainActorStubbingAccess",
                            "MainActorVerificationAccess"}:
            run(check_name + "-DefaultIsolation",
                [*compiler_command, "-default-isolation", "MainActor", fixture],
                env=swift_environment, fails=True, patterns=diagnostic_patterns)
    run_swift("reporter-intentional-failure", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX022_intentionalReporterFailure"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_FAILURE": "1"},
        patterns=[r"ConsumerTests.swift:\d+", r"Expected exactly 1 calls; observed 0"])
    run("xctest-consumer", [sys.executable, "Fixtures/XCTestConsumer/verify.py"],
        env=swift_environment, timeout=600,
        patterns=[r"PASS: XCTest reports sync and async verification failures at their caller lines"])
    for label, flag in [("typed", "--missing"), ("sync", "--missing-sync"), ("never", "--missing-never")]:
        fatal_log = run(label + "-missing-terminates", [modules / "consumer-demo", flag],
                        fails=True, patterns=[r"MOCK ISSUE: No matching stub", r"Fatal error: No matching stub"])
        assert fatal_log.index("MOCK ISSUE:") < fatal_log.index("Fatal error:")
    run_swift("runtime-only-consumer", [
        "run", "--package-path", "Fixtures/RuntimeOnly", "RuntimeOnly"],
        patterns=[r"PASS: runtime-only consumer"])
    runtime_bin = Path(run_swift("runtime-only-bin-path", [
        "build", "--package-path", "Fixtures/RuntimeOnly", "--show-bin-path"]).strip())
    linkage = run("runtime-only-linkage", ["otool", "-L", runtime_bin / "RuntimeOnly"])
    assert not any(name in linkage for name in ["SwiftSyntax", "SwiftParser", "Testing.framework", "XCTest"])
    dependencies = json.loads(run_swift("runtime-dependencies", ["package", "show-dependencies", "--format", "json"]))
    assert dependencies.get("dependencies") == []
    runtime_sources = list((ROOT / "Sources/BlueprintMocking").glob("*.swift"))
    assert all("import Testing" not in p.read_text() and "import XCTest" not in p.read_text()
               and "import SwiftSyntax" not in p.read_text() for p in runtime_sources)
    source_after = checkout_state()
    exact_revision = (
        source_before["revision"]
        if source_before and source_before == source_after and source_before["clean"] else None
    )
    profile = {
        "sourceRevision": exact_revision,
        "checkoutBefore": source_before,
        "checkoutAfter": source_after,
        "resultsSHA256": hashlib.sha256(result_document()).hexdigest(),
        "status": "prototype evidence, not release certification",
        "swift": swift_version,
        "swiftPath": str(swift),
        "swiftCompilerVersion": compiler_version,
        "swiftCompilerPath": str(swiftc),
        "languageMode": "6", "sdkPath": sdk,
        "sdkVersion": sdk_version,
        "executionOS": subprocess.check_output(["sw_vers"], text=True).strip(),
        "architecture": platform.machine(), "deploymentTarget": f"macOS {deployment_target}",
        "defaultIsolation": "compiler default (nonisolated); no upcoming feature flags",
        "parser": "SwiftParser/SwiftSyntax bundled with this exact Xcode toolchain",
        "generatedSHA256": hashlib.sha256(baseline).hexdigest(),
        "mainActorGeneratedSHA256": hashlib.sha256(actor_baseline).hexdigest(),
        "effectsGeneratedSHA256": hashlib.sha256(effect_generated.read_bytes()).hexdigest(),
        "effectEdgesGeneratedSHA256": hashlib.sha256(edge_generated.read_bytes()).hexdigest(),
        "parameterListGeneratedSHA256": hashlib.sha256(parameter_generated.read_bytes()).hexdigest(),
        "structuralTypesGeneratedSHA256": hashlib.sha256(structural_generated.read_bytes()).hexdigest(),
        "propertyAccessorsGeneratedSHA256": hashlib.sha256(property_generated.read_bytes()).hexdigest(),
        "subscriptGeneratedSHA256": hashlib.sha256(subscript_generated.read_bytes()).hexdigest(),
        "effectfulSubscriptGeneratedSHA256": hashlib.sha256(effectful_subscript_generated.read_bytes()).hexdigest(),
        "variadicSubscriptGeneratedSHA256": hashlib.sha256(variadic_subscript_generated.read_bytes()).hexdigest(),
        "variadicGeneratedSHA256": hashlib.sha256(variadic_generated.read_bytes()).hexdigest(),
        "acceptanceContractCount": len(rows),
    }
    (EVIDENCE / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")

exit_status = 0
try:
    main()
except Exception as error:
    print("Verification failed: " + str(error), file=sys.stderr)
    exit_status = 1
finally:
    (EVIDENCE / "results.json").write_bytes(result_document())
if exit_status:
    sys.exit(exit_status)
print("All prototype checks passed; evidence is in Evidence/results.json.", flush=True)
