#!/usr/bin/env python3
"""Tiny corpus comparator for pdf-parser and lightweight Python baselines."""

from __future__ import annotations

import argparse
import json
import resource
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


DEFAULT_TOOLS = ("pdf-parser", "pymupdf", "pypdfium2", "pdfplumber", "tesseract")


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path
    truth_path: Path
    table_truth_path: Path | None = None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default="benchmark/eval/corpus/manifest.tsv",
        help="TSV manifest with category, doc_id, pdf_path, truth_text_path, and optional specialist truth paths",
    )
    parser.add_argument(
        "--tools",
        default=",".join(DEFAULT_TOOLS),
        help="Comma-separated tools: pdf-parser,pymupdf,pypdfium2,pdfplumber,tesseract",
    )
    parser.add_argument(
        "--jsonl",
        action="store_true",
        help="Emit JSONL instead of a side-by-side table",
    )
    parser.add_argument(
        "--output",
        help="Optional file path for the emitted table or JSONL",
    )
    parser.add_argument(
        "--require-baselines",
        action="store_true",
        help="Fail if an optional baseline dependency is unavailable",
    )
    parser.add_argument(
        "--pdf-parser-adaptive",
        action="store_true",
        help="Run the pdf-parser lane through adaptive extraction, including OCR-routed pages",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    entries = load_manifest(repo_root / args.manifest, repo_root)
    tools = tuple(tool.strip() for tool in args.tools.split(",") if tool.strip())

    rows: list[dict[str, object]] = []
    for entry in entries:
        truth = entry.truth_path.read_text(encoding="utf-8")
        for tool in tools:
            row = run_tool(repo_root, entry, truth, tool, pdf_parser_adaptive=args.pdf_parser_adaptive)
            rows.append(row)
            if args.require_baselines and row["status"] != "ok" and row["parser"] != "tesseract":
                raise SystemExit(f"{tool} failed for {entry.doc_id}: {row.get('reason', row['status'])}")

    output = render_jsonl(rows) if args.jsonl else render_table(rows)
    if args.output:
        output_path = repo_root / args.output
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output, encoding="utf-8")
    else:
        print(output, end="")
    return 0


def load_manifest(path: Path, repo_root: Path) -> list[Entry]:
    entries: list[Entry] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 4 or len(fields) > 7:
            raise ValueError(f"Malformed manifest row: {raw_line!r}")
        category, doc_id, pdf_path, truth_path = fields[:4]
        table_truth_path = fields[4] if len(fields) >= 5 and fields[4] else None
        entries.append(
            Entry(
                category=category,
                doc_id=doc_id,
                pdf_path=(repo_root / pdf_path).resolve(),
                truth_path=(repo_root / truth_path).resolve(),
                table_truth_path=(repo_root / table_truth_path).resolve() if table_truth_path else None,
            )
        )
    return entries


def run_tool(
    repo_root: Path,
    entry: Entry,
    truth: str,
    tool: str,
    *,
    pdf_parser_adaptive: bool,
) -> dict[str, object]:
    started = time.perf_counter()
    try:
        if tool == "pdf-parser":
            return run_pdf_parser(repo_root, entry, adaptive=pdf_parser_adaptive)
        if tool == "pymupdf":
            text = extract_optional("fitz", extract_pymupdf, entry.pdf_path)
        elif tool == "pypdfium2":
            text = extract_optional("pypdfium2", extract_pypdfium2, entry.pdf_path)
        elif tool == "pdfplumber":
            text = extract_optional("pdfplumber", extract_pdfplumber, entry.pdf_path)
        elif tool == "tesseract":
            return skipped(entry, tool, "tesseract pipeline is intentionally staged for the OCR sprint")
        else:
            return skipped(entry, tool, f"unknown tool: {tool}")
    except ModuleNotFoundError as err:
        return skipped(entry, tool, f"missing dependency: {err.name}")
    except Exception as err:  # Keep one bad parser from hiding other baselines.
        return skipped(entry, tool, f"{type(err).__name__}: {err}")

    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return row(
        entry=entry,
        parser=tool,
        status="ok",
        metrics=text_metrics(text, truth),
        latency_ms=elapsed_ms,
        peak_rss_mb=current_peak_rss_mb(),
    )


def run_pdf_parser(repo_root: Path, entry: Entry, *, adaptive: bool) -> dict[str, object]:
    cmd = [
        "zig",
        "build",
        "eval",
        "--",
        str(entry.pdf_path),
        "--truth-text",
        str(entry.truth_path),
        "--category",
        entry.category,
        "--doc-id",
        entry.doc_id,
        "--parser",
        "pdf-parser",
    ]
    if adaptive:
        cmd.append("--adaptive")
    if entry.table_truth_path is not None:
        cmd.extend(["--truth-table-json", str(entry.table_truth_path)])
    proc = subprocess.run(
        cmd,
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return skipped(entry, "pdf-parser", proc.stderr.strip() or f"exit {proc.returncode}")
    result = json.loads(proc.stdout.splitlines()[-1])
    metrics = result["metrics"]
    return row(
        entry=entry,
        parser="pdf-parser",
        status="ok",
        metrics={
            "cer": metrics["cer"],
            "wer": metrics["wer"],
            "token_f1": metrics["token_f1"],
        },
        latency_ms=metrics["median_ms_per_page"],
        peak_rss_mb=metrics["peak_rss_mb"],
    )


def extract_optional(module_name: str, extractor: Callable[[Path], str], pdf_path: Path) -> str:
    __import__(module_name)
    return extractor(pdf_path)


def extract_pymupdf(pdf_path: Path) -> str:
    import fitz

    with fitz.open(pdf_path) as doc:
        return "\n".join(page.get_text("text", sort=True) for page in doc)


def extract_pypdfium2(pdf_path: Path) -> str:
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(str(pdf_path))
    try:
        texts: list[str] = []
        for index in range(len(pdf)):
            page = pdf[index]
            try:
                textpage = page.get_textpage()
                try:
                    texts.append(textpage.get_text_range())
                finally:
                    textpage.close()
            finally:
                page.close()
        return "\n".join(texts)
    finally:
        pdf.close()


def extract_pdfplumber(pdf_path: Path) -> str:
    import pdfplumber

    with pdfplumber.open(pdf_path) as pdf:
        return "\n".join(page.extract_text() or "" for page in pdf.pages)


def row(
    *,
    entry: Entry,
    parser: str,
    status: str,
    metrics: dict[str, float | None],
    latency_ms: float | None,
    peak_rss_mb: float | None,
) -> dict[str, object]:
    return {
        "doc_id": entry.doc_id,
        "category": entry.category,
        "parser": parser,
        "status": status,
        "metrics": metrics,
        "latency_ms": latency_ms,
        "peak_rss_mb": peak_rss_mb,
    }


def skipped(entry: Entry, parser: str, reason: str) -> dict[str, object]:
    result = row(
        entry=entry,
        parser=parser,
        status="skipped",
        metrics={"cer": None, "wer": None, "token_f1": None},
        latency_ms=None,
        peak_rss_mb=None,
    )
    result["reason"] = reason
    return result


def text_metrics(prediction: str, truth: str) -> dict[str, float | None]:
    predicted = normalize(prediction)
    expected = normalize(truth)
    predicted_tokens = predicted.split()
    expected_tokens = expected.split()
    char_edits = edit_distance(list(predicted), list(expected))
    word_edits = edit_distance(predicted_tokens, expected_tokens)
    return {
        "cer": normalized_by(char_edits, len(expected)),
        "wer": normalized_by(word_edits, len(expected_tokens)),
        "token_f1": token_f1(predicted_tokens, expected_tokens),
    }


def normalize(text: str) -> str:
    return " ".join(text.split())


def normalized_by(value: int, denominator: int) -> float | None:
    if denominator == 0:
        return 0.0 if value == 0 else None
    return value / denominator


def token_f1(predicted: list[str], expected: list[str]) -> float | None:
    if not predicted and not expected:
        return 1.0
    if not predicted or not expected:
        return None
    remaining: dict[str, int] = {}
    for token in expected:
        remaining[token] = remaining.get(token, 0) + 1
    matches = 0
    for token in predicted:
        count = remaining.get(token, 0)
        if count:
            matches += 1
            remaining[token] = count - 1
    precision = matches / len(predicted)
    recall = matches / len(expected)
    if precision + recall == 0:
        return None
    return 2 * precision * recall / (precision + recall)


def edit_distance(a: list[str], b: list[str]) -> int:
    previous = list(range(len(b) + 1))
    current = [0] * (len(b) + 1)
    for ai, a_item in enumerate(a, start=1):
        current[0] = ai
        for bi, b_item in enumerate(b, start=1):
            substitution = previous[bi - 1] + (0 if a_item == b_item else 1)
            current[bi] = min(previous[bi] + 1, current[bi - 1] + 1, substitution)
        previous, current = current, previous
    return previous[len(b)]


def current_peak_rss_mb() -> float:
    rss = float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    if sys.platform == "darwin":
        return rss / (1024.0 * 1024.0)
    return rss / 1024.0


def render_jsonl(rows: list[dict[str, object]]) -> str:
    return "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows)


def render_table(rows: list[dict[str, object]]) -> str:
    headers = ("doc_id", "category", "parser", "status", "cer", "wer", "token_f1", "latency_ms", "rss_mb")
    body = []
    for data in rows:
        metrics = data["metrics"]
        assert isinstance(metrics, dict)
        body.append(
            (
                str(data["doc_id"]),
                str(data["category"]),
                str(data["parser"]),
                str(data["status"]),
                fmt(metrics.get("cer")),
                fmt(metrics.get("wer")),
                fmt(metrics.get("token_f1")),
                fmt(data.get("latency_ms")),
                fmt(data.get("peak_rss_mb")),
            )
        )
    widths = [len(header) for header in headers]
    for row_data in body:
        for index, value in enumerate(row_data):
            widths[index] = max(widths[index], len(value))
    lines = ["  ".join(header.ljust(widths[index]) for index, header in enumerate(headers))]
    lines.append("  ".join("-" * width for width in widths))
    for row_data in body:
        lines.append("  ".join(value.ljust(widths[index]) for index, value in enumerate(row_data)))
    return "\n".join(lines) + "\n"


def fmt(value: object) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.4f}"
    return str(value)


if __name__ == "__main__":
    raise SystemExit(main())
