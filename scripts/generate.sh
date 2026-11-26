#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTC="${BLUEPRINT_VERIFY_SWIFTC:-$(xcrun --find swiftc)}"
SDK_PATH="${BLUEPRINT_VERIFY_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# The host tool links Xcode's parser dylibs. The runtime deployment floor is separate.
GENERATOR_HOST_TARGET="15.0"
HOST="$(dirname "$SWIFTC")/../lib/swift/host"
mkdir -p "$ROOT/.build/prototype-tooling"
"$SWIFTC" -target "$(uname -m)-apple-macos$GENERATOR_HOST_TARGET" -sdk "$SDK_PATH" -swift-version 6 -I "$HOST" -L "$HOST" -lSwiftSyntax -lSwiftParser \
  -Xlinker -rpath -Xlinker "$HOST" \
  "$ROOT/Packages/Tooling/Sources/BlueprintMockingCLI/main.swift" \
  "$ROOT/Packages/Tooling/Sources/BlueprintMockingCLI/PluginGeneration.swift" \
  "$ROOT/Packages/Tooling/Sources/BlueprintMockingCLI/ProtocolSourceIndex.swift" \
  -o "$ROOT/.build/prototype-tooling/generate"
"$ROOT/.build/prototype-tooling/generate" "$@"
