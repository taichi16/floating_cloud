#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT/../.." && pwd)"
APP_BIN="$WORKSPACE_ROOT/bin/app/全一輸入法.app/Contents/MacOS/UnifyIME"
REPORT_SCRIPT="$ROOT/scripts/test_report.py"
REPORT_ROOT="$WORKSPACE_ROOT/doc/test-results"
RUN_SELFTEST=1
RUN_NATIVE_IMK=1
BUILD_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --skip-selftest)
      RUN_SELFTEST=0
      ;;
    --skip-native-imk)
      RUN_NATIVE_IMK=0
      ;;
    *)
      BUILD_ARGS+=("$arg")
      ;;
  esac
done

if [[ ! " ${BUILD_ARGS[*]} " =~ " --skip-sign " ]]; then
  BUILD_ARGS+=(--skip-sign)
fi
if (( RUN_NATIVE_IMK == 1 )); then
  if [[ ! " ${BUILD_ARGS[*]} " =~ " --no-deploy " && ! " ${BUILD_ARGS[*]} " =~ " --deploy " ]]; then
    BUILD_ARGS+=(--deploy)
  fi
elif [[ ! " ${BUILD_ARGS[*]} " =~ " --no-deploy " && ! " ${BUILD_ARGS[*]} " =~ " --deploy " ]]; then
  BUILD_ARGS+=(--no-deploy)
fi

BUILD_MODE="${UNIFYIME_SWIFT_CONFIGURATION:-${FASTCHIME_SWIFT_CONFIGURATION:-debug}}"
for arg in "${BUILD_ARGS[@]}"; do
  case "$arg" in
    --release)
      BUILD_MODE="release"
      ;;
    --debug)
      BUILD_MODE="debug"
      ;;
  esac
done

RUN_ID="$(python3 -c 'import datetime, uuid; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex)')"
RUN_DIR="$REPORT_ROOT/$RUN_ID"
REPORT_JSON="$REPORT_ROOT/unifyime-check-$RUN_ID.json"
REPORT_MARKDOWN="$REPORT_ROOT/unifyime-check-$RUN_ID.md"
RAW_REPORT_JSON="$RUN_DIR/raw-selftest.json"
B_REPORT_JSON="$RUN_DIR/user-frequency.json"
mkdir -p "$RUN_DIR"

GIT_SHA="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD)"
PLATFORM="$(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"
STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
python3 "$REPORT_SCRIPT" init \
  --output "$REPORT_JSON" \
  --run-id "$RUN_ID" \
  --workspace-root "$WORKSPACE_ROOT" \
  --git-sha "$GIT_SHA" \
  --platform "$PLATFORM" \
  --build-mode "$BUILD_MODE" \
  --started-at "$STARTED_AT" \
  --fixture-file "$WORKSPACE_ROOT/src/unifyIME/tests/regression_cases.jsonl" \
  --fixture-file "$WORKSPACE_ROOT/src/unifyIME/tests/composition_append_cases.jsonl" \
  --fixture-file "$WORKSPACE_ROOT/src/unifyIME/tests/web_mixed_sentences.jsonl"

typeset -i STAGE_INDEX=0
typeset -i OVERALL_EXIT=0
typeset -i LAST_STAGE_EXIT=0
LAST_STAGE_STATUS="unresolved"

monotonic_milliseconds() {
  python3 -c 'import time; print(int(time.monotonic() * 1000))'
}

record_manual_stage() {
  local name="$1"
  local stage_status="$2"
  local duration_ms="${3:-0}"
  local exit_code_arg="${4:-}"
  print "[check] 階段 $name：$stage_status"
  if [[ -n "$exit_code_arg" ]]; then
    python3 "$REPORT_SCRIPT" record \
      --output "$REPORT_JSON" \
      --name "$name" \
      --status "$stage_status" \
      --duration-ms "$duration_ms" \
      --exit-code "$exit_code_arg"
  else
    python3 "$REPORT_SCRIPT" record \
      --output "$REPORT_JSON" \
      --name "$name" \
      --status "$stage_status" \
      --duration-ms "$duration_ms"
  fi
}

run_stage() {
  local name="$1"
  local detail_json="$2"
  shift 2
  STAGE_INDEX+=1
  local safe_name="${name//[^A-Za-z0-9_-]/_}"
  local log_path="$RUN_DIR/$(printf '%02d' "$STAGE_INDEX")-$safe_name.log"
  local started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local started_ms="$(monotonic_milliseconds)"
  print "[check] 階段 $name：開始"
  local exit_code=0
  if "$@" >"$log_path" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi
  local duration_ms=$(( $(monotonic_milliseconds) - started_ms ))
  cat "$log_path"

  local stage_status="fail"
  if (( exit_code == 0 )); then
    stage_status="pass"
  fi
  if [[ -n "$detail_json" && -f "$detail_json" ]]; then
    local detail_status=""
    if detail_status="$(python3 "$REPORT_SCRIPT" status --input "$detail_json" 2>/dev/null)"; then
      stage_status="$detail_status"
    fi
  fi

  if [[ -n "$detail_json" ]]; then
    python3 "$REPORT_SCRIPT" record \
      --output "$REPORT_JSON" \
      --name "$name" \
      --status "$stage_status" \
      --duration-ms "$duration_ms" \
      --exit-code "$exit_code" \
      --started-at "$started_at" \
      --log "$log_path" \
      --detail-json "$detail_json"
  else
    python3 "$REPORT_SCRIPT" record \
      --output "$REPORT_JSON" \
      --name "$name" \
      --status "$stage_status" \
      --duration-ms "$duration_ms" \
      --exit-code "$exit_code" \
      --started-at "$started_at" \
      --log "$log_path"
  fi
  print "[check] 階段 $name：$stage_status，耗時 ${duration_ms} ms，exit code=$exit_code"

  LAST_STAGE_EXIT=$exit_code
  LAST_STAGE_STATUS="$stage_status"
  if (( exit_code != 0 && OVERALL_EXIT == 0 )); then
    OVERALL_EXIT=$exit_code
  fi
}

run_stage "編譯前差異檢查" "" git -C "$WORKSPACE_ROOT" diff --check
run_stage "建置" "" zsh "$ROOT/build.sh" "${BUILD_ARGS[@]}"
BUILD_EXIT=$LAST_STAGE_EXIT

if (( BUILD_EXIT == 0 )) && [[ -x "$APP_BIN" ]]; then
  run_stage "ranker-status smoke" "" "$APP_BIN" ranker-status
  run_stage "A 符號修飾鍵純邏輯 probe" "" "$APP_BIN" symbol-shortcut-probe
else
  record_manual_stage "ranker-status smoke" "unresolved"
  record_manual_stage "A 符號修飾鍵純邏輯 probe" "unresolved"
fi

run_stage "B 使用者詞頻獨立測試" "$B_REPORT_JSON" zsh "$ROOT/scripts/run_user_frequency_store_selftest.command" "$B_REPORT_JSON"

if (( BUILD_EXIT == 0 )) && [[ -x "$APP_BIN" ]]; then
  if (( RUN_SELFTEST == 1 )); then
    run_stage "continuous mixed-input smoke" "" python3 "$ROOT/scripts/mixed_live_smoke.py"
    run_stage "raw selftest" "$RAW_REPORT_JSON" env \
      UNIFYIME_TEST_RUN_ID="$RUN_ID" \
      UNIFYIME_RAW_SELFTEST_REPORT="$RAW_REPORT_JSON" \
      python3 "$ROOT/scripts/raw_selftest.py"
  else
    record_manual_stage "continuous mixed-input smoke" "skip"
    record_manual_stage "raw selftest" "skip"
  fi
else
  record_manual_stage "continuous mixed-input smoke" "unresolved"
  record_manual_stage "raw selftest" "unresolved"
fi

HOST_REPORT_JSON="$RUN_DIR/native-imk-host.json"
HOST_TRACE_PATH="$RUN_DIR/native-imk-runtime.log"
if (( RUN_NATIVE_IMK == 1 )) && (( BUILD_EXIT == 0 )) && [[ -x "$APP_BIN" ]] && [[ " ${BUILD_ARGS[*]} " =~ " --deploy " ]]; then
  run_stage "native IMK AppKit host smoke" "$HOST_REPORT_JSON" env \
    UNIFYIME_WORKSPACE_ROOT="$WORKSPACE_ROOT" \
    UNIFYIME_RUNTIME_TRACE_ENABLED=1 \
    UNIFYIME_RUNTIME_TRACE="$HOST_TRACE_PATH" \
    zsh "$ROOT/scripts/run_native_imk_host_smoke.command" \
    "$HOST_REPORT_JSON" "$HOST_TRACE_PATH" "$HOME/Library/Input Methods/全一輸入法.app"
elif (( RUN_NATIVE_IMK == 0 )); then
  record_manual_stage "native IMK AppKit host smoke" "skip"
else
  record_manual_stage "native IMK AppKit host smoke" "unresolved"
fi

record_manual_stage "CotEditor/TextEdit manual acceptance" "unresolved"

python3 "$REPORT_SCRIPT" finalize \
  --output "$REPORT_JSON" \
  --markdown "$REPORT_MARKDOWN" \
  --check-exit-code "$OVERALL_EXIT"

print "[check] 完成：exit code=$OVERALL_EXIT"
exit "$OVERALL_EXIT"
