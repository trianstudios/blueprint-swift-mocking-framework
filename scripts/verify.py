#!/usr/bin/env python3
"""One entry point for the supported local prototype profile; no network dependencies."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys

from check_release import read_registry
from fatal_child import check_fatal_child

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = Path(os.environ.get("BLUEPRINT_EVIDENCE_DIRECTORY", ROOT / "Evidence")).resolve()
EVIDENCE.mkdir(parents=True, exist_ok=True)
RESULTS = []

def run(name, command, *, fails=False, patterns=(), env=None, timeout=120):
    completed = subprocess.run(
        [str(x) for x in command], cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    output = completed.stdout
    valid = (completed.returncode != 0) if fails else (completed.returncode == 0)
    valid = valid and all(re.search(pattern, output) for pattern in patterns)
    return record_result(name, output, completed.returncode, valid, expected_failure=fails)


def record_result(name, output, returncode, valid, *, expected_failure):
    log = EVIDENCE / (name + ".log")
    log.write_text(output, encoding="utf-8")
    RESULTS.append({"check": name, "passed": bool(valid), "exit": returncode,
                    "expected_failure": expected_failure, "log": log.name,
                    "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
    print(("PASS " if valid else "FAIL ") + name, flush=True)
    if not valid:
        print(output[-10000:], flush=True)
        raise RuntimeError(name)
    return output

def generate(tool, source, output, selected="UserRepository", projections=(), *,
             module="ConsumerDomain", forwarding=(), specializations=(), spy=False):
    arguments = [tool, "--input", source, "--module", module,
                 "--protocol", selected, "--output", output]
    for projection in projections:
        arguments.extend(["--project", projection])
    for method in forwarding:
        arguments.extend(["--forward-variadic", method])
    for specialization in specializations:
        arguments.extend(["--specialize-subscript", specialization])
    if spy:
        arguments.append("--spy")
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
    swift_environment.pop("BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE", None)
    swift_environment.pop("BLUEPRINT_EXPECT_PARAMETERIZED_REPORTER_FAILURE", None)
    swift_environment.pop("BLUEPRINT_CLOSED_OWNER_BRIDGE", None)
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
    rows, registry_errors = read_registry(matrix)
    if registry_errors:
        raise ValueError("Invalid acceptance matrix:\n" + "\n".join(registry_errors))
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
    spy_source = source.with_name("SpyDirectory.swift")
    spy_generated = generated.with_name("SpyDirectoryMock.swift")
    run("spy-generation", generate(tool, spy_source, spy_generated, "SpyDirectory", spy=True))
    actor_spy_source = source.with_name("ActorSpyDirectory.swift")
    actor_spy_generated = generated.with_name("ActorSpyDirectoryMock.swift")
    run("actor-spy-generation", generate(tool, actor_spy_source, actor_spy_generated, "ActorSpyDirectory", spy=True))
    additional_spies = [
        ("writable-spy", "WritableSpyDirectory"),
        ("actor-writable-spy", "ActorWritableSpyDirectory"),
        ("inout-spy", "InoutSpyDirectory"),
        ("callback-spy", "CallbackSpyDirectory"),
        ("depth-spy", "DepthSpyDirectory"),
        ("structural-spy", "StructuralSpyDirectory"),
    ]
    for check, protocol in additional_spies:
        run(check + "-generation", generate(
            tool, source.with_name(protocol + ".swift"), generated.with_name(protocol + "Mock.swift"),
            protocol, spy=True))
    type_subscript_source = source.with_name("TypeSubscriptDirectory.swift")
    type_subscript_generated = generated.with_name("TypeSubscriptDirectoryMock.swift")
    run("type-subscript-generation", generate(
        tool, type_subscript_source, type_subscript_generated, "TypeSubscriptDirectory"))
    generic_subscript_source = source.with_name("GenericSubscriptDirectory.swift")
    generic_subscript_generated = generated.with_name("GenericSubscriptDirectoryMock.swift")
    generic_subscript_specializations = ("get_subscript(_:)=Int", "get_subscript(_:)=String",
                                         "get_subscript(_:)=Int?", "get_subscript(named:)=Int")
    run("generic-subscript-generation", generate(
        tool, generic_subscript_source, generic_subscript_generated, "GenericSubscriptDirectory",
        specializations=generic_subscript_specializations))
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
    repeated_spy = temp / "RepeatedSpy.swift"
    run("spy-generation-repeat", generate(tool, spy_source, repeated_spy, "SpyDirectory", spy=True))
    assert spy_generated.read_bytes() == repeated_spy.read_bytes()
    repeated_actor_spy = temp / "RepeatedActorSpy.swift"
    run("actor-spy-generation-repeat", generate(tool, actor_spy_source, repeated_actor_spy, "ActorSpyDirectory", spy=True))
    assert actor_spy_generated.read_bytes() == repeated_actor_spy.read_bytes()
    for check, protocol in additional_spies:
        repeated = temp / ("Repeated" + protocol + ".swift")
        run(check + "-generation-repeat", generate(
            tool, source.with_name(protocol + ".swift"), repeated, protocol, spy=True))
        assert generated.with_name(protocol + "Mock.swift").read_bytes() == repeated.read_bytes()
    repeated_type_subscript = temp / "RepeatedTypeSubscript.swift"
    run("type-subscript-generation-repeat", generate(
        tool, type_subscript_source, repeated_type_subscript, "TypeSubscriptDirectory"))
    assert type_subscript_generated.read_bytes() == repeated_type_subscript.read_bytes()
    rejected_type_projection = temp / "RejectedTypeSubscriptProjection.swift"
    sentinel = "sentinel: preserve generated output\n"
    rejected_type_projection.write_text(sentinel)
    run("type-subscript-reject-projection", generate(
        tool, type_subscript_source, rejected_type_projection, "TypeSubscriptDirectory",
        projections=("get_subscript(_:)",)), fails=True,
        patterns=[r"BPM001", r":\d+:\d+: error:", r"cannot be combined with generated projected mock types"])
    assert rejected_type_projection.read_text() == sentinel
    repeated_generic_subscript = temp / "RepeatedGenericSubscript.swift"
    run("generic-subscript-generation-repeat", generate(
        tool, generic_subscript_source, repeated_generic_subscript, "GenericSubscriptDirectory",
        specializations=reversed(generic_subscript_specializations)))
    assert generic_subscript_generated.read_bytes() == repeated_generic_subscript.read_bytes()
    generic_rejections = (
        ("unknown", ("get_subscript(wrong:)=Int",), "Unknown generic subscript selector"),
        ("duplicate", ("get_subscript(_:)=Int?", "get_subscript(_:) = Int?"),
         "Duplicate generic subscript specialization"),
        ("unsupported-type", ("get_subscript(_:)=(Int, String)",),
         "Unsupported generic subscript specialization type"),
        ("missing-declaration", ("get_subscript(_:)=Int",),
         "Generic subscripts require explicit specialization"),
    )
    for label, options, pattern in generic_rejections:
        rejected = temp / "RejectedGenericSubscript.swift"
        sentinel = "sentinel: preserve generated output\n"
        rejected.write_text(sentinel)
        run("generic-subscript-reject-" + label, generate(
            tool, generic_subscript_source, rejected, "GenericSubscriptDirectory", specializations=options),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == sentinel
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
    spy_inout = temp / "InoutSpy.swift"
    spy_inout.write_text("public protocol InoutSpy: Sendable { func update(_ value: inout String) }\n")
    spy_async_inout = temp / "AsyncInoutSpy.swift"
    spy_async_inout.write_text("public protocol AsyncInoutSpy: Sendable { func update(_ value: inout Int) async }\n")
    spy_actor_inout = temp / "ActorInoutSpy.swift"
    spy_actor_inout.write_text("@MainActor public protocol ActorInoutSpy { func update(_ value: inout Int) }\n")
    spy_inout_collision = temp / "InoutSpyCollision.swift"
    spy_inout_collision.write_text("public protocol InoutSpyCollision: Sendable {\n"
                                   "    func update(_ value: Int)\n"
                                   "    func update(_ value: inout Int)\n"
                                   "}\n")
    spy_callback = temp / "CallbackSpy.swift"
    spy_callback.write_text("public protocol CallbackSpy: Sendable { func apply(_ block: @escaping (Int) -> Int) }\n")
    spy_actor_callback = temp / "MainActorCallbackSpy.swift"
    spy_actor_callback.write_text("public protocol MainActorCallbackSpy: Sendable {\n"
                                  "    func apply(_ block: @MainActor (Int) -> Int)\n"
                                  "}\n")
    spy_async_callback = temp / "AsyncCallbackSpy.swift"
    spy_async_callback.write_text("public protocol AsyncCallbackSpy: Sendable { func apply(_ block: (Int) -> Int) async }\n")
    spy_callback_collision = temp / "CallbackSpyCollision.swift"
    spy_callback_collision.write_text("public protocol CallbackSpyCollision: Sendable {\n"
                                      "    func apply(id: Int, using block: (Int) -> Int) -> Int\n"
                                      "    func apply(id: Int) -> Int\n"
                                      "}\n")
    spy_link_collision = temp / "SpyLinkCollision.swift"
    spy_link_collision.write_text("public protocol SpyLinkCollision: Sendable {\n"
                                  "    var forwardingTargets: Int { get }\n"
                                  "    func probe() async throws -> Int\n"
                                  "}\n")
    spy_rejections = (
        ("link-name-collision", spy_link_collision, "SpyLinkCollision", (),
         "conflicts with generated forwarding link setup or target names"),
        ("variadic", variadic_source, "VariadicDirectory", (), "cannot splat a Swift variadic argument"),
        ("writable-property", property_source, "PropertyDirectory", (), "writable property requires a nonmutating setter"),
        ("writable-subscript", subscript_source, "SubscriptDirectory", (), "writable subscript requires a nonmutating setter"),
        ("static", type_subscript_source, "TypeSubscriptDirectory", (), "use a metatype seam"),
        ("generic", generic_subscript_source, "GenericSubscriptDirectory", (), "requires a polymorphic provider"),
        ("projection", spy_source, "SpyDirectory", ("display(for:)",), "cannot be combined with projections"),
        ("inout-type", spy_inout, "InoutSpy", (), "requires a Sendable method with one inout Swift.Int"),
        ("inout-async", spy_async_inout, "AsyncInoutSpy", (), "inout forwarding requires a synchronous method"),
        ("inout-actor", spy_actor_inout, "ActorInoutSpy", (), "requires a Sendable method with one inout Swift.Int"),
        ("inout-collision", spy_inout_collision, "InoutSpyCollision", (), "Inout overloads with identical matcher signatures"),
        ("callback-escaping", spy_callback, "CallbackSpy", (), "require one unannotated, nonescaping"),
        ("callback-isolated", spy_actor_callback, "MainActorCallbackSpy", (), "require one unannotated, nonescaping"),
        ("callback-async", spy_async_callback, "AsyncCallbackSpy", (), "require a synchronous nonthrowing method"),
        ("callback-collision", spy_callback_collision, "CallbackSpyCollision", (), "identical ordinary-argument matcher signatures"),
    )
    for label, input_path, protocol, projections, pattern in spy_rejections:
        rejected = temp / "RejectedSpy.swift"
        sentinel = "sentinel: preserve generated output\n"
        rejected.write_text(sentinel)
        run("spy-reject-" + label, generate(tool, input_path, rejected, protocol, projections, spy=True),
            fails=True, patterns=[r"BPM001", r":\d+:\d+: error:", pattern])
        assert rejected.read_text() == sentinel

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
        "GenericSubscript": r"Generic subscripts require explicit specialization",
        "GenericSubscriptSetter": r"Generic specialization requires a synchronous read-only",
        "GenericSubscriptNestedResult": r"Generic subscript results must be concrete or exactly the generic index type",
        "StaticSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
        "GenericStaticSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
        "EffectfulSubscriptSetter": r"Effectful subscript getters require read-only subscripts",
        "BorrowingSubscript": r"Subscript indices require.*without ownership",
        "VariadicSubscript": r"Type-level subscript scopes require a concrete synchronous Sendable static subscript",
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
        "MainActorSpyAsyncTransport": r"sending 'entry' risks causing data races",
        "MainActorSpyWitnessAccess": r"main actor-isolated.*'display",
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
        "TypeSubscriptWrongNewValue": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "ValueForNever": r"cannot convert value of type 'String'.*'Never'",
        "AsyncAnswerForSyncThrowing": r"to parameter expecting synchronous function type",
        "GenericSubscriptWrongConstraint": r"requires that 'UnhashableKey' conform to 'Hashable'",
        "GenericSubscriptWrongMatcher": r"cannot convert value of type 'Matcher<String>' to expected argument type 'Matcher<Int>'",
        "GenericSubscriptUnsupportedSpecialization": r"no exact matches in call to instance method 'get_subscript'",
        "GenericSubscriptWrongResult": r"cannot convert value of type 'String' to expected argument type 'Int'",
        "CallbackSpyDeferredCapture": r"passing non-escaping parameter 'callback'.*'@escaping'",
        "CallbackSpyDetachedCapture": r"escaping closure captures non-escaping value",
        "InoutSpyRetainsAccess": r"escaping closure captures 'inout' parameter 'value'",
        "StructuralSpyWrongLink": r"cannot convert value of type 'AsyncThrowingForwardingTarget<Int, Int, StructuralSpyFailure>' to expected argument type 'AsyncThrowingForwardingTarget<Int, String, StructuralSpyFailure>'",
        "SpyWrongTarget": r"argument type 'UnrelatedDependency' does not conform to expected type 'SpyDirectory'",
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
        if fixture.stem in {"InoutSpyRetainsAccess", "CallbackSpyDetachedCapture"}:
            compiler_stage = ["-emit-sil", "-o", os.devnull]
        if fixture.stem == "CallbackSpyDetachedCapture":
            diagnostic_patterns.append(r"passing closure as a 'sending' parameter risks causing data races")
        if fixture.stem in {"MainActorAsyncTransport", "MainActorSpyAsyncTransport"}:
            # Swift checks unsafe region transfers during SIL generation.
            compiler_stage = ["-emit-sil", "-o", os.devnull]
            payload = "DirectoryEntry" if fixture.stem == "MainActorAsyncTransport" else "ActorSpyEntry"
            diagnostic_patterns.append(rf"non-Sendable '{payload}'-typed result.*main actor-isolated")
        compiler_command = [
            swiftc, "-swift-version", "6", "-target",
            f"{platform.machine()}-apple-macos{deployment_target}", "-sdk", sdk, *compiler_stage,
            "-I", modules,
        ]
        check_name = "compile-reject-" + fixture.stem
        run(check_name, [*compiler_command, fixture], env=swift_environment,
            fails=True, patterns=diagnostic_patterns)
        if fixture.stem in {"MainActorWitnessAccess", "MainActorStubbingAccess", "MainActorVerificationAccess",
                            "MainActorSpyWitnessAccess", "MainActorSpyAsyncTransport", "CallbackSpyDetachedCapture"}:
            run(check_name + "-DefaultIsolation",
                [*compiler_command, "-default-isolation", "MainActor", fixture],
                env=swift_environment, fails=True, patterns=diagnostic_patterns)
    run_swift("reporter-intentional-failure", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX022_intentionalReporterFailure"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_FAILURE": "1"},
        patterns=[r"ConsumerTests.swift:\d+", r"Expected exactly 1 calls; observed 0"])
    swift_testing_late_issue = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:[^\n]+"
        r"\.set[^\n]+ in a finished mock session"
    )
    late_reporter = run_swift("swift-testing-late-reporter-ownership", [
        "test", "--package-path", "Fixtures/ProtocolConsumer",
        "--filter", "DX023_lateTypeScopeTaskKeepsOwningReporter"], fails=True,
        extra_environment={"BLUEPRINT_EXPECT_LATE_REPORTER_FAILURE": "1"},
        patterns=[swift_testing_late_issue, r"recorded an issue at TypeSubscriptDirectory\.swift:",
                  r"PASS: DX023 late type task retained its owning reporter",
                  r"Test run with 1 test.*failed.*with 1 issue\b"])
    assert len(re.findall(swift_testing_late_issue, late_reporter)) == 1

    parameterized_reporter_checks = [
        ("swift-testing-parameterized-owner-explicit", "DX023_detachedParameterizedReporterAttribution"),
    ]
    release = re.search(r"\bSwift version (\d+)\.(\d+)", compiler_version)
    if release and tuple(map(int, release.groups())) >= (6, 1):
        parameterized_reporter_checks.append(
            ("swift-testing-parameterized-owner-trait", "DX023_scopedParameterizedReporterAttribution"))
    for check, test in parameterized_reporter_checks:
        display_name = re.escape(test + "(_:)")
        issue_line = rf"(?m)^[^\n]*\bTest {display_name} recorded an issue\b[^\n]*$"
        owner_issue = (
            rf'Test {display_name} recorded an issue with 1 argument scenario\s*(?:→|->)\s*"owner-A"'
            r"\s+at TypeSubscriptDirectory\.swift:\d+:\d+: Issue recorded"
        )
        owner_started = rf'Test case passing 1 argument scenario\s*(?:→|->)\s*"owner-A" to {display_name} started\.'
        peer_started = rf'Test case passing 1 argument scenario\s*(?:→|->)\s*"peer-B" to {display_name} started\.'
        attribution = run_swift(check, [
            "test", "--package-path", "Fixtures/ProtocolConsumer", "--filter", test], fails=True,
            extra_environment={"BLUEPRINT_EXPECT_PARAMETERIZED_REPORTER_FAILURE": "1"},
            patterns=[owner_started, peer_started, owner_issue, r"PASS: DX023 owner case drained 1 detached issue",
                      r"PASS: DX023 peer case drained 0 issues",
                      rf"Test {display_name} with 2 test cases failed[^\n]+with 1 issue\.",
                      r"Test run with 1 test\b[^\n]*failed[^\n]+with 1 issue\."])
        assert len(re.findall(issue_line, attribution)) == 1, f"{check} emitted extra native issues"
        peer_id, = re.findall(r"^BLUEPRINT_PARAM_PEER_ACTIVE id=(.+)$", attribution, re.MULTILINE)
        owner_id, = re.findall(r"^BLUEPRINT_PARAM_OWNER_ACTIVE id=(.+)$", attribution, re.MULTILINE)
        assert peer_id == owner_id and test in owner_id, f"{check} did not exercise one native function"
    # The native case-boundary assertions use the event schema verified on Swift 6.4.
    if release and tuple(map(int, release.groups())) >= (6, 4):
        for context in ("inherited", "detached", "thread"):
            run(f"swift-testing-finished-owner-{context}", [
                sys.executable, "Fixtures/ProtocolConsumer/verify_closed_owner.py",
                "--swift", swift, "--evidence-dir", EVIDENCE, "--skip-build", "--context", context],
                env=swift_environment, timeout=180,
                patterns=[rf"PASS: Swift Testing closed-owner {context} produced one run-level issue and no case issues"])
        run("swift-testing-finished-owner-dropped-only", [
            sys.executable, "Fixtures/ProtocolConsumer/verify_closed_owner.py",
            "--swift", swift, "--evidence-dir", EVIDENCE, "--skip-build", "--context", "detached", "--dropped-only"],
            env=swift_environment, timeout=180,
            patterns=[r"PASS: Swift Testing closed-owner detached produced one dropped-only run-level issue and no case issues"])
    run("xctest-consumer", [sys.executable, "Fixtures/XCTestConsumer/verify.py"],
        env=swift_environment, timeout=600,
        patterns=[r"PASS: XCTest reports sync and async verification failures at their caller lines",
                  r"PASS: XCTest late type task retained its owning reporter",
                  r"PASS: XCTest routes buffered orphan failures to the suite"])
    run("quiescent-configuration-retirement", [
        modules / "consumer-demo", "--quiescent-configuration"], timeout=20,
        patterns=[r"PASS: RUN035 retired configuration reentered both locks and published the next revision",
                  r"PASS: RUN035 installed an awaited configuration through the public SwiftPM product"])
    fatal_signal = {"arm64": signal.SIGTRAP, "x86_64": signal.SIGILL}[platform.machine()]

    def run_fatal(name, flag, message, *, issue_prefix=r"^MOCK ISSUE: "):
        result = check_fatal_child(
            [modules / "consumer-demo", flag], cwd=ROOT, expected_signal=fatal_signal,
            issue_pattern=issue_prefix + message, fatal_pattern=r"^.+:\d+: Fatal error: " + message,
        )
        output = result.stderr
        if result.error is not None:
            output += f"\nVerifier: {result.error}\n"
        record_result(name, output, result.returncode, result.error is None, expected_failure=True)

    missing_stubs = [
        ("typed", "--missing", r"UserRepository\|fetchUser\(id:String\) async throws\(RepositoryError\)->String"),
        ("sync", "--missing-sync", r"UserRepository\|greeting\(_:String\)->String"),
        ("never", "--missing-never", r"EffectEdges\|stop\(id:String\)->Never"),
    ]
    for label, flag, endpoint in missing_stubs:
        run_fatal(label + "-missing-terminates", flag,
                  rf"No matching stub for schema1\|ConsumerDomain\.{endpoint}\|Sendable$")
    unlisted = r"No configured specialization for schema1\|ConsumerDomain\.GenericSubscriptDirectory.*\[Swift.Bool\]$"
    run_fatal("generic-subscript-missing-terminates", "--missing-generic-specialization", unlisted)
    type_scope = r"Missing type-level mock scope for schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
    run_fatal("type-subscript-detached-reject", "--type-subscript-detached",
              type_scope + r".*\.get->Int\|Sendable$",
              issue_prefix=r"^TypeSubscriptDirectory\.swift:\d+:\d+: error: BlueprintMocking: ")
    run("type-subscript-unbound-setter", [modules / "consumer-demo", "--type-subscript-unbound-setter"],
        patterns=[type_scope + r".*\.set", r"PASS: unbound type setter returned after diagnosis"])
    stale_scope = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
        r".*\.get->Int\|Sendable with a stale type-level mock scope$"
    )
    run_fatal("type-subscript-stale-reject", "--type-subscript-stale", stale_scope)
    closed_scope = (
        r"Cannot call schema1\|ConsumerDomain\.TypeSubscriptDirectory\|type:subscript:"
        r".*\.get->Int\|Sendable in a finished mock session$"
    )
    run_fatal("type-subscript-closed-orphan-terminates", "--type-subscript-closed-orphan", closed_scope,
              issue_prefix=r"^MOCK ORPHAN: session [0-9A-Fa-f-]+ epoch 0 TypeSubscriptDirectory\.swift:2:1: ")
    run_swift("runtime-only-consumer", [
        "run", "--package-path", "Fixtures/RuntimeOnly", "RuntimeOnly"],
        patterns=[r"PASS: runtime-only consumer"])
    runtime_bin = Path(run_swift("runtime-only-bin-path", [
        "build", "--package-path", "Fixtures/RuntimeOnly", "--show-bin-path"]).strip())
    linkage = run("runtime-only-linkage", ["otool", "-L", runtime_bin / "RuntimeOnly"])
    excluded_libraries = ("SwiftSyntax", "SwiftParser", "SourceKit", "Testing.framework", "XCTest")
    assert not any(name in linkage for name in excluded_libraries)
    dependencies = json.loads(run_swift("runtime-dependencies", ["package", "show-dependencies", "--format", "json"]))
    assert dependencies.get("dependencies") == []
    runtime_consumer = json.loads(run_swift("runtime-only-consumer-dependencies", [
        "package", "--package-path", "Fixtures/RuntimeOnly", "show-dependencies", "--format", "json"]))
    runtime_dependency, = runtime_consumer["dependencies"]
    assert runtime_dependency["name"] == "BluepringMockingFramework"
    assert runtime_dependency["dependencies"] == []
    runtime_sources = list((ROOT / "Sources/BlueprintMocking").glob("*.swift"))
    excluded_imports = ("SwiftSyntax", "SwiftParser", "SourceKit", "Testing", "XCTest")
    assert all(not any(f"import {module}" in p.read_text() for module in excluded_imports) for p in runtime_sources)

    check_swiftpm_plugin = os.environ.get("BLUEPRINT_VERIFY_SWIFTPM_PLUGIN") == "1"
    if check_swiftpm_plugin:
        run("swiftpm-build-plugin-consumer", [
            sys.executable, "Fixtures/PluginConsumer/verify.py", "--swift", swift,
            "--evidence-dir", EVIDENCE, "--cache-path", ROOT / ".build/dx004-swiftpm-cache",
            "--jobs", "4",
        ], env=swift_environment, timeout=900,
            patterns=[r"PASS: DX004 SwiftPM plugin clean build, regeneration, and incremental stability"])
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
        "swiftPMBuildPluginVerified": check_swiftpm_plugin,
        "generatedSHA256": hashlib.sha256(baseline).hexdigest(),
        "mainActorGeneratedSHA256": hashlib.sha256(actor_baseline).hexdigest(),
        "effectsGeneratedSHA256": hashlib.sha256(effect_generated.read_bytes()).hexdigest(),
        "effectEdgesGeneratedSHA256": hashlib.sha256(edge_generated.read_bytes()).hexdigest(),
        "parameterListGeneratedSHA256": hashlib.sha256(parameter_generated.read_bytes()).hexdigest(),
        "structuralTypesGeneratedSHA256": hashlib.sha256(structural_generated.read_bytes()).hexdigest(),
        "propertyAccessorsGeneratedSHA256": hashlib.sha256(property_generated.read_bytes()).hexdigest(),
        "subscriptGeneratedSHA256": hashlib.sha256(subscript_generated.read_bytes()).hexdigest(),
        "effectfulSubscriptGeneratedSHA256": hashlib.sha256(effectful_subscript_generated.read_bytes()).hexdigest(),
        "actorSpyGeneratedSHA256": hashlib.sha256(actor_spy_generated.read_bytes()).hexdigest(),
        "spyGeneratedSHA256": hashlib.sha256(spy_generated.read_bytes()).hexdigest(),
        "typeSubscriptGeneratedSHA256": hashlib.sha256(type_subscript_generated.read_bytes()).hexdigest(),
        "genericSubscriptGeneratedSHA256": hashlib.sha256(generic_subscript_generated.read_bytes()).hexdigest(),
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
print(f"All prototype checks passed; evidence is in {EVIDENCE / 'results.json'}.", flush=True)
