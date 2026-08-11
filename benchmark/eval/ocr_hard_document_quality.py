#!/usr/bin/env python3
"""Absolute OCR quality gate for real public-domain hard scans."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

from ocr_form_quality import (
    collect_toolchain,
    enforce_toolchain_versions,
    read_artifacts,
    semantic_tokens,
    token_metrics,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--parser", default="zig-out/bin/pdf-parser")
    parser.add_argument(
        "--pdf",
        default="benchmark/eval/corpus/scanned_typewritten/jbig2-public-domain-preface.pdf",
    )
    parser.add_argument(
        "--truth",
        default=(
            "benchmark/eval/ground_truth/ocr_text/scanned_typewritten/"
            "jbig2-public-domain-preface.json"
        ),
    )
    parser.add_argument("--output")
    parser.add_argument("--ocr-executable", default="tesseract")
    parser.add_argument("--ocr-rasterizer", default="pdftoppm")
    parser.add_argument("--expected-ocr-version")
    parser.add_argument("--expected-rasterizer-version")
    return parser.parse_args()


def contains_token_sequence(haystack: str, needle: str) -> bool:
    haystack_tokens = [token.upper() for token in semantic_tokens(haystack)]
    needle_tokens = [token.upper() for token in semantic_tokens(needle)]
    if not needle_tokens:
        return True
    width = len(needle_tokens)
    return any(
        haystack_tokens[index : index + width] == needle_tokens
        for index in range(len(haystack_tokens) - width + 1)
    )


def evaluate(
    artifacts: list[dict[str, Any]],
    truth: dict[str, Any],
    pdf_bytes: bytes,
) -> dict[str, Any]:
    manifests = [record for record in artifacts if record.get("record_type") == "document_manifest"]
    if len(manifests) != 1:
        raise ValueError(f"expected one document_manifest, got {len(manifests)}")
    manifest = manifests[0]
    if manifest.get("has_specialist_failures"):
        raise ValueError("document manifest reports specialist failures")

    spans = [record for record in artifacts if record.get("record_type") == "span"]
    span_text = "\n".join(str(record.get("text", "")) for record in spans)
    attempts = [record for record in artifacts if record.get("record_type") == "specialist_attempt"]
    completed_selected_attempts = [
        record
        for record in attempts
        if record.get("attempt_status") == "completed" and record.get("selected") is True
    ]
    expected_attempt_count = truth.get("expected_attempt_count")
    expected_selected_attempt = truth.get("expected_selected_attempt", {})
    fresh_ocr_spans = [
        record
        for record in spans
        if record.get("provenance", {}).get("source_kind") == "fresh_ocr"
    ]

    expected_sha256 = str(truth["fixture_sha256"])
    actual_sha256 = hashlib.sha256(pdf_bytes).hexdigest()
    required_filters = [str(value) for value in truth["required_pdf_filters"]]
    matched_filters = [value for value in required_filters if value.encode("ascii") in pdf_bytes]
    required_phrases = [str(value) for value in truth["required_phrases"]]
    matched_phrases = [
        value for value in required_phrases if contains_token_sequence(span_text, value)
    ]
    tokens = token_metrics(str(truth["text"]), span_text)
    route_counts = manifest.get("route_counts", {})
    expected_route_counts = truth.get("expected_route_counts", {})

    metrics = {
        "fixture_sha256_exact": 1.0 if actual_sha256 == expected_sha256 else 0.0,
        "manifest_input_sha256_exact": (
            1.0 if manifest.get("input_sha256") == expected_sha256 else 0.0
        ),
        "source_id_exact": 1.0 if manifest.get("source_id") == truth["doc_id"] else 0.0,
        "required_pdf_filter_recall": (
            len(matched_filters) / len(required_filters) if required_filters else 1.0
        ),
        "page_count_exact": (
            1.0 if manifest.get("page_count") == int(truth["expected_page_count"]) else 0.0
        ),
        "native_page_count_exact": 1.0 if route_counts.get("native_pages") == 0 else 0.0,
        "route_counts_exact": (
            1.0
            if all(route_counts.get(key) == value for key, value in expected_route_counts.items())
            else 0.0
        ),
        "ocr_attempt_completed": 1.0 if len(completed_selected_attempts) == 1 else 0.0,
        "attempt_count_exact": (
            1.0 if expected_attempt_count is None or len(attempts) == expected_attempt_count else 0.0
        ),
        "selected_attempt_config_exact": (
            1.0
            if len(completed_selected_attempts) == 1
            and all(
                completed_selected_attempts[0].get("config", {}).get(key) == value
                for key, value in expected_selected_attempt.items()
            )
            else 0.0
        ),
        "fresh_ocr_span_fraction": len(fresh_ocr_spans) / len(spans) if spans else 0.0,
        "required_phrase_recall": (
            len(matched_phrases) / len(required_phrases) if required_phrases else 1.0
        ),
        "token_precision": tokens["precision"],
        "token_recall": tokens["recall"],
        "token_f1": tokens["f1"],
    }
    floors = truth["floors"]
    failures = [
        {"metric": metric, "actual": metrics.get(metric), "floor": floor}
        for metric, floor in floors.items()
        if metrics.get(metric) is None or metrics[metric] < float(floor)
    ]
    return {
        "benchmark_schema_version": "0.3.0",
        "record_type": "ocr_hard_document_quality",
        "doc_id": truth["doc_id"],
        "status": "pass" if not failures else "fail",
        "fixture": {
            "actual_sha256": actual_sha256,
            "expected_sha256": expected_sha256,
            "required_pdf_filters": required_filters,
            "matched_pdf_filters": matched_filters,
        },
        "metrics": metrics,
        "floors": floors,
        "failures": failures,
        "required_phrases": required_phrases,
        "matched_phrases": matched_phrases,
        "span_count": len(spans),
        "attempt_count": len(attempts),
        "expected_route_counts": expected_route_counts,
        "actual_route_counts": route_counts,
        "attempts": [
            {
                "attempt_id": record.get("attempt_id"),
                "status": record.get("attempt_status"),
                "selected": record.get("selected"),
                "config": record.get("config"),
                "quality": record.get("quality"),
            }
            for record in attempts
        ],
    }


def main() -> int:
    args = parse_args()
    pdf_path = Path(args.pdf)
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    try:
        toolchain = collect_toolchain(args.ocr_executable, args.ocr_rasterizer)
        report = evaluate(
            read_artifacts(
                Path(args.parser),
                pdf_path,
                args.ocr_executable,
                args.ocr_rasterizer,
                str(truth["doc_id"]),
            ),
            truth,
            pdf_path.read_bytes(),
        )
        enforce_toolchain_versions(
            report,
            toolchain,
            args.expected_ocr_version,
            args.expected_rasterizer_version,
        )
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"OCR hard-document quality gate failed to run: {error}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
