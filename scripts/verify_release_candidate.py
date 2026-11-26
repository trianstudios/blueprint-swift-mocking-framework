#!/usr/bin/env python3
"""Check the exact signed release candidate and authenticated build evidence before publishing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

import check_release
from check_release import contained_path, evaluate, passing_results, read_json

REGISTRY = "Docs/Acceptance-Status.csv"
VERIFIER = "scripts/verify.py"
SIGNATURE_NAMESPACE = "blueprint-mocking-release-evidence"
ATTESTATION_FIELDS = {
    "schema", "revision", "tag", "tagObject", "verifierSHA256",
    "registrySHA256", "profileSHA256", "resultsSHA256", "certificationSHA256",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_environment():
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    return environment | {
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    }


def invoke(command, *, failure, environment, data=None):
    process = subprocess.run(
        command, env=environment, input=data, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=30,
    )
    if process.returncode:
        raise ValueError(failure)
    return process.stdout


def git(checkout, environment, *arguments, failure):
    return invoke([
        "git", "-C", checkout, "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
        *arguments,
    ], failure=failure, environment=environment)


def clean_head(checkout, environment):
    root = git(checkout, environment, "rev-parse", "--show-toplevel",
               failure="candidate is not a Git checkout").decode().strip()
    if Path(root).resolve() != checkout:
        raise ValueError("candidate path must be the root of the Git checkout")
    revision = git(checkout, environment, "rev-parse", "--verify", "HEAD",
                   failure="candidate checkout has no HEAD").decode().strip()
    state = git(checkout, environment, "status", "--porcelain=v1", "--untracked-files=all",
                "--ignore-submodules=none", failure="could not inspect candidate checkout status")
    entries = git(checkout, environment, "ls-files", "-v", "-z", failure="could not inspect candidate index")
    if state or any(entry[:2] != b"H " for entry in entries.rstrip(b"\0").split(b"\0")):
        raise ValueError("candidate checkout must be clean and fully checked out")
    return revision


def external_path(path, internal_roots, label):
    path = path.resolve(strict=True)
    if any(path.is_relative_to(root) for root in internal_roots):
        raise ValueError(f"{label} must be outside the candidate checkout and Git directories")
    return path


def read_attestation(evidence, keygen, signers, identity, environment):
    path = contained_path(evidence, "attestation.json")
    signature = contained_path(evidence, "attestation.json.sig")
    document = path.read_bytes()
    invoke([
        keygen, "-Y", "verify", "-f", signers, "-I", identity,
        "-n", SIGNATURE_NAMESPACE, "-s", signature,
    ], failure="trusted runner signature verification failed", environment=environment, data=document)
    attestation = read_json(document, "runner attestation")
    if set(attestation) != ATTESTATION_FIELDS or type(attestation["schema"]) is not int or attestation["schema"] != 1:
        raise ValueError("unsupported runner attestation fields or schema")
    return attestation


def tag_object(checkout, environment, ref):
    return git(checkout, environment, "show-ref", "--hash", "--verify", ref,
               failure="candidate tag ref is missing").decode().strip()


def verify_tag(checkout, environment, keygen, signers, tag, revision):
    ref = f"refs/tags/{tag}"
    git(checkout, environment, "check-ref-format", ref, failure="invalid candidate tag name")
    tag_oid = tag_object(checkout, environment, ref)
    content = git(checkout, environment, "cat-file", "tag", tag_oid,
                  failure="candidate tag must be annotated")
    header = f"object {revision}\ntype commit\ntag {tag}\n".encode()
    if not content.startswith(header):
        raise ValueError("candidate tag must name and directly target the checkout commit")
    signature = git(checkout, environment, "for-each-ref", "--count=1",
                    "--format=%(objectname)%00%(refname)%00%(contents:signature)", ref,
                    failure="could not inspect candidate tag signature")
    ssh_prefix = f"{tag_oid}\0{ref}\0-----BEGIN SSH SIGNATURE-----\n".encode()
    if not signature.startswith(ssh_prefix) or not signature.rstrip().endswith(b"-----END SSH SIGNATURE-----"):
        raise ValueError("candidate tag requires an SSH signature")
    git(checkout, environment,
        "-c", "gpg.format=ssh", "-c", f"gpg.ssh.program={keygen}",
        "-c", f"gpg.ssh.allowedSignersFile={signers}", "-c", "gpg.minTrustLevel=fully",
        "verify-tag", "--", tag_oid, failure="trusted release tag signature verification failed")
    return tag_oid


def evidence_document(evidence, name, expected):
    data = contained_path(evidence, name).read_bytes()
    if digest(data) != expected:
        raise ValueError(f"{name} digest does not match the signed runner attestation")
    return data


def verify_profile(evidence, attestation, revision):
    profile_data = evidence_document(evidence, "profile.json", attestation["profileSHA256"])
    profile = read_json(profile_data, "verifier profile")
    if profile.get("sourceRevision") != revision:
        raise ValueError("verifier profile must bind the actual checkout revision")
    for key in ("checkoutBefore", "checkoutAfter"):
        state = profile.get(key)
        if not isinstance(state, dict) or state.get("revision") != revision or state.get("clean") is not True:
            raise ValueError("verifier profile must bind the same clean checkout before and after verification")
    results_data = evidence_document(evidence, "results.json", attestation["resultsSHA256"])
    if profile.get("resultsSHA256") != digest(results_data):
        raise ValueError("verifier results digest does not match the profile")
    results = read_json(b'{"results":' + results_data + b'}', "verifier results")["results"]
    if not passing_results(results):
        raise ValueError("verifier results must contain passing checks")
    for result in results:
        evidence_document(evidence, result.get("log"), result.get("logSHA256"))


def verify_candidate(checkout, tag, evidence, tag_signers, runner_signers, runner_id, verifier_sha256):
    checkout = checkout.resolve(strict=True)
    environment = git_environment()
    revision = clean_head(checkout, environment)
    git_roots = [
        Path(git(checkout, environment, "rev-parse", "--path-format=absolute", flag,
                 failure="could not locate candidate Git directories").decode().strip()).resolve()
        for flag in ("--git-dir", "--git-common-dir")
    ]
    internal_roots = [checkout, *git_roots]
    external_path(Path(__file__), internal_roots, "release gate tool")
    external_path(Path(check_release.__file__), internal_roots, "acceptance checker tool")
    evidence = external_path(evidence, internal_roots, "build evidence")
    policy_roots = [*internal_roots, evidence]
    tag_signers = external_path(tag_signers, policy_roots, "release tag signers")
    runner_signers = external_path(runner_signers, policy_roots, "runner signers")
    keygen = shutil.which("ssh-keygen", path=environment.get("PATH"))
    if not keygen:
        raise ValueError("OpenSSH ssh-keygen is required")

    attestation = read_attestation(evidence, keygen, runner_signers, runner_id, environment)
    if attestation["revision"] != revision:
        raise ValueError("signed evidence revision does not match the actual checkout commit")
    tag_oid = verify_tag(checkout, environment, keygen, tag_signers, tag, revision)
    if attestation["tag"] != tag or attestation["tagObject"] != tag_oid:
        raise ValueError("signed runner evidence does not match the verified candidate tag")

    verifier = git(checkout, environment, "show", f"{revision}:{VERIFIER}",
                   failure="candidate is missing its verifier")
    if not re.fullmatch(r"[0-9a-f]{64}", verifier_sha256) or digest(verifier) != verifier_sha256:
        raise ValueError("candidate verifier does not match the approved verifier SHA-256")
    if attestation["verifierSHA256"] != verifier_sha256:
        raise ValueError("signed runner evidence does not match the approved verifier")
    registry_digest = digest(git(checkout, environment, "show", f"{revision}:{REGISTRY}",
                                 failure="candidate is missing its committed acceptance registry"))
    if attestation["registrySHA256"] != registry_digest:
        raise ValueError("signed runner evidence does not match the committed acceptance registry")

    verify_profile(evidence, attestation, revision)
    registry = contained_path(checkout, REGISTRY)
    certification = contained_path(evidence, "certification.json")
    report = evaluate(
        registry, certification, revision, repository=checkout,
        registry_sha256=registry_digest, certification_sha256=attestation["certificationSHA256"],
    )
    if report["state"] != "ready":
        details = "; ".join(report["errors"])
        raise ValueError(f"strict release check returned {report['state']}" + (f": {details}" if details else ""))
    if clean_head(checkout, environment) != revision or tag_object(checkout, environment, f"refs/tags/{tag}") != tag_oid:
        raise ValueError("candidate checkout or verified tag changed during release verification")
    return report | {"revision": revision, "tag": tag, "tagObject": tag_oid, "runner": runner_id}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--tag-signers", type=Path, required=True)
    parser.add_argument("--runner-signers", type=Path, required=True)
    parser.add_argument("--runner-id", required=True)
    parser.add_argument("--verifier-sha256", required=True)
    options = parser.parse_args()
    try:
        report = verify_candidate(
            options.checkout, options.tag, options.evidence, options.tag_signers,
            options.runner_signers, options.runner_id, options.verifier_sha256,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Release candidate rejected: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
