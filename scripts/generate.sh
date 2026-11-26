#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${BLUEPRINT_VERIFY_SWIFTC:-$(xcrun --find swiftc)}"
SDK_PATH="${BLUEPRINT_VERIFY_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
MACOS_DEPLOYMENT_TARGET="$(cat "$ROOT/scripts/macos-deployment-target")"
HOST="$(dirname "$SWIFTC")/../lib/swift/host"
mkdir -p "$ROOT/.build/prototype-tooling"
"$SWIFTC" -target "$(uname -m)-apple-macos$MACOS_DEPLOYMENT_TARGET" -sdk "$SDK_PATH" -swift-version 6 -I "$HOST" -L "$HOST" -lSwiftSyntax -lSwiftParser \
  -Xlinker -rpath -Xlinker "$HOST" "$ROOT/Tooling/GenerateMocks.swift" \
  -o "$ROOT/.build/prototype-tooling/generate"
"$ROOT/.build/prototype-tooling/generate" "$@"
