#!/bin/bash
set -euo pipefail

: "${BLUEPRINT_MOCKING_SOURCE_MODULE:?Set the Swift module name of the supplied source files}"
: "${BLUEPRINT_MOCKING_TOOL:?Set the absolute path to the prepared blueprint-mocking executable}"
: "${BLUEPRINT_MOCKING_CONFIG:?Set the absolute path to the Blueprint Mocking configuration}"
: "${TARGET_TEMP_DIR:?Run this script from an Xcode target build phase}"

fail() {
    printf 'error: Blueprint Mocking: %s\n' "$1" >&2
    exit 1
}

if [[ "$BLUEPRINT_MOCKING_TOOL" != /* || "$BLUEPRINT_MOCKING_CONFIG" != /* || "$TARGET_TEMP_DIR" != /* ]]; then
    fail "Tool, configuration and target intermediate paths must be absolute."
fi
if [[ "${SCRIPT_INPUT_FILE_LIST_COUNT:-0}" != 1 || "${SCRIPT_OUTPUT_FILE_LIST_COUNT:-0}" != 1 ]]; then
    fail "Declare exactly one input and one output .xcfilelist on the Run Script phase."
fi

output_directory="$TARGET_TEMP_DIR/Blueprint"
shard="$output_directory/BlueprintMocks.generated.swift"
index="$output_directory/BlueprintMockingIndex.generated.swift"
saw_shard=false
saw_index=false
while IFS= read -r path || [[ -n "$path" ]]; do
    case "$path" in
        '')
            ;;
        "$shard")
            if $saw_shard; then fail "Declare the generated shard output exactly once."; fi
            saw_shard=true
            ;;
        "$index")
            if $saw_index; then fail "Declare the generated index output exactly once."; fi
            saw_index=true
            ;;
        *)
            fail "Unexpected output list entry '$path'."
            ;;
    esac
done < "${SCRIPT_OUTPUT_FILE_LIST_0:?Xcode must supply the resolved output file list}"
if ! $saw_shard || ! $saw_index; then
    fail "Declare the generated shard and index in the target intermediate directory."
fi

sources=()
while IFS= read -r path || [[ -n "$path" ]]; do
    case "$path" in
        /*.swift)
            sources+=(--source "$BLUEPRINT_MOCKING_SOURCE_MODULE" "$path")
            ;;
        *.swift)
            fail "Swift source list entry '$path' must resolve to an absolute path."
            ;;
    esac
done < "${SCRIPT_INPUT_FILE_LIST_0:?Xcode must supply the resolved input file list}"
if [[ ${#sources[@]} -eq 0 ]]; then
    fail "Declare the supplied Swift source files in the input .xcfilelist."
fi

# The CLI derives the source membership fingerprint from the resolved module/path entries.
exec "$BLUEPRINT_MOCKING_TOOL" generate \
    --config "$BLUEPRINT_MOCKING_CONFIG" \
    --output "$output_directory" --input-set-id 008 "${sources[@]}"
