#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
REPORT_PATH="${1:?請提供 B 測試 JSON 報告路徑}"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unifyime-user-frequency-test.XXXXXX")"
TEST_BIN="$TEST_BUILD_DIR/UserFrequencyStoreSelfTest"
SWIFT_SOURCES=(
  "$ROOT/Sources/IME/Lexicon/UserFrequencyStore.swift"
  "$ROOT/scripts/user_frequency_store_selftest.swift"
)

swiftc \
  -parse-as-library \
  -module-name UnifyIMEUserFrequencySelfTest \
  "${SWIFT_SOURCES[@]}" \
  -o "$TEST_BIN"

"$TEST_BIN" --report-json "$REPORT_PATH"
