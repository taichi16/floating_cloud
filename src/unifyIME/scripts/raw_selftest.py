import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def resolve_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_root()
APP = Path(os.environ.get("UNIFYIME_CLI_PATH", str(ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME")))
CASE_FILE = ROOT / "src" / "unifyIME" / "tests" / "regression_cases.jsonl"
PROBE_BATCH_COMMANDS = {
    "zh": "zh-build-raw-input-batch",
    "en": "en-build-raw-input-batch",
    "mix": "build-raw-input-batch",
}
ACTION_BATCH_COMMANDS = {
    "zh": "zh-ime-action-batch-replay",
    "en": "en-ime-action-batch-replay",
    "mix": "ime-action-batch-replay",
}
SUBPROCESS_TIMEOUT_SECONDS = 180


def move_test_artifact_to_trash(path: Path) -> None:
    if not path.exists():
        return
    trash = Path.home() / ".Trash"
    trash.mkdir(parents=True, exist_ok=True)
    destination = trash / path.name
    suffix = 0
    while destination.exists():
        suffix += 1
        destination = trash / f"{path.name}.unifyime-{os.getpid()}-{suffix}"
    path.replace(destination)
    print(f"[raw selftest] 測試目錄已移至 Trash：{destination}", flush=True)


def load_cases() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with CASE_FILE.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            rows.append({
                "category": str(payload["category"]),
                "sentence": str(payload["sentence"]),
            })
    return rows


def run(cmd: list[str]) -> tuple[subprocess.CompletedProcess[str] | None, bool]:
    started = time.monotonic()
    try:
        result = subprocess.run(cmd, text=True, capture_output=True, timeout=SUBPROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return None, True
    elapsed = time.monotonic() - started
    signal_timeout = result.returncode in {-signal.SIGTERM, -signal.SIGKILL} and elapsed >= SUBPROCESS_TIMEOUT_SECONDS - 10
    return result, signal_timeout


def final_text_from_probe_output(output: str) -> str:
    blocks = re.findall(r"=== IME ACTION STEP .*?===\n(.*?)\n=== END IME ACTION STEP .*?===", output, re.S)
    final_block = blocks[-1] if blocks else ""
    match = re.search(r"文字：\n(.*?)\n\n讀音佇列：", final_block, re.S)
    if not match:
        return ""
    return match.group(1).replace("❚", "").strip()


def write_report(path: Path | None, report: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary_path, path)


def main() -> int:
    report_argument = None
    if "--report-json" in sys.argv:
        report_index = sys.argv.index("--report-json")
        if report_index + 1 < len(sys.argv):
            report_argument = Path(sys.argv[report_index + 1])

    run_id = os.environ.get("UNIFYIME_TEST_RUN_ID") or f"raw-{uuid.uuid4().hex}"
    started_at = time.time()
    started_monotonic = time.monotonic()
    cases = load_cases()
    failures: list[tuple[int, str, str, str, str]] = []
    skipped: list[tuple[int, str, str]] = []
    category_totals: dict[str, int] = {}
    category_passes: dict[str, int] = {}
    category_reports: list[dict[str, object]] = []
    for case in cases:
        category = case["category"]
        category_totals[category] = category_totals.get(category, 0) + 1
    cases_by_category: dict[str, list[tuple[int, str]]] = {}
    for idx, case in enumerate(cases, 1):
        cases_by_category.setdefault(case["category"], []).append((idx, case["sentence"]))

    print(f"[raw selftest] run_id={run_id} 案例總數={len(cases)}", flush=True)
    for category, entries in cases_by_category.items():
        probe_cmd = PROBE_BATCH_COMMANDS[category]
        action_cmd = ACTION_BATCH_COMMANDS[category]
        category_started = time.monotonic()
        category_status = "pass"
        probe_exit_code: int | None = None
        action_exit_code: int | None = None
        category_failed_before_action = 0
        print(f"[raw selftest] 分類 {category} 開始：{len(entries)} 筆", flush=True)
        temporary_root = Path(tempfile.mkdtemp(prefix=f"unifyime-raw-selftest-{run_id}-{category}-"))
        try:
            probe_input_path = temporary_root / "probe-input.txt"
            probe_input_path.write_text("\n".join(sentence for _, sentence in entries) + "\n", encoding="utf-8")

            print(f"[raw selftest] 階段 {category}/probe 開始", flush=True)
            try:
                probe, probe_timed_out = run([str(APP), probe_cmd, str(probe_input_path)])
                probe_exit_code = probe.returncode if probe is not None else None
            except OSError as error:
                probe = None
                probe_timed_out = False
                probe_exit_code = None
                category_status = "fail"
                for idx, sentence in entries:
                    failures.append((idx, category, sentence, f"{probe_cmd} failed", str(error)))
                print(f"[raw selftest] 階段 {category}/probe：fail（{error}）", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(entries),
                    "skip": 0,
                    "probe_exit_code": probe_exit_code,
                    "action_exit_code": None,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            if probe_timed_out:
                category_status = "timeout"
                for idx, sentence in entries:
                    failures.append((idx, category, sentence, f"{probe_cmd} timeout", ""))
                print(f"[raw selftest] 階段 {category}/probe：timeout", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(entries),
                    "skip": 0,
                    "probe_exit_code": None,
                    "action_exit_code": None,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            if probe.returncode != 0:
                category_status = "fail"
                detail = (probe.stdout + probe.stderr).strip()
                for idx, sentence in entries:
                    failures.append((idx, category, sentence, f"{probe_cmd} failed", detail))
                print(f"[raw selftest] 階段 {category}/probe：fail exit_code={probe.returncode}", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(entries),
                    "skip": 0,
                    "probe_exit_code": probe.returncode,
                    "action_exit_code": None,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue
            print(f"[raw selftest] 階段 {category}/probe：pass exit_code={probe.returncode}", flush=True)

            probe_lines = [line for line in probe.stdout.splitlines() if line.strip()]
            batch_rows: list[dict[str, object]] = []
            resolved_cases: dict[str, tuple[int, str, str]] = {}

            for line_index, (idx, sentence) in enumerate(entries):
                if line_index >= len(probe_lines):
                    failures.append((idx, category, sentence, f"missing {probe_cmd} row", ""))
                    category_failed_before_action += 1
                    continue
                try:
                    payload = json.loads(probe_lines[line_index])
                except json.JSONDecodeError:
                    failures.append((idx, category, sentence, f"invalid {probe_cmd} json", probe_lines[line_index]))
                    category_failed_before_action += 1
                    continue
                if not payload.get("resolved"):
                    skipped.append((idx, category, sentence))
                    continue

                row_keys = payload.get("row_keys")
                key_tokens = payload.get("key_tokens")
                key_sequence = payload.get("key_sequence", "")
                if isinstance(row_keys, list) and row_keys:
                    tokens = list(row_keys)
                elif key_sequence:
                    tokens = [f"raw:{ch}" for ch in key_sequence if ch != " "] + ["enter"]
                elif isinstance(key_tokens, list) and key_tokens:
                    tokens = [f"raw:{token}" for token in key_tokens] + ["enter"]
                else:
                    failures.append((idx, category, sentence, "empty key_sequence", probe.stdout.strip()))
                    category_failed_before_action += 1
                    continue

                row_id = f"{category}-case-{idx}"
                batch_rows.append({
                    "row_id": row_id,
                    "row_keys": tokens,
                })
                resolved_cases[row_id] = (idx, sentence, key_sequence)

            if not batch_rows:
                if category_failed_before_action:
                    category_status = "fail"
                else:
                    category_status = "skip"
                print(f"[raw selftest] 分類 {category}：{category_status}，沒有可執行的 action 案例", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": category_failed_before_action,
                    "skip": sum(1 for _, cat, _ in skipped if cat == category),
                    "probe_exit_code": probe_exit_code,
                    "action_exit_code": None,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            batch_path = temporary_root / "action-batch.jsonl"
            batch_path.write_text(
                "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in batch_rows),
                encoding="utf-8",
            )

            print(f"[raw selftest] 階段 {category}/action 開始：{len(batch_rows)} 筆", flush=True)
            try:
                result, action_timed_out = run([str(APP), action_cmd, str(batch_path)])
                action_exit_code = result.returncode if result is not None else None
            except OSError as error:
                result = None
                action_timed_out = False
                action_exit_code = None
                category_status = "fail"
                for _, (idx, sentence, key_sequence) in resolved_cases.items():
                    failures.append((idx, category, sentence, f"{action_cmd} failed", str(error)))
                print(f"[raw selftest] 階段 {category}/action：fail（{error}）", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(resolved_cases) + category_failed_before_action,
                    "skip": sum(1 for _, cat, _ in skipped if cat == category),
                    "probe_exit_code": probe_exit_code,
                    "action_exit_code": action_exit_code,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            if action_timed_out:
                category_status = "timeout"
                for _, (idx, sentence, key_sequence) in resolved_cases.items():
                    failures.append((idx, category, sentence, f"{action_cmd} timeout", key_sequence))
                print(f"[raw selftest] 階段 {category}/action：timeout", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(resolved_cases) + category_failed_before_action,
                    "skip": sum(1 for _, cat, _ in skipped if cat == category),
                    "probe_exit_code": probe_exit_code,
                    "action_exit_code": action_exit_code,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            if result.returncode != 0:
                category_status = "fail"
                detail = (result.stdout + result.stderr).strip()
                for _, (idx, sentence, key_sequence) in resolved_cases.items():
                    failures.append((idx, category, sentence, f"{action_cmd} failed", detail))
                print(f"[raw selftest] 階段 {category}/action：fail exit_code={result.returncode}", flush=True)
                category_reports.append({
                    "category": category,
                    "status": category_status,
                    "total": len(entries),
                    "pass": 0,
                    "fail": len(resolved_cases) + category_failed_before_action,
                    "skip": sum(1 for _, cat, _ in skipped if cat == category),
                    "probe_exit_code": probe_exit_code,
                    "action_exit_code": result.returncode,
                    "duration_ms": int((time.monotonic() - category_started) * 1000),
                })
                continue

            print(f"[raw selftest] 階段 {category}/action：pass exit_code={result.returncode}", flush=True)
            outputs: dict[str, dict[str, object]] = {}
            for line in result.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                row_id = str(payload.get("row_id", ""))
                if row_id:
                    outputs[row_id] = payload

            for row_id, (idx, sentence, key_sequence) in resolved_cases.items():
                payload = outputs.get(row_id)
                if not payload:
                    failures.append((idx, category, sentence, "missing batch result", key_sequence))
                    continue
                if payload.get("error"):
                    failures.append((idx, category, sentence, str(payload["error"]), key_sequence))
                    continue
                actual = str(payload.get("text", "")).replace("❚", "").strip()
                if actual != sentence:
                    failures.append((idx, category, sentence, actual, key_sequence))
                    continue
                category_passes[category] = category_passes.get(category, 0) + 1

            category_failed = sum(1 for _, cat, _, _, _ in failures if cat == category)
            category_skipped = sum(1 for _, cat, _ in skipped if cat == category)
            if category_failed:
                category_status = "fail"
            elif category_skipped:
                category_status = "skip"
            else:
                category_status = "pass"
            print(
                f"[raw selftest] 分類 {category}：{category_status} "
                f"pass={category_passes.get(category, 0)} fail={category_failed} skip={category_skipped}",
                flush=True,
            )
            category_reports.append({
                "category": category,
                "status": category_status,
                "total": len(entries),
                "pass": category_passes.get(category, 0),
                "fail": category_failed,
                "skip": category_skipped,
                "probe_exit_code": probe_exit_code,
                "action_exit_code": action_exit_code,
                "duration_ms": int((time.monotonic() - category_started) * 1000),
            })
        finally:
            move_test_artifact_to_trash(temporary_root)

    total_passes = sum(category_passes.values())
    print(f"TOTAL {len(cases)}")
    print(f"PASS {total_passes}")
    print(f"FAIL {len(failures)}")
    print(f"SKIP_UNRESOLVED {len(skipped)}")
    for category in sorted(category_totals):
        total = category_totals[category]
        passed = category_passes.get(category, 0)
        skipped_count = sum(1 for _, cat, _ in skipped if cat == category)
        failed = sum(1 for _, cat, _, _, _ in failures if cat == category)
        category_status = next((item["status"] for item in category_reports if item["category"] == category), "unresolved")
        print(f"CATEGORY {category}: status={category_status} total={total} pass={passed} fail={failed} skip={skipped_count}")
    for idx, category, expected, actual, extra in failures:
        print("---")
        print(f"CASE {idx}")
        print(f"CATEGORY: {category}")
        print(f"EXPECTED: {expected}")
        print(f"ACTUAL:   {actual}")
        print(f"EXTRA:    {extra}")
    for idx, category, sentence in skipped:
        print("---")
        print(f"CASE {idx}")
        print(f"CATEGORY: {category}")
        print(f"SKIPPED:  unresolved reverse path")
        print(f"TARGET:   {sentence}")

    exit_code = 0 if not failures and not skipped else 2
    if any(item["status"] == "timeout" for item in category_reports):
        overall_status = "timeout"
    elif failures:
        overall_status = "fail"
    elif skipped:
        overall_status = "skip"
    else:
        overall_status = "pass"
    report_path = report_argument
    if report_path is None:
        environment_report = os.environ.get("UNIFYIME_RAW_SELFTEST_REPORT")
        if environment_report:
            report_path = Path(environment_report)
    write_report(report_path, {
        "run_id": run_id,
        "status": overall_status,
        "exit_code": exit_code,
        "started_at_epoch": started_at,
        "finished_at_epoch": time.time(),
        "duration_ms": int((time.monotonic() - started_monotonic) * 1000),
        "total": len(cases),
        "pass": total_passes,
        "fail": len(failures),
        "skip": len(skipped),
        "categories": category_reports,
    })
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
