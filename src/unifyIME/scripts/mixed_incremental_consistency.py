#!/usr/bin/env python3
"""Compare mixed incremental output with and without the local span cache."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from mixed_live_smoke import CASES, INCREMENTAL_LONG_CASES


ROOT = Path(__file__).resolve().parents[3]
APP = Path(
    os.environ.get(
        "UNIFYIME_CLI_PATH",
        str(ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"),
    )
)
TIMEOUT_SECONDS = 120
CONTROL_CASES = [
    ("control-candidate-confirm", ["raw:ji3", "choose:1", "enter"]),
    ("control-cursor-edit", ["raw:ji3", "enter", "left", "raw:wu0fu4", "enter"]),
    ("control-middle-delete", ["raw:ji3wu0fu4", "enter", "left", "delete:1", "enter"]),
    ("control-middle-retype", ["raw:ji3wu0fu4", "enter", "left", "backspace:1", "raw:wu0fu4", "enter"]),
]


def build_rows() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for case_id, raw, _expected, should_commit in CASES:
        if case_id == "delete-short":
            raw_keys = [f"raw:{raw}", "enter", "backspace:1", "raw:gjbj4"]
        elif case_id == "delete-medium":
            raw_keys = [f"raw:{raw}", "enter", "backspace:2", "raw:hk4g4"]
        elif case_id == "delete-long-mixed":
            raw_keys = [f"raw:{raw}", "enter", "backspace:2", "raw:tj/6vupgjbj4"]
        else:
            is_incremental = not case_id.startswith("long-") or case_id in INCREMENTAL_LONG_CASES
            raw_keys = [f"raw:{character}" for character in raw] if is_incremental else [f"raw:{raw}"]
        rows.append({"row_id": case_id, "row_keys": raw_keys + (["enter"] if should_commit else [])})
    rows.extend({"row_id": case_id, "row_keys": keys} for case_id, keys in CONTROL_CASES)
    return rows


def write_input(rows: list[dict[str, object]]) -> Path:
    handle = tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".jsonl", delete=False)
    path = Path(handle.name)
    try:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    finally:
        handle.close()
    return path


def parse_outputs(stdout: str) -> dict[str, dict[str, object]]:
    outputs: dict[str, dict[str, object]] = {}
    for line in stdout.splitlines():
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        row_id = str(payload.get("row_id", ""))
        if row_id:
            outputs[row_id] = payload
    return outputs


def parse_profile_summary(stderr: str) -> dict[str, object] | None:
    marker = "runtime-profile-summary "
    for line in reversed(stderr.splitlines()):
        if line.startswith(marker):
            try:
                return json.loads(line[len(marker) :])
            except json.JSONDecodeError:
                return None
    return None


def run_variant(input_path: Path, disabled: bool) -> dict[str, object]:
    environment = os.environ.copy()
    environment["UNIFYIME_PROFILE"] = "1"
    environment["UNIFYIME_PROFILE_SUMMARY"] = "1"
    if disabled:
        environment["UNIFYIME_DISABLE_INCREMENTAL_MIXED_CACHE"] = "1"
    else:
        environment.pop("UNIFYIME_DISABLE_INCREMENTAL_MIXED_CACHE", None)
    started = time.perf_counter()
    result = subprocess.run(
        [str(APP), "ime-action-batch-replay", str(input_path)],
        text=True,
        capture_output=True,
        timeout=TIMEOUT_SECONDS,
        env=environment,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return {
        "returncode": result.returncode,
        "elapsed_ms": elapsed_ms,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "outputs": parse_outputs(result.stdout),
        "profile": parse_profile_summary(result.stderr),
    }


def normalized_outputs(outputs: dict[str, dict[str, object]]) -> dict[str, dict[str, object]]:
    keys = ("text", "readings", "has_composition", "error")
    return {
        row_id: {key: payload.get(key) for key in keys if key in payload}
        for row_id, payload in sorted(outputs.items())
    }


def metric(summary: dict[str, object] | None, label: str) -> dict[str, object]:
    if not summary:
        return {"samples": 0, "total_ms": 0.0, "average_ms": 0.0, "last_ms": 0.0}
    for item in summary.get("metrics", []):
        if isinstance(item, dict) and item.get("label") == label:
            return item
    return {"samples": 0, "total_ms": 0.0, "average_ms": 0.0, "last_ms": 0.0}


def cache_stats(summary: dict[str, object] | None) -> dict[str, object]:
    if not summary or not isinstance(summary.get("span_cache"), dict):
        return {"entries": 0, "hits": 0, "misses": 0, "reuse": 0, "invalidations": 0}
    return summary["span_cache"]


def main() -> int:
    if not APP.is_file():
        print(f"FAIL app missing: {APP}")
        return 2

    rows = build_rows()
    input_path = write_input(rows)
    try:
        enabled = run_variant(input_path, disabled=False)
        disabled = run_variant(input_path, disabled=True)
    except subprocess.TimeoutExpired as error:
        print(f"FAIL timeout after {TIMEOUT_SECONDS}s: {error}")
        return 2
    finally:
        input_path.unlink(missing_ok=True)

    print(f"enabled exit={enabled['returncode']} elapsed_ms={enabled['elapsed_ms']:.1f}")
    print(f"disabled exit={disabled['returncode']} elapsed_ms={disabled['elapsed_ms']:.1f}")
    if enabled["returncode"] != 0:
        print(enabled["stdout"], end="")
        print(enabled["stderr"], end="")
    if disabled["returncode"] != 0:
        print(disabled["stdout"], end="")
        print(disabled["stderr"], end="")

    expected_ids = {str(row["row_id"]) for row in rows}
    enabled_ids = set(enabled["outputs"])
    disabled_ids = set(disabled["outputs"])
    consistency_pass = (
        enabled["returncode"] == 0
        and disabled["returncode"] == 0
        and enabled_ids == expected_ids
        and disabled_ids == expected_ids
        and normalized_outputs(enabled["outputs"]) == normalized_outputs(disabled["outputs"])
    )
    print(f"output_consistency={'PASS' if consistency_pass else 'FAIL'} rows={len(rows)}")

    enabled_walk = metric(enabled["profile"], "readingWalker.resolveWalk")
    disabled_walk = metric(disabled["profile"], "readingWalker.resolveWalk")
    enabled_span = metric(enabled["profile"], "unified.mergeSpanCoverages.spanCoverages")
    disabled_span = metric(disabled["profile"], "unified.mergeSpanCoverages.spanCoverages")
    print(
        "readingWalker.resolveWalk "
        f"enabled_samples={enabled_walk['samples']} enabled_total_ms={float(enabled_walk['total_ms']):.1f} "
        f"disabled_samples={disabled_walk['samples']} disabled_total_ms={float(disabled_walk['total_ms']):.1f}"
    )
    print(
        "unified.mergeSpanCoverages.spanCoverages "
        f"enabled_samples={enabled_span['samples']} enabled_total_ms={float(enabled_span['total_ms']):.1f} "
        f"disabled_samples={disabled_span['samples']} disabled_total_ms={float(disabled_span['total_ms']):.1f}"
    )
    print(f"span_cache enabled={json.dumps(cache_stats(enabled['profile']), ensure_ascii=False, sort_keys=True)}")
    print(f"span_cache disabled={json.dumps(cache_stats(disabled['profile']), ensure_ascii=False, sort_keys=True)}")

    performance_pass = (
        int(enabled_walk["samples"]) < int(disabled_walk["samples"])
        and float(enabled_walk["total_ms"]) <= float(disabled_walk["total_ms"])
    )
    print(f"incremental_performance={'PASS' if performance_pass else 'UNRESOLVED'}")
    if not consistency_pass:
        print("enabled outputs:", json.dumps(enabled["outputs"], ensure_ascii=False, sort_keys=True))
        print("disabled outputs:", json.dumps(disabled["outputs"], ensure_ascii=False, sort_keys=True))
    return 0 if consistency_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
