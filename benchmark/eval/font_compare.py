#!/usr/bin/env python3
"""Compare ugly-font fixtures against external text APIs."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


FONT_COMPARE_SCHEMA_VERSION = "0.2.0"
DEFAULT_TOOLS = ("pdf-parser", "pdftotext", "pymupdf", "pypdfium2")
REQUIRED_TRUTH_KEYS = {
    "expected_text",
    "expect_actual_text",
    "expect_unicode_map_error",
    "expected_writing_mode",
    "required_glyph_trace_fields",
}


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path
    truth_text_path: Path
    font_truth_path: Path | None
    font_case_tags: tuple[str, ...]


class OptionalBaselineMissing(RuntimeError):
    pass


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="benchmark/eval/corpus/manifest.tsv")
    parser.add_argument("--output", help="JSONL output path; stdout when omitted")
    parser.add_argument("--tools", default=",".join(DEFAULT_TOOLS))
    parser.add_argument("--doc-id", action="append", default=[], help="Only compare matching doc id; repeatable")
    parser.add_argument("--require-baselines", action="store_true")
    parser.add_argument("--pdf-parser-command", default="zig-out/bin/pdf-parser")
    parser.add_argument("--ensure-releasefast", dest="ensure_releasefast", action="store_true")
    parser.add_argument("--no-ensure-releasefast", dest="ensure_releasefast", action="store_false")
    parser.set_defaults(ensure_releasefast=True)
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    parser_command = resolve_command_path(repo_root, args.pdf_parser_command)
    if args.ensure_releasefast and "pdf-parser" in parse_tools(args.tools):
        ensure_releasefast(repo_root, parser_command)

    doc_filter = set(args.doc_id)
    entries = [
        entry
        for entry in load_entries(repo_root / args.manifest, repo_root)
        if entry.category == "weird_fonts" and (not doc_filter or entry.doc_id in doc_filter)
    ]

    output_handle = None
    failure_count = 0
    if args.output:
        output_path = resolve_command_path(repo_root, args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_handle = output_path.open("w", encoding="utf-8")
    try:
        for entry in entries:
            truth = load_font_truth(entry)
            for tool in parse_tools(args.tools):
                row = run_tool(
                    repo_root=repo_root,
                    parser_command=parser_command,
                    entry=entry,
                    truth=truth,
                    tool=tool,
                    require_baselines=args.require_baselines,
                )
                if row["status"] == "failed":
                    failure_count += 1
                write_row(output_handle, row)
    finally:
        if output_handle is not None:
            output_handle.close()
    return 1 if failure_count else 0


def parse_tools(value: str) -> tuple[str, ...]:
    return tuple(tool.strip() for tool in value.split(",") if tool.strip())


def resolve_command_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def ensure_releasefast(repo_root: Path, parser_command: Path) -> None:
    proc = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast", "--summary", "all"],
        cwd=repo_root,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.strip() or proc.stdout.strip() or "ReleaseFast build failed")
    if not parser_command.exists():
        raise SystemExit(f"ReleaseFast build completed but {parser_command} was not found")


def load_entries(manifest_path: Path, repo_root: Path) -> list[Entry]:
    metadata = load_metadata(manifest_path.parent / "metadata.jsonl")
    entries: list[Entry] = []
    with manifest_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for fields in reader:
            if not fields or not fields[0] or fields[0].startswith("#"):
                continue
            if len(fields) < 4:
                raise ValueError(f"Malformed manifest row: {fields!r}")
            meta = metadata.get((fields[0], fields[1]), {})
            font_truth_path = meta.get("font_truth_path")
            entries.append(
                Entry(
                    category=fields[0],
                    doc_id=fields[1],
                    pdf_path=resolve_manifest_path(repo_root, fields[2]),
                    truth_text_path=resolve_manifest_path(repo_root, fields[3]),
                    font_truth_path=resolve_manifest_path(repo_root, font_truth_path) if font_truth_path else None,
                    font_case_tags=tuple(meta.get("font_case_tags", [])),
                )
            )
    return entries


def load_metadata(path: Path) -> dict[tuple[str, str], dict[str, Any]]:
    if not path.exists():
        return {}
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            row = json.loads(line)
            rows[(row["category"], row["doc_id"])] = row
    return rows


def resolve_manifest_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def load_font_truth(entry: Entry) -> dict[str, Any]:
    if entry.font_truth_path is None:
        raise ValueError(f"{entry.doc_id} is missing font_truth_path metadata")
    with entry.font_truth_path.open("r", encoding="utf-8") as handle:
        truth = json.load(handle)
    validate_font_truth(truth)
    return truth


def validate_font_truth(truth: dict[str, Any]) -> None:
    missing = sorted(REQUIRED_TRUTH_KEYS.difference(truth))
    if missing:
        raise ValueError(f"font truth missing keys: {', '.join(missing)}")
    if not isinstance(truth["required_glyph_trace_fields"], list):
        raise ValueError("required_glyph_trace_fields must be a list")


def run_tool(
    *,
    repo_root: Path,
    parser_command: Path,
    entry: Entry,
    truth: dict[str, Any],
    tool: str,
    require_baselines: bool,
) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        if tool == "pdf-parser":
            result = extract_pdf_parser(repo_root, parser_command, entry)
        elif tool == "pdftotext":
            result = extract_pdftotext(entry)
        elif tool == "pymupdf":
            result = extract_pymupdf(entry)
        elif tool == "pypdfium2":
            result = extract_pypdfium2(entry)
        else:
            return skipped(entry, tool, f"unknown tool: {tool}")
    except OptionalBaselineMissing as err:
        if require_baselines:
            return failed(entry, tool, str(err))
        return skipped(entry, tool, str(err))
    except Exception as err:
        return failed(entry, tool, str(err))

    wall_ms = (time.perf_counter() - started) * 1000.0
    expectations = expectation_results(tool, truth, result)
    exact_text_ok = exact_text_matches(result["text"], truth["expected_text"])
    expectations["exact_text_ok"] = exact_text_ok if truth.get("require_exact_text") else None
    return {
        "record_type": "font_compare_result",
        "font_compare_schema_version": FONT_COMPARE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "tool": tool,
        "status": "failed" if truth.get("require_exact_text") and not exact_text_ok else "ok",
        "font_case_tags": list(entry.font_case_tags),
        "wall_ms": round(wall_ms, 3),
        "text": result["text"],
        "metrics": text_metrics(truth["expected_text"], result["text"]),
        "char_count": result.get("char_count"),
        "bbox_count": result.get("bbox_count"),
        "expectations": expectations,
        "notes": result.get("notes", []),
    }


def extract_pdf_parser(repo_root: Path, parser_command: Path, entry: Entry) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="pdf-parser-font-diff-") as temp_dir:
        output_path = Path(temp_dir) / "artifacts.jsonl"
        debug_dir = Path(temp_dir) / "debug"
        cmd = [
            str(parser_command),
            "extract-adaptive",
            "--input",
            str(entry.pdf_path),
            "--source-id",
            entry.doc_id,
            "--format",
            "artifact-jsonl",
            "--output",
            str(output_path),
            "--debug-assets-dir",
            str(debug_dir),
        ]
        proc = subprocess.run(cmd, cwd=repo_root, text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "pdf-parser failed")
        artifacts = read_jsonl(output_path)
        spans = [row for row in artifacts if row.get("record_type") == "span"]
        glyph_traces = read_glyph_traces(repo_root, artifacts)
        return {
            "text": "\n".join(str(span.get("text", "")) for span in spans if span.get("text")),
            "char_count": sum(len(str(span.get("text", ""))) for span in spans),
            "bbox_count": len(glyph_traces),
            "glyph_traces": glyph_traces,
            "notes": [],
        }


def extract_pymupdf(entry: Entry) -> dict[str, Any]:
    try:
        import fitz  # type: ignore
    except ImportError as err:
        raise OptionalBaselineMissing("PyMuPDF is not installed") from err

    doc = fitz.open(entry.pdf_path)
    try:
        text_parts: list[str] = []
        bbox_count = 0
        char_count = 0
        notes: list[str] = []
        for page in doc:
            text = page.get_text("text", sort=True)
            text_parts.append(text.rstrip("\n"))
            char_count += len(text)
            try:
                trace = page.get_texttrace()
                bbox_count += sum(len(span.get("chars", [])) for span in trace)
            except Exception as err:
                notes.append(f"get_texttrace unavailable: {err}")
                bbox_count += rawdict_char_count(page.get_text("rawdict"))
        return {
            "text": "\n".join(part for part in text_parts if part),
            "char_count": char_count,
            "bbox_count": bbox_count,
            "notes": notes,
        }
    finally:
        doc.close()


def extract_pdftotext(entry: Entry) -> dict[str, Any]:
    executable = shutil.which("pdftotext")
    if executable is None:
        raise OptionalBaselineMissing("pdftotext is not installed")
    proc = subprocess.run(
        [executable, "-enc", "UTF-8", "-layout", str(entry.pdf_path), "-"],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "pdftotext failed")
    text = proc.stdout.rstrip("\n\f")
    return {
        "text": text,
        "char_count": len(text),
        "bbox_count": None,
        "notes": ["Poppler pdftotext -layout UTF-8 baseline"],
    }


def extract_pypdfium2(entry: Entry) -> dict[str, Any]:
    try:
        import pypdfium2 as pdfium  # type: ignore
    except ImportError as err:
        raise OptionalBaselineMissing("pypdfium2 is not installed") from err

    doc = pdfium.PdfDocument(str(entry.pdf_path))
    try:
        text_parts: list[str] = []
        char_count = 0
        bbox_count = 0
        for page_index in range(len(doc)):
            page = doc[page_index]
            textpage = page.get_textpage()
            count = textpage.count_chars()
            text_parts.append(textpage.get_text_range(0, count).rstrip("\n"))
            char_count += count
            for index in range(count):
                if textpage.get_charbox(index) is not None:
                    bbox_count += 1
            textpage.close()
            page.close()
        return {
            "text": "\n".join(part for part in text_parts if part),
            "char_count": char_count,
            "bbox_count": bbox_count,
            "notes": [],
        }
    finally:
        doc.close()


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def read_glyph_traces(repo_root: Path, artifacts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    traces: list[dict[str, Any]] = []
    for row in artifacts:
        if row.get("record_type") != "debug_asset" or row.get("asset_kind") != "glyph_trace_jsonl":
            continue
        raw_path = row.get("path")
        if not raw_path:
            continue
        path = Path(str(raw_path))
        if not path.is_absolute():
            path = repo_root / path
        if path.exists():
            traces.extend(read_jsonl(path))
    return traces


def rawdict_char_count(raw: dict[str, Any]) -> int:
    count = 0
    for block in raw.get("blocks", []):
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                count += len(span.get("chars", []))
    return count


def expectation_results(tool: str, truth: dict[str, Any], result: dict[str, Any]) -> dict[str, Any]:
    if tool != "pdf-parser":
        return {
            "actual_text_ok": text_contains_expected(result["text"], truth["expected_text"]) if truth.get("expect_actual_text") else None,
            "unicode_map_error_ok": None,
            "vertical_writing_ok": None,
            "required_glyph_trace_fields_ok": None,
        }

    traces = result.get("glyph_traces", [])
    required_fields = truth.get("required_glyph_trace_fields", [])
    first_trace = traces[0] if traces else {}
    expected_writing_mode = truth.get("expected_writing_mode")
    expect_unicode_error = bool(truth.get("expect_unicode_map_error"))
    return {
        "actual_text_ok": any(bool(trace.get("actual_text")) for trace in traces)
        if truth.get("expect_actual_text")
        else not any(bool(trace.get("actual_text")) for trace in traces),
        "unicode_map_error_ok": any(bool(trace.get("unicode_map_error")) for trace in traces)
        if expect_unicode_error
        else not any(bool(trace.get("unicode_map_error")) for trace in traces),
        "vertical_writing_ok": any(trace.get("writing_mode") == expected_writing_mode for trace in traces)
        if expected_writing_mode is not None
        else None,
        "required_glyph_trace_fields_ok": all(field in first_trace for field in required_fields) if traces else False,
    }


def text_contains_expected(text: str, expected: str) -> bool:
    return normalize_text(expected) in normalize_text(text)


def exact_text_matches(actual: str, expected: str) -> bool:
    def canonical(value: str) -> str:
        return value.replace("\r\n", "\n").replace("\r", "\n").strip("\n\f")

    return canonical(actual) == canonical(expected)


def text_metrics(expected: str, actual: str) -> dict[str, float]:
    expected_norm = normalize_text(expected)
    actual_norm = normalize_text(actual)
    return {
        "cer": normalized_edit_distance(expected_norm, actual_norm),
        "wer": word_error_rate(expected_norm, actual_norm),
        "token_f1": token_f1(expected_norm, actual_norm),
    }


def normalize_text(value: str) -> str:
    return " ".join(value.split())


def normalized_edit_distance(expected: str, actual: str) -> float:
    if not expected and not actual:
        return 0.0
    return levenshtein(expected, actual) / max(1, len(expected))


def word_error_rate(expected: str, actual: str) -> float:
    expected_words = expected.split()
    actual_words = actual.split()
    if not expected_words and not actual_words:
        return 0.0
    return levenshtein_sequence(expected_words, actual_words) / max(1, len(expected_words))


def token_f1(expected: str, actual: str) -> float:
    expected_words = expected.split()
    actual_words = actual.split()
    if not expected_words and not actual_words:
        return 1.0
    if not expected_words or not actual_words:
        return 0.0
    expected_counts: dict[str, int] = {}
    actual_counts: dict[str, int] = {}
    for word in expected_words:
        expected_counts[word] = expected_counts.get(word, 0) + 1
    for word in actual_words:
        actual_counts[word] = actual_counts.get(word, 0) + 1
    overlap = sum(min(count, actual_counts.get(word, 0)) for word, count in expected_counts.items())
    precision = overlap / len(actual_words)
    recall = overlap / len(expected_words)
    return 0.0 if precision + recall == 0 else 2.0 * precision * recall / (precision + recall)


def levenshtein(a: str, b: str) -> int:
    return levenshtein_sequence(list(a), list(b))


def levenshtein_sequence(a: list[Any], b: list[Any]) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        current = [i]
        for j, cb in enumerate(b, start=1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (0 if ca == cb else 1),
                )
            )
        previous = current
    return previous[-1]


def write_row(output_handle, row: dict[str, Any]) -> None:
    line = json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
    if output_handle is None:
        print(line, end="", flush=True)
    else:
        output_handle.write(line)
        output_handle.flush()


def skipped(entry: Entry, tool: str, reason: str) -> dict[str, Any]:
    return {
        "record_type": "font_compare_result",
        "font_compare_schema_version": FONT_COMPARE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "tool": tool,
        "status": "skipped",
        "font_case_tags": list(entry.font_case_tags),
        "reason": reason,
    }


def failed(entry: Entry, tool: str, reason: str) -> dict[str, Any]:
    return {
        "record_type": "font_compare_result",
        "font_compare_schema_version": FONT_COMPARE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "tool": tool,
        "status": "failed",
        "font_case_tags": list(entry.font_case_tags),
        "reason": reason,
    }


if __name__ == "__main__":
    raise SystemExit(main())
