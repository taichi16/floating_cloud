#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import uuid
from datetime import datetime, timezone
from pathlib import Path


STATUSES = {"pass", "fail", "skip", "timeout", "unresolved"}
PENDING_ONLY_STAGES = {
    "native IMK AppKit host smoke",
    "CotEditor/TextEdit manual acceptance",
}


def now_iso8601() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def atomic_write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary_path, path)


def load_json(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"報告不是 JSON object：{path}")
    return payload


def relative_path(path: Path, base: Path) -> str:
    try:
        return os.path.relpath(path, base)
    except ValueError:
        return str(path)


def stage_diagnosis(stage: dict[str, object]) -> str:
    details = stage.get("details")
    if not isinstance(details, dict):
        return ""
    diagnosis = details.get("diagnosis")
    if not isinstance(diagnosis, dict):
        return ""
    failure_class = str(diagnosis.get("failure_class", "unknown"))
    execution_status = str(diagnosis.get("execution_status", "unknown"))
    reason_code = str(diagnosis.get("reason_code", "unknown"))
    return f"{failure_class} / {execution_status} / {reason_code}"


def fixture_digest(paths: list[Path], workspace_root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda item: str(item)):
        display = relative_path(path, workspace_root)
        digest.update(display.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def command_init(args: argparse.Namespace) -> int:
    workspace_root = Path(args.workspace_root).resolve()
    fixture_paths = [Path(item).resolve() for item in args.fixture_file]
    for path in fixture_paths:
        if not path.is_file():
            raise FileNotFoundError(f"找不到測試 fixture：{path}")
    payload: dict[str, object] = {
        "schema_version": 1,
        "run_id": args.run_id,
        "started_at": args.started_at or now_iso8601(),
        "finished_at": None,
        "git_sha": args.git_sha,
        "platform": args.platform or platform.platform(),
        "build_mode": args.build_mode,
        "fixture_hash": fixture_digest(fixture_paths, workspace_root),
        "fixture_files": [relative_path(path, workspace_root) for path in fixture_paths],
        "known_findings": [],
        "lifecycle_flush_hooks": [
            "SessionCtl.deactivateServer",
            "IMEApplicationDelegate.applicationWillTerminate",
        ],
        "manual_acceptance": [
            "CotEditor",
            "TextEdit",
        ],
        "stages": [],
        "check_exit_code": None,
        "status": "running",
    }
    atomic_write_json(Path(args.output).resolve(), payload)
    print(f"測試報告已初始化：{args.output}")
    return 0


def command_record(args: argparse.Namespace) -> int:
    output_path = Path(args.output).resolve()
    payload = load_json(output_path)
    if args.status not in STATUSES:
        raise ValueError(f"未知測試狀態：{args.status}")
    entry: dict[str, object] = {
        "name": args.name,
        "status": args.status,
        "started_at": args.started_at or now_iso8601(),
        "finished_at": now_iso8601(),
        "duration_ms": args.duration_ms,
        "exit_code": args.exit_code,
    }
    if args.log:
        entry["log"] = relative_path(Path(args.log).resolve(), output_path.parent)
    if args.detail_json:
        detail_path = Path(args.detail_json).resolve()
        try:
            entry["details"] = load_json(detail_path)
        except Exception as error:
            entry["details"] = {"detail_read_error": str(error)}
    stages = payload.setdefault("stages", [])
    if not isinstance(stages, list):
        raise ValueError("報告 stages 欄位格式錯誤")
    stages.append(entry)
    atomic_write_json(output_path, payload)
    return 0


def command_status(args: argparse.Namespace) -> int:
    payload = load_json(Path(args.input).resolve())
    status = payload.get("status")
    if status not in STATUSES and status not in {"running", "pass_with_pending"}:
        status = "unresolved"
    print(status)
    return 0


def resolved_overall_status(stages: list[object]) -> str:
    statuses = {stage.get("status") for stage in stages if isinstance(stage, dict)}
    if "fail" in statuses:
        return "fail"
    if "timeout" in statuses:
        return "timeout"
    if "unresolved" in statuses:
        return "unresolved"
    if "skip" in statuses:
        return "skip"
    return "pass"


def has_only_external_pending(stages: list[object]) -> bool:
    unresolved = {
        stage.get("name")
        for stage in stages
        if isinstance(stage, dict) and stage.get("status") == "unresolved"
    }
    return bool(unresolved) and unresolved.issubset(PENDING_ONLY_STAGES)


def markdown_report(payload: dict[str, object]) -> str:
    lines = [
        "# UnifyIME 測試報告",
        "",
        f"- run id：`{payload.get('run_id', '')}`",
        f"- 開始時間：`{payload.get('started_at', '')}`",
        f"- 結束時間：`{payload.get('finished_at', '')}`",
        f"- git SHA：`{payload.get('git_sha', '')}`",
        f"- 平台：`{payload.get('platform', '')}`",
        f"- 建置模式：`{payload.get('build_mode', '')}`",
        f"- fixture hash：`{payload.get('fixture_hash', '')}`",
        f"- check exit code：`{payload.get('check_exit_code', '')}`",
        f"- 報告狀態：`{payload.get('status', '')}`",
        "",
        "## 階段結果",
        "",
        "| 階段 | 狀態 | 診斷 | 耗時（ms） | exit code | log |",
        "| --- | --- | --- | ---: | ---: | --- |",
    ]
    stages = payload.get("stages", [])
    if isinstance(stages, list):
        for stage in stages:
            if not isinstance(stage, dict):
                continue
            log = stage.get("log", "")
            lines.append(
                f"| {stage.get('name', '')} | {stage.get('status', '')} | "
                f"{stage_diagnosis(stage)} | {stage.get('duration_ms', '')} | "
                f"{stage.get('exit_code', '')} | {log} |"
            )
    lines.extend([
        "",
        "## Fixture",
        "",
    ])
    fixture_files = payload.get("fixture_files", [])
    if isinstance(fixture_files, list):
        for fixture in fixture_files:
            lines.append(f"- `{fixture}`")
    lines.extend([
        "",
        "## 已知待決事項",
        "",
    ])
    findings = payload.get("known_findings", [])
    if isinstance(findings, list):
        for finding in findings:
            if not isinstance(finding, dict):
                continue
            lines.append(
                f"- [{finding.get('status', 'unresolved')}] {finding.get('summary', '')}"
            )
            action = finding.get("action")
            if action:
                lines.append(f"  - 處置：{action}")
            evidence = finding.get("evidence", [])
            if isinstance(evidence, list):
                for item in evidence:
                    lines.append(f"  - 證據：`{item}`")
    lines.extend([
        "",
        "## 驗收邊界",
        "",
        "- `native IMK AppKit host smoke` 使用真正的 `NSTextView` 與 `NSApplication` event loop 驗證 SessionCtl 的 IMK client、marked text 與 commit 鏈。",
        "- CotEditor 與 TextEdit 不由此 smoke 取代，仍保留為 `manual unresolved`；其實際應用程式驗證尚未宣告完成。",
        "- native smoke 若前景 App／current `NSTextInputContext`／input source 前置條件未成立，會以 `unresolved` 加上 `execution_status=NOT_RUN` 記錄，不得解讀為產品輸入行為失敗。",
        "- native smoke 診斷分類為 `precondition_not_met`、`host_harness_failure` 或 `product_behavior_failure`；分類依已觀察證據，不以猜測補足。",
        "- 使用者詞頻在 `SessionCtl.deactivateServer` 與正式 IME 程式終止接點呼叫 `flushNow`。",
        "- `unresolved` 代表尚未執行或需要人工／原生 IMK 驗證，不得視為通過。",
        "- `pass_with_pending` 代表所有自動化階段通過，但僅剩列明的原生／人工驗收待補；它不是核心測試失敗。",
        "- `timeout` 與 `fail` 保留原始退出語意，不以放寬門檻或跳過案例消除。",
        "",
    ])
    return "\n".join(lines)


def command_finalize(args: argparse.Namespace) -> int:
    output_path = Path(args.output).resolve()
    payload = load_json(output_path)
    stages = payload.get("stages", [])
    payload["finished_at"] = now_iso8601()
    stage_list = stages if isinstance(stages, list) else []
    status = resolved_overall_status(stage_list)
    if (
        status == "unresolved"
        and args.check_exit_code == 0
        and has_only_external_pending(stage_list)
    ):
        status = "pass_with_pending"
    payload["status"] = status
    payload["check_exit_code"] = args.check_exit_code
    atomic_write_json(output_path, payload)
    markdown_path = Path(args.markdown).resolve()
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.write_text(markdown_report(payload), encoding="utf-8")
    print(f"JSON 報告：{output_path}")
    print(f"Markdown 報告：{markdown_path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="建立 UnifyIME 統一測試報告")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init = subparsers.add_parser("init")
    init.add_argument("--output", required=True)
    init.add_argument("--run-id", required=True)
    init.add_argument("--workspace-root", required=True)
    init.add_argument("--git-sha", required=True)
    init.add_argument("--platform", required=True)
    init.add_argument("--build-mode", required=True)
    init.add_argument("--started-at")
    init.add_argument("--fixture-file", action="append", required=True)
    init.set_defaults(handler=command_init)

    record = subparsers.add_parser("record")
    record.add_argument("--output", required=True)
    record.add_argument("--name", required=True)
    record.add_argument("--status", required=True, choices=sorted(STATUSES))
    record.add_argument("--duration-ms", required=True, type=int)
    record.add_argument("--exit-code", type=int)
    record.add_argument("--started-at")
    record.add_argument("--log")
    record.add_argument("--detail-json")
    record.set_defaults(handler=command_record)

    status = subparsers.add_parser("status")
    status.add_argument("--input", required=True)
    status.set_defaults(handler=command_status)

    finalize = subparsers.add_parser("finalize")
    finalize.add_argument("--output", required=True)
    finalize.add_argument("--markdown", required=True)
    finalize.add_argument("--check-exit-code", required=True, type=int)
    finalize.set_defaults(handler=command_finalize)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
