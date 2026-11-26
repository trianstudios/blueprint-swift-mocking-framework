#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="$(xcrun --find swiftc)"
HOST="$(dirname "$SWIFTC")/../lib/swift/host"
mkdir -p "$ROOT/.build/prototype-tooling"
"$SWIFTC" -target "$(uname -m)-apple-macos15.0" -sdk "$(xcrun --show-sdk-path)" -swift-version 6 -I "$HOST" -L "$HOST" -lSwiftSyntax -lSwiftParser \
  -Xlinker -rpath -Xlinker "$HOST" "$ROOT/Tooling/GenerateMocks.swift" \
  -o "$ROOT/.build/prototype-tooling/generate"
"$ROOT/.build/prototype-tooling/generate" "$@"
