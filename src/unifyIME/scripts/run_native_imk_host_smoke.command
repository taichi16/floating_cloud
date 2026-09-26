#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
REPORT_PATH="${1:?請提供 native host smoke JSON 報告路徑}"
TRACE_PATH="${2:?請提供 native host smoke trace 路徑}"
APP_BUNDLE="${3:-$HOME/Library/Input Methods/行雲_繁-A.app}"
DRY_RUN=0
SCENARIO="${UNIFYIME_NATIVE_IMK_SCENARIO:-basic}"
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --scenario=*)
      SCENARIO="${arg#--scenario=}"
      ;;
  esac
done
HOST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unifyime-native-imk-host.XXXXXX")"
HOST_APP="$HOST_BUILD_DIR/NativeIMKHostSmoke.app"
HOST_BIN="$HOST_APP/Contents/MacOS/NativeIMKHostSmoke"

source "$WORKSPACE_ROOT/scripts/dist_common.sh"
cleanup() {
  move_to_trash "$HOST_BUILD_DIR"
}
trap cleanup EXIT

HOST_ARCH="${UNIFYIME_ARCH:-${FASTCHIME_ARCH:-$(uname -m)}}"
MACOS_TARGET="${UNIFYIME_MACOS_TARGET:-${FASTCHIME_MACOS_TARGET:-13.0}}"
TARGET_TRIPLE="$HOST_ARCH-apple-macos$MACOS_TARGET"

mkdir -p "$HOST_APP/Contents/MacOS" "$HOST_APP/Contents/Resources"

swiftc \
  -parse-as-library \
  -module-name UnifyIMENativeIMKHostSmoke \
  -target "$TARGET_TRIPLE" \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  -framework InputMethodKit \
  "$ROOT/scripts/native_imk_host_smoke.swift" \
  -o "$HOST_BIN"

cp "$ROOT/scripts/NativeIMKHostSmoke-Info.plist" "$HOST_APP/Contents/Info.plist"

HOST_ARGS=(
  --report-json "$REPORT_PATH"
  --trace-path "$TRACE_PATH"
  --app-bundle "$APP_BUNDLE"
  --workspace-root "$WORKSPACE_ROOT"
  --scenario "$SCENARIO"
)
if (( DRY_RUN == 1 )); then
  HOST_ARGS+=(--dry-run)
fi

set +e
if [[ "$SCENARIO" == "long-text" ]]; then
  UNIFYIME_WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  UNIFYIME_RUNTIME_TRACE="$TRACE_PATH" \
    "$HOST_BIN" "${HOST_ARGS[@]}"
else
  UNIFYIME_WORKSPACE_ROOT="$WORKSPACE_ROOT" \
  UNIFYIME_RUNTIME_TRACE_ENABLED=1 \
  UNIFYIME_RUNTIME_TRACE="$TRACE_PATH" \
    "$HOST_BIN" "${HOST_ARGS[@]}"
fi
EXIT_CODE=$?
set -e
exit "$EXIT_CODE"
