#!/usr/bin/env bash
set -euo pipefail

# Runs the archived revision against the official Ubuntu 24.04 ARM64 Swift image.
# Prefetch the pinned image on the local Docker engine. No build-time network is used.
image='docker.io/library/swift@sha256:48533db2448d17806ed571982fcddef736530761565f34c6f2f6a5428c438292'

usage() {
  printf 'Usage: bash scripts/verify_linux_runtime.sh [git-ref]\n'
  printf 'Requires a running local Linux ARM64 Docker engine. The default revision is HEAD.\n'
  printf 'Prefetch: docker --host unix:///var/run/docker.sock pull --platform linux/arm64 %s\n' "$image"
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
esac
if (( $# > 1 )); then
  usage >&2
  exit 2
fi

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
commit="$(git -C "$repo" rev-parse --verify --end-of-options "${1:-HEAD}^{commit}")"
docker_config="$(mktemp -d "${TMPDIR:-/tmp}/blueprint-linux-docker.XXXXXX")"
trap 'rmdir -- "$docker_config"' EXIT

docker_local() {
  env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
    docker --config "$docker_config" --host unix:///var/run/docker.sock "$@"
}

engine="$(docker_local version --format '{{.Server.Os}}/{{.Server.Arch}} {{.Server.Version}}')"
case "$engine" in
  linux/arm64\ *|linux/aarch64\ *) ;;
  *) printf 'Expected a local Linux ARM64 Docker engine, got %s\n' "$engine" >&2; exit 1 ;;
esac
if ! docker_local image inspect "$image" >/dev/null 2>&1; then
  printf 'The pinned Swift image is missing from the local engine.\n' >&2
  usage >&2
  exit 1
fi
printf 'Commit: %s\nImage: %s\nDocker engine: %s\n' "$commit" "$image" "$engine"

IFS= read -r -d '' workload <<'CONTAINER' || true
set -euo pipefail

tar -xf -
. /etc/os-release
printf 'OS: %s\nKernel: %s\nArchitecture: %s\n' "$PRETTY_NAME" "$(uname -r)" "$(uname -m)"
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 && "$(uname -m)" == aarch64 ]]
swift --version

swift test --jobs 3
swift test --jobs 3 --package-path Fixtures/ProtocolConsumer
swift test --jobs 3 --package-path Fixtures/XCTestConsumer
swift run --jobs 3 --package-path Fixtures/RuntimeOnly RuntimeOnly

dependencies="$(swift package show-dependencies)"
printf '%s\n' "$dependencies"
if [[ "$dependencies" != 'No external dependencies found' ]]; then
  printf 'Unexpected SwiftPM dependency graph\n' >&2
  exit 1
fi
runtime_dir="$(swift build --package-path Fixtures/RuntimeOnly --show-bin-path)"
links="$(ldd "$runtime_dir/RuntimeOnly")"
printf '%s\n' "$links"
if grep -Eiq 'SwiftSyntax|SwiftParser|sourcekit|libTesting|libXCTest|not found' <<<"$links"; then
  printf 'Unexpected or unresolved runtime-only linkage\n' >&2
  exit 1
fi

expect_failure() {
  local label="$1" pattern="$2" output="/tmp/$1.log"
  shift 2
  if "$@" >"$output" 2>&1 || ! grep -En "$pattern" "$output"; then
    cat "$output"
    printf '%s did not fail with the expected caller location\n' "$label" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$label"
}

expect_failure swift-testing-caller 'ConsumerTests\.swift:[0-9]+:[0-9]+: Issue recorded' \
  env BLUEPRINT_EXPECT_FAILURE=1 swift test --jobs 3 --package-path Fixtures/ProtocolConsumer \
  --filter DX022_intentionalReporterFailure

reporter_tests=Fixtures/XCTestConsumer/Tests/XCTestConsumerTests/ReporterTests.swift
for mode in sync async; do
  assert_line="$(grep -n "expected XCTest failure: $mode$" "$reporter_tests" | cut -d: -f1)"
  case "$mode" in
    sync) test_name=ReporterTests.testMismatchReportsSyncCaller; expected_count=1 ;;
    async) test_name=ReporterTests.testMismatchReportsAsyncCaller; expected_count=2 ;;
  esac
  expect_failure "xctest-$mode-caller" \
    "ReporterTests\.swift:$assert_line: error:.*Expected exactly $expected_count calls; observed $((expected_count - 1))" \
    env BLUEPRINT_XCTEST_EXPECT_FAILURE=1 swift test --jobs 3 --package-path Fixtures/XCTestConsumer \
    --filter "$test_name"
done

printf 'PASS Ubuntu 24.04 ARM64 runtime, archived generated consumers, and reporter checks\n'
CONTAINER

git -C "$repo" archive --format=tar "$commit" |
  docker_local run --rm --interactive --pull never --platform linux/arm64 \
    --network none --cap-drop ALL --security-opt no-new-privileges --read-only \
    --tmpfs /work:rw,exec,size=2147483648 --tmpfs /tmp:rw,exec,size=2147483648 \
    --tmpfs /root:rw,size=268435456 --workdir /work "$image" /bin/bash -c "$workload"
