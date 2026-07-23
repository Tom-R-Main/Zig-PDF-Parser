#!/usr/bin/env python3
"""Absolute quality gate for raster-only financial forms."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


TOKEN_PATTERN = re.compile(r"[A-Z0-9]+(?:[./-][A-Z0-9]+)*", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parser", default="zig-out/bin/pdf-parser")
    parser.add_argument(
        "--pdf",
        default="benchmark/eval/corpus/scanned_financial_forms/expenditure-form.pdf",
    )
    parser.add_argument(
        "--truth",
        default="benchmark/eval/ground_truth/ocr_forms/scanned_financial_forms/expenditure-form.json",
    )
    parser.add_argument("--output")
    return parser.parse_args()


def read_artifacts(parser_path: Path, pdf_path: Path) -> list[dict[str, Any]]:
    completed = subprocess.run(
        [
            str(parser_path),
            "extract-adaptive",
            "--input",
            str(pdf_path),
            "--source-id",
            "ocr-form-quality",
            "--format",
            "artifact-jsonl",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        diagnostic = completed.stderr.strip()[-4096:]
        raise RuntimeError(
            f"pdf-parser failed with exit {completed.returncode}: {diagnostic or 'no stderr'}"
        )
    return [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]


def token_recall(expected: str, actual: str) -> float:
    expected_tokens = Counter(token.upper() for token in TOKEN_PATTERN.findall(expected))
    if not expected_tokens:
        return 1.0
    actual_tokens = Counter(token.upper() for token in TOKEN_PATTERN.findall(actual))
    matched = sum(min(count, actual_tokens[token]) for token, count in expected_tokens.items())
    return matched / sum(expected_tokens.values())


def exact_recall(expected: list[str], actual: list[str]) -> float:
    if not expected:
        return 1.0
    remaining = Counter(value.strip().upper() for value in actual)
    matched = 0
    for value in expected:
        key = value.strip().upper()
        if remaining[key] > 0:
            remaining[key] -= 1
            matched += 1
    return matched / len(expected)


def table_rows(artifacts: list[dict[str, Any]]) -> list[list[str]]:
    tables = [record for record in artifacts if record.get("record_type") == "table"]
    if not tables:
        return []
    values = [
        [
            str(cell.get("normalized_text") or cell.get("text") or "").strip()
            for cell in row.get("cells", [])
        ]
        for row in tables[0].get("rows", [])
    ]
    if values and [value.upper() for value in values[0][:3]] == ["DATE", "VENDOR", "AMOUNT"]:
        return values[1:]
    return values


def evaluate(artifacts: list[dict[str, Any]], truth: dict[str, Any]) -> dict[str, Any]:
    manifests = [record for record in artifacts if record.get("record_type") == "document_manifest"]
    if len(manifests) != 1:
        raise ValueError(f"expected one document_manifest, got {len(manifests)}")
    manifest = manifests[0]
    if manifest.get("has_specialist_failures"):
        raise ValueError("document manifest reports specialist failures")

    expected_rows = truth["rows"]
    actual_rows = table_rows(artifacts)
    expected_dates = [str(row["date"]) for row in expected_rows]
    expected_vendors = [str(row["vendor"]) for row in expected_rows]
    expected_amounts = [str(row["amount"]) for row in expected_rows]
    actual_dates = [row[0] for row in actual_rows if len(row) >= 3]
    actual_vendors = [row[1] for row in actual_rows if len(row) >= 3]
    actual_amounts = [row[2] for row in actual_rows if len(row) >= 3]

    span_text = "\n".join(
        str(record.get("text", ""))
        for record in artifacts
        if record.get("record_type") == "span"
    )
    expected_total = str(truth["total"])
    metrics = {
        "token_recall": token_recall(str(truth["text"]), span_text),
        "row_count_exact": 1.0 if len(actual_rows) == len(expected_rows) else 0.0,
        "date_exact_recall": exact_recall(expected_dates, actual_dates),
        "vendor_exact_recall": exact_recall(expected_vendors, actual_vendors),
        "amount_exact_recall": exact_recall(expected_amounts, actual_amounts),
        "total_exact_match": 1.0 if expected_total in span_text.split() else 0.0,
    }
    metrics["numeric_exact_match"] = (
        metrics["amount_exact_recall"] * len(expected_amounts)
        + metrics["total_exact_match"]
    ) / (len(expected_amounts) + 1)

    floors = truth["floors"]
    failures = [
        {"metric": metric, "actual": metrics.get(metric), "floor": floor}
        for metric, floor in floors.items()
        if metrics.get(metric) is None or metrics[metric] < float(floor)
    ]
    attempts = [
        {
            "attempt_id": record.get("attempt_id"),
            "status": record.get("attempt_status"),
            "selected": record.get("selected"),
            "config": record.get("config"),
            "quality": record.get("quality"),
        }
        for record in artifacts
        if record.get("record_type") == "specialist_attempt"
    ]
    return {
        "benchmark_schema_version": "0.2.0",
        "record_type": "ocr_form_quality",
        "doc_id": truth["doc_id"],
        "status": "pass" if not failures else "fail",
        "metrics": metrics,
        "floors": floors,
        "failures": failures,
        "expected_row_count": len(expected_rows),
        "actual_row_count": len(actual_rows),
        "attempts": attempts,
    }


def main() -> int:
    args = parse_args()
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    try:
        report = evaluate(read_artifacts(Path(args.parser), Path(args.pdf)), truth)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"OCR form quality gate failed to run: {error}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
