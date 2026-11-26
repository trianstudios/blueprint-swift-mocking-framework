#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHADOW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/blueprint-swift-shadow.XXXXXXXX")"
trap 'rm -f "$SHADOW_DIR/swift" "$SHADOW_DIR/invoked"; rmdir "$SHADOW_DIR"' EXIT

cat > "$SHADOW_DIR/swift" <<'SWIFT'
#!/bin/bash
printf '%s\n' "$*" >> "$BLUEPRINT_SHADOW_SWIFT_MARKER"
printf '%s\n' 'The verifier invoked a PATH-shadowed Swift driver' >&2
exit 97
SWIFT
chmod +x "$SHADOW_DIR/swift"

if ! PATH="$SHADOW_DIR:$PATH" BLUEPRINT_SHADOW_SWIFT_MARKER="$SHADOW_DIR/invoked" \
    python3 "$ROOT/scripts/verify.py"; then
    if [[ -f "$SHADOW_DIR/invoked" ]]; then
        printf 'The shadow Swift driver received: %s\n' "$(cat "$SHADOW_DIR/invoked")" >&2
    fi
    exit 1
fi
[[ ! -e "$SHADOW_DIR/invoked" ]]
