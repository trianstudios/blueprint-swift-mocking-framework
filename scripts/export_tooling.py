#!/usr/bin/env python3
"""Export and verify a deterministic tooling source archive at an exact Git commit."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import unicodedata

from check_release import obj, read_json

REPOSITORY = Path(__file__).resolve().parents[1]
TOOLING = PurePosixPath("Packages/Tooling")
MANIFEST = str(TOOLING / "ExportManifest.json")
PROVENANCE = "BlueprintToolingExport.json"
PACKAGE_ID = "blueprint-swift-mocking-tools"
SWIFT_SYNTAX_URL = "https://github.com/swiftlang/swift-syntax.git"
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")


def git(repository, *arguments):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_OPTIONAL_LOCKS="0")
    process = subprocess.run(
        ["git", "--no-replace-objects", "-C", repository, *arguments], env=environment,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
    )
    if process.returncode:
        detail = process.stderr.decode(errors="replace").strip()
        raise ValueError(detail or f"Git could not read {arguments[0]}")
    return process.stdout


def tracked_entries(repository, revision):
    if not isinstance(revision, str) or not COMMIT.fullmatch(revision):
        raise ValueError("Specify the full lowercase Git commit ID")
    resolved = git(repository, "rev-parse", "--verify", "--end-of-options",
                   f"{revision}^{{commit}}").decode().strip()
    if resolved != revision:
        raise ValueError("The revision must be a commit object")
    entries = {}
    raw = git(repository, "ls-tree", "-r", "-z", "--full-tree", revision, "--", "LICENSE", str(TOOLING))
    for record in raw.split(b"\0"):
        if record:
            header, name = record.split(b"\t", 1)
            mode, kind, oid = header.decode("ascii").split(" ")
            entries[name.decode("utf-8")] = (mode, kind, oid)
    return entries


def blob(repository, entries, path):
    entry = entries.get(path)
    if entry is None:
        raise ValueError(f"Export source is missing from the commit: {path}")
    mode, kind, oid = entry
    if kind != "blob" or mode not in ("100644", "100755"):
        raise ValueError(f"Export source must be a regular tracked file: {path}")
    return git(repository, "cat-file", "blob", oid)


def swift_source(path):
    return len(path.parts) >= 3 and path.parts[0] in ("Sources", "Plugins") and path.suffix == ".swift"


def export_path(value):
    if not isinstance(value, str) or not value:
        raise ValueError("Export paths must be nonempty strings")
    path = PurePosixPath(value)
    if (path.is_absolute() or ".." in path.parts or path.as_posix() != value or "\\" in value
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
            or (path != PurePosixPath("Package.swift") and not swift_source(path))):
        raise ValueError(f"Invalid tooling export path: {value!r}")
    return path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_manifest(repository, entries):
    manifest = read_json(blob(repository, entries, MANIFEST), "tooling export manifest")
    if set(manifest) != {"schema", "files", "compatibility"} or type(manifest["schema"]) is not int or manifest["schema"] != 1:
        raise ValueError("Unsupported tooling export manifest")
    if not isinstance(manifest["files"], list):
        raise ValueError("Tooling export manifest needs a file list")
    paths = [export_path(value) for value in manifest["files"]]
    normalized = {unicodedata.normalize("NFC", str(path)).casefold() for path in paths}
    if len(normalized) != len(paths) or PurePosixPath("Package.swift") not in paths:
        raise ValueError("Tooling export paths must be unique and include Package.swift")
    committed_sources = {
        PurePosixPath(name).relative_to(TOOLING)
        for name in entries
        if PurePosixPath(name).is_relative_to(TOOLING)
        and swift_source(PurePosixPath(name).relative_to(TOOLING))
    }
    if set(paths).difference({PurePosixPath("Package.swift")}) != committed_sources:
        raise ValueError("Tooling export manifest must list exactly the committed Swift sources and plugins")

    compatibility = obj(manifest["compatibility"], "tooling compatibility")
    if set(compatibility) != {"runtimeProduct", "runtimeModule", "endpointSchema", "swiftLanguageMode", "swiftSyntax"}:
        raise ValueError("Unsupported tooling compatibility fields")
    if (compatibility["runtimeProduct"] != "BluepringMockingFramework"
            or compatibility["runtimeModule"] != "BlueprintMocking"
            or type(compatibility["endpointSchema"]) is not int or compatibility["endpointSchema"] != 1
            or compatibility["swiftLanguageMode"] != "6"):
        raise ValueError("Unsupported runtime compatibility")
    syntax = obj(compatibility["swiftSyntax"], "SwiftSyntax compatibility")
    if (set(syntax) != {"url", "version", "revision"} or syntax["url"] != SWIFT_SYNTAX_URL
            or not isinstance(syntax["version"], str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", syntax["version"])
            or not isinstance(syntax["revision"], str) or not COMMIT.fullmatch(syntax["revision"])):
        raise ValueError("The tooling export requires an exact SwiftSyntax version and revision")
    return paths, compatibility


def build_archive(repository, revision):
    entries = tracked_entries(repository, revision)
    paths, compatibility = load_manifest(repository, entries)
    mappings = {str(path): str(TOOLING / path) for path in paths} | {"LICENSE": "LICENSE"}
    files = {target: blob(repository, entries, source) for target, source in sorted(mappings.items())}
    provenance = {
        "schema": 1,
        "packageIdentity": PACKAGE_ID,
        "authoringRevision": revision,
        "compatibility": compatibility,
        "files": [
            {"path": target, "source": mappings[target], "sha256": digest(data)}
            for target, data in files.items()
        ],
    }
    files[PROVENANCE] = (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode()
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            tar.addfile(entry, io.BytesIO(data))
    return archive.getvalue()


def verify_archive(contents, repository, revision):
    if contents != build_archive(repository, revision):
        raise ValueError(f"Archive does not match the committed tooling export for {revision}")
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
        with archive.extractfile(PROVENANCE) as manifest:
            return read_json(manifest.read(), "tooling export provenance")


def unpack_verified_archive(contents, destination, repository, revision):
    provenance = verify_archive(contents, repository, revision)
    destination.mkdir(parents=True, exist_ok=False)
    # The same immutable bytes just matched the canonical, regular-file-only archive.
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:") as archive:
        for entry in archive:
            target = destination / entry.name
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(entry) as source, target.open("xb") as output:
                output.write(source.read())
    return provenance


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    for action, flag in (("export", "--output"), ("verify", "--archive")):
        command = actions.add_parser(action)
        command.add_argument("revision", help="full commit ID in the authoring repository")
        command.add_argument("--repository", type=Path, default=REPOSITORY)
        command.add_argument(flag, type=Path, required=True)
    options = parser.parse_args(argv)
    try:
        if options.action == "export":
            archive = build_archive(options.repository, options.revision)
            with options.output.open("xb") as output:
                output.write(archive)
        else:
            archive = options.archive.read_bytes()
            verify_archive(archive, options.repository, options.revision)
        print(f"{digest(archive)}  {options.revision}")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Tooling export failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
