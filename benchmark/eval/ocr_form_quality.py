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
OCR_DATE_PATTERN = re.compile(
    r"(?<![A-Z0-9])O?\d{2}[^A-Z0-9]?\d{2}/\d{4}(?![A-Z0-9])",
    re.IGNORECASE,
)


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
    parser.add_argument("--ocr-executable", default="tesseract")
    parser.add_argument("--ocr-rasterizer", default="pdftoppm")
    parser.add_argument("--expected-ocr-version")
    parser.add_argument("--expected-rasterizer-version")
    return parser.parse_args()


def read_artifacts(
    parser_path: Path,
    pdf_path: Path,
    ocr_executable: str = "tesseract",
    ocr_rasterizer: str = "pdftoppm",
    source_id: str = "ocr-form-quality",
) -> list[dict[str, Any]]:
    completed = subprocess.run(
        [
            str(parser_path),
            "extract-adaptive",
            "--input",
            str(pdf_path),
            "--source-id",
            source_id,
            "--format",
            "artifact-jsonl",
            "--ocr-executable",
            ocr_executable,
            "--ocr-rasterizer",
            ocr_rasterizer,
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
    return token_metrics(expected, actual)["recall"]


def token_metrics(expected: str, actual: str) -> dict[str, float]:
    expected_tokens = Counter(token.upper() for token in semantic_tokens(expected))
    actual_tokens = Counter(token.upper() for token in semantic_tokens(actual))
    matched = sum(min(count, actual_tokens[token]) for token, count in expected_tokens.items())
    expected_count = sum(expected_tokens.values())
    actual_count = sum(actual_tokens.values())
    recall = matched / expected_count if expected_count else 1.0
    precision = matched / actual_count if actual_count else 1.0 if expected_count == 0 else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"recall": recall, "precision": precision, "f1": f1}


def semantic_tokens(value: str) -> list[str]:
    normalized = OCR_DATE_PATTERN.sub(lambda match: normalize_ocr_date(match.group()), value)
    return TOKEN_PATTERN.findall(normalized)


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


def normalize_ocr_date(value: str) -> str:
    """Normalize separator glyph loss while preserving all recognized date digits."""
    digits = re.sub(r"\D", "", value)
    if len(digits) != 8:
        return value.strip()
    month = int(digits[:2])
    day = int(digits[2:4])
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return value.strip()
    return f"{digits[:2]}/{digits[2:4]}/{digits[4:]}"


def normalized_row_tuples(rows: list[list[str]]) -> list[str]:
    return [
        "\x1f".join((normalize_ocr_date(row[0]), row[1].strip(), row[2].strip()))
        for row in rows
        if len(row) >= 3
    ]


def expected_row_tuples(rows: list[dict[str, Any]]) -> list[str]:
    return [
        "\x1f".join((str(row["date"]), str(row["vendor"]).strip(), str(row["amount"])))
        for row in rows
    ]


def tool_version(executable: str, version_arg: str) -> dict[str, str]:
    completed = subprocess.run(
        [executable, version_arg],
        check=False,
        capture_output=True,
        text=True,
    )
    output = "\n".join(part for part in (completed.stdout.strip(), completed.stderr.strip()) if part)
    first_line = next((line.strip() for line in output.splitlines() if line.strip()), "")
    if completed.returncode != 0 or not first_line:
        detail = first_line or f"exit {completed.returncode} with no version output"
        raise RuntimeError(f"could not determine version for {executable}: {detail}")
    return {"executable": executable, "version": first_line}


def collect_toolchain(ocr_executable: str, ocr_rasterizer: str) -> dict[str, dict[str, str]]:
    return {
        "ocr": tool_version(ocr_executable, "--version"),
        "rasterizer": tool_version(ocr_rasterizer, "-v"),
    }


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
    actual_dates = [normalize_ocr_date(row[0]) for row in actual_rows if len(row) >= 3]
    actual_vendors = [row[1] for row in actual_rows if len(row) >= 3]
    actual_amounts = [row[2] for row in actual_rows if len(row) >= 3]
    expected_tuples = expected_row_tuples(expected_rows)
    actual_tuples = normalized_row_tuples(actual_rows)

    span_text = "\n".join(
        str(record.get("text", ""))
        for record in artifacts
        if record.get("record_type") == "span"
    )
    expected_total = str(truth["total"])
    tokens = token_metrics(str(truth["text"]), span_text)
    metrics = {
        "token_recall": tokens["recall"],
        "token_precision": tokens["precision"],
        "token_f1": tokens["f1"],
        "row_count_exact": 1.0 if len(actual_rows) == len(expected_rows) else 0.0,
        "row_tuple_exact_recall": exact_recall(expected_tuples, actual_tuples),
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
        "benchmark_schema_version": "0.3.0",
        "record_type": "ocr_form_quality",
        "doc_id": truth["doc_id"],
        "status": "pass" if not failures else "fail",
        "metrics": metrics,
        "floors": floors,
        "failures": failures,
        "expected_row_count": len(expected_rows),
        "actual_row_count": len(actual_rows),
        "actual_rows": actual_rows,
        "attempts": attempts,
    }


def enforce_toolchain_versions(
    report: dict[str, Any],
    toolchain: dict[str, dict[str, str]],
    expected_ocr_version: str | None,
    expected_rasterizer_version: str | None,
) -> None:
    report["toolchain"] = toolchain
    expectations = (
        ("ocr_version", expected_ocr_version, toolchain["ocr"]["version"]),
        (
            "rasterizer_version",
            expected_rasterizer_version,
            toolchain["rasterizer"]["version"],
        ),
    )
    for metric, expected, actual in expectations:
        if expected is not None and actual != expected:
            report["failures"].append({"metric": metric, "actual": actual, "expected": expected})
    report["status"] = "pass" if not report["failures"] else "fail"


def main() -> int:
    args = parse_args()
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    try:
        toolchain = collect_toolchain(args.ocr_executable, args.ocr_rasterizer)
        report = evaluate(
            read_artifacts(Path(args.parser), Path(args.pdf), args.ocr_executable, args.ocr_rasterizer),
            truth,
        )
        enforce_toolchain_versions(
            report,
            toolchain,
            args.expected_ocr_version,
            args.expected_rasterizer_version,
        )
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"OCR form quality gate failed to run: {error}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
