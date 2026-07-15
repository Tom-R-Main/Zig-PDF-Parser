#!/usr/bin/env python3
"""Compare financial table stress fixtures against optional table baselines."""

from __future__ import annotations

import argparse
import contextlib
import csv
import io
import json
import math
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


TABLE_COMPARE_SCHEMA_VERSION = "0.2.0"
DEFAULT_TOOLS = ("pdf-parser", "pymupdf-find-tables", "pdfplumber")


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path
    truth_text_path: Path | None
    table_truth_path: Path | None
    table_case_tags: tuple[str, ...]
    table_quality_floors: dict[str, dict[str, float]] = field(default_factory=dict)
    table_known_unsupported_tools: tuple[str, ...] = ()


class OptionalBaselineMissing(RuntimeError):
    pass


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="benchmark/eval/table_stress/manifest.tsv")
    parser.add_argument("--output", help="JSONL output path; stdout when omitted")
    parser.add_argument("--tools", default=",".join(DEFAULT_TOOLS))
    parser.add_argument("--doc-id", action="append", default=[], help="Only compare matching doc id; repeatable")
    parser.add_argument("--category", action="append", default=[], help="Only compare matching category; repeatable")
    parser.add_argument("--require-baselines", action="store_true")
    parser.add_argument("--pdf-parser-command", default="zig-out/bin/pdf-parser")
    parser.add_argument("--ensure-releasefast", dest="ensure_releasefast", action="store_true")
    parser.add_argument("--no-ensure-releasefast", dest="ensure_releasefast", action="store_false")
    parser.set_defaults(ensure_releasefast=True)
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    parser_command = resolve_path(repo_root, args.pdf_parser_command)
    tools = parse_tools(args.tools)
    if args.ensure_releasefast and "pdf-parser" in tools:
        ensure_releasefast(repo_root, parser_command)

    entries = filter_entries(
        load_entries(resolve_path(repo_root, args.manifest), repo_root),
        set(args.category),
        set(args.doc_id),
    )
    output_handle = None
    failure_count = 0
    if args.output:
        output_path = resolve_path(repo_root, args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_handle = output_path.open("w", encoding="utf-8")
    try:
        for entry in entries:
            truth = load_table_truth(entry)
            for tool in tools:
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


def resolve_path(repo_root: Path, value: str | Path) -> Path:
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


def filter_entries(entries: list[Entry], categories: set[str], doc_ids: set[str]) -> list[Entry]:
    return [
        entry
        for entry in entries
        if entry.table_truth_path is not None
        and (not categories or entry.category in categories)
        and (not doc_ids or entry.doc_id in doc_ids)
    ]


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
            table_truth_path = fields[4] if len(fields) >= 5 and fields[4] else None
            entries.append(
                Entry(
                    category=fields[0],
                    doc_id=fields[1],
                    pdf_path=resolve_manifest_path(repo_root, fields[2]),
                    truth_text_path=resolve_manifest_path(repo_root, fields[3]) if fields[3] else None,
                    table_truth_path=resolve_manifest_path(repo_root, table_truth_path) if table_truth_path else None,
                    table_case_tags=tuple(meta.get("table_case_tags", [])),
                    table_quality_floors=parse_quality_floors(meta.get("table_quality_floors")),
                    table_known_unsupported_tools=parse_known_unsupported_tools(
                        meta.get("table_known_unsupported_tools")
                    ),
                )
            )
    return entries


def parse_quality_floors(value: Any) -> dict[str, dict[str, float]]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError("table_quality_floors must be an object keyed by tool")
    parsed: dict[str, dict[str, float]] = {}
    for tool, raw_metrics in value.items():
        if not isinstance(tool, str) or not isinstance(raw_metrics, dict):
            raise ValueError("table_quality_floors must map tool names to metric objects")
        metrics: dict[str, float] = {}
        for metric, raw_floor in raw_metrics.items():
            if (
                not isinstance(metric, str)
                or isinstance(raw_floor, bool)
                or not isinstance(raw_floor, (int, float))
            ):
                raise ValueError("table quality floors must be numeric")
            floor = float(raw_floor)
            if not math.isfinite(floor) or floor < 0.0 or floor > 1.0:
                raise ValueError("table quality floors must be finite and between 0 and 1")
            metrics[metric] = floor
        parsed[tool] = metrics
    return parsed


def parse_known_unsupported_tools(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or any(not isinstance(tool, str) or not tool for tool in value):
        raise ValueError("table_known_unsupported_tools must be an array of non-empty tool names")
    return tuple(value)


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


def resolve_manifest_path(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def load_table_truth(entry: Entry) -> list[dict[str, Any]]:
    if entry.table_truth_path is None:
        raise ValueError(f"{entry.doc_id} is missing table truth")
    with entry.table_truth_path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, list):
        raise ValueError("table truth must be a list")
    return value


def run_tool(
    *,
    repo_root: Path,
    parser_command: Path,
    entry: Entry,
    truth: list[dict[str, Any]],
    tool: str,
    require_baselines: bool,
) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        if tool == "pdf-parser":
            predicted = extract_pdf_parser(repo_root, parser_command, entry)
        elif tool == "pymupdf-find-tables":
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                predicted = extract_pymupdf_tables(entry)
        elif tool == "pdfplumber":
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                predicted = extract_pdfplumber_tables(entry)
        else:
            return skipped(entry, tool, f"unknown tool: {tool}")
    except OptionalBaselineMissing as err:
        if require_baselines:
            return failed(entry, tool, str(err))
        return skipped(entry, tool, str(err))
    except Exception as err:
        return failed(entry, tool, str(err))

    wall_ms = (time.perf_counter() - started) * 1000.0
    metrics = table_metrics(predicted, truth)
    quality_floors = entry.table_quality_floors.get(tool, {})
    violations = quality_violations(metrics, quality_floors)
    known_unsupported = tool in entry.table_known_unsupported_tools
    status = "failed" if violations else "known_unsupported" if known_unsupported else "ok"
    notes = violations or (["known unsupported baseline; metrics are observational and non-blocking"] if known_unsupported else [])
    return {
        "record_type": "table_compare_result",
        "table_compare_schema_version": TABLE_COMPARE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "tool": tool,
        "status": status,
        "table_case_tags": list(entry.table_case_tags),
        "metrics": metrics,
        "quality_floors": quality_floors,
        "wall_ms": round(wall_ms, 3),
        "notes": notes,
    }


def quality_violations(
    metrics: dict[str, float | None],
    floors: dict[str, float],
) -> list[str]:
    violations: list[str] = []
    for metric, floor in sorted(floors.items()):
        value = metrics.get(metric)
        if value is None:
            violations.append(f"{metric} is unavailable; required floor is {floor:.6f}")
        elif value + 1e-12 < floor:
            violations.append(f"{metric} {value:.6f} is below required floor {floor:.6f}")
    return violations


def extract_pdf_parser(repo_root: Path, parser_command: Path, entry: Entry) -> list[dict[str, Any]]:
    with tempfile.TemporaryDirectory(prefix="pdf-parser-table-stress-") as temp_dir:
        output_path = Path(temp_dir) / "artifacts.jsonl"
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
        ]
        proc = subprocess.run(cmd, cwd=repo_root, text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "pdf-parser failed")
        records = read_jsonl(output_path)
    return [record for record in records if record.get("record_type") == "table"]


def extract_pymupdf_tables(entry: Entry) -> list[dict[str, Any]]:
    try:
        import fitz
    except ModuleNotFoundError as err:
        raise OptionalBaselineMissing("PyMuPDF is not installed") from err

    tables: list[dict[str, Any]] = []
    with fitz.open(entry.pdf_path) as doc:
        for page_index, page in enumerate(doc):
            page_height = float(page.rect.height)
            finder = getattr(page, "find_tables", None)
            if finder is None:
                raise OptionalBaselineMissing("PyMuPDF Page.find_tables() is unavailable")
            found = finder()
            for table_index, table in enumerate(getattr(found, "tables", found)):
                rows = table.extract()
                tables.append(
                    {
                        "table_id": f"pymupdf-{page_index}-{table_index}",
                        "page_index": page_index,
                        "bbox": top_origin_bbox_to_pdf(getattr(table, "bbox", None), page_height),
                        "rows": [[{"text": cell or ""} for cell in row] for row in rows],
                    }
                )
    return tables


def top_origin_bbox_to_pdf(value: Any, page_height: float) -> list[float]:
    box = parse_bbox(value)
    if box is None:
        return []
    return [box[0], page_height - box[3], box[2], page_height - box[1]]


def extract_pdfplumber_tables(entry: Entry) -> list[dict[str, Any]]:
    try:
        import pdfplumber
    except ModuleNotFoundError as err:
        raise OptionalBaselineMissing("pdfplumber is not installed") from err

    tables: list[dict[str, Any]] = []
    with pdfplumber.open(entry.pdf_path) as pdf:
        for page_index, page in enumerate(pdf.pages):
            for table_index, rows in enumerate(page.extract_tables() or []):
                tables.append(
                    {
                        "table_id": f"pdfplumber-{page_index}-{table_index}",
                        "page_index": page_index,
                        "rows": [[{"text": cell or ""} for cell in row] for row in rows],
                    }
                )
    return tables


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                records.append(json.loads(line))
    return records


def table_metrics(predicted: list[dict[str, Any]], truth: list[dict[str, Any]]) -> dict[str, float | None]:
    predicted_cells = flatten_cells(predicted)
    truth_cells = flatten_cells(truth)
    return {
        "cell_text_accuracy": sequence_accuracy(
            [normalize_cell(cell.get("text", "")) for cell in predicted_cells],
            [normalize_cell(cell.get("text", "")) for cell in truth_cells],
        ),
        "role_accuracy": nullable_sequence_accuracy(
            [cell.get("role") for cell in predicted_cells],
            [cell.get("role") for cell in truth_cells],
        ),
        "bbox_iou": bbox_iou_metric(predicted, truth),
        "source_span_coverage": source_span_coverage(predicted_cells, truth_cells),
        "continuation_accuracy": continuation_accuracy(predicted, truth),
        "numeric_accuracy": numeric_accuracy(predicted_cells, truth_cells),
    }


def flatten_cells(tables: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cells: list[dict[str, Any]] = []
    for table in tables:
        for row in table.get("rows", []):
            row_cells = row.get("cells", []) if isinstance(row, dict) else row
            if not isinstance(row_cells, list):
                continue
            for cell in row_cells:
                if isinstance(cell, dict):
                    cells.append(cell)
                else:
                    cells.append({"text": "" if cell is None else str(cell)})
    return cells


def normalize_cell(value: Any) -> str:
    return " ".join(str(value).split())


def sequence_accuracy(predicted: list[str], truth: list[str]) -> float | None:
    if not truth:
        return 1.0 if not predicted else 0.0
    matched = sum(1 for left, right in zip(predicted, truth) if left == right)
    return matched / max(len(predicted), len(truth))


def nullable_sequence_accuracy(predicted: list[Any], truth: list[Any]) -> float | None:
    labeled = [(index, value) for index, value in enumerate(truth) if value is not None]
    if not labeled:
        return None
    matched = 0
    for index, value in labeled:
        if index < len(predicted) and predicted[index] == value:
            matched += 1
    return matched / len(labeled)


def bbox_iou_metric(predicted: list[dict[str, Any]], truth: list[dict[str, Any]]) -> float | None:
    predicted_boxes = [box for table in predicted if (box := parse_bbox(table.get("bbox"))) is not None]
    truth_boxes = [box for table in truth if (box := parse_bbox(table.get("bbox"))) is not None]
    if not truth_boxes:
        return None
    if not predicted_boxes:
        return 0.0
    count = min(len(predicted_boxes), len(truth_boxes))
    return sum(bbox_iou(predicted_boxes[index], truth_boxes[index]) for index in range(count)) / max(
        len(predicted_boxes),
        len(truth_boxes),
    )


def parse_bbox(value: Any) -> tuple[float, float, float, float] | None:
    if isinstance(value, dict):
        try:
            return (float(value["x0"]), float(value["y0"]), float(value["x1"]), float(value["y1"]))
        except (KeyError, TypeError, ValueError):
            return None
    if isinstance(value, list) and len(value) == 4:
        try:
            return tuple(float(part) for part in value)  # type: ignore[return-value]
        except (TypeError, ValueError):
            return None
    return None


def bbox_iou(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    ix0 = max(a[0], b[0])
    iy0 = max(a[1], b[1])
    ix1 = min(a[2], b[2])
    iy1 = min(a[3], b[3])
    intersection = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
    union = bbox_area(a) + bbox_area(b) - intersection
    return 0.0 if union <= 0 else intersection / union


def bbox_area(box: tuple[float, float, float, float]) -> float:
    return max(0.0, box[2] - box[0]) * max(0.0, box[3] - box[1])


def source_span_coverage(predicted: list[dict[str, Any]], truth: list[dict[str, Any]]) -> float | None:
    required_indexes = [
        index
        for index, cell in enumerate(truth)
        if cell.get("source_span_required") is True or "source_span_ids" in cell
    ]
    if not required_indexes:
        return None
    covered = 0
    for index in required_indexes:
        if index < len(predicted) and predicted[index].get("source_span_ids"):
            covered += 1
    return covered / len(required_indexes)


def continuation_accuracy(predicted: list[dict[str, Any]], truth: list[dict[str, Any]]) -> float | None:
    truth_values = continuation_values(truth)
    if not truth_values:
        return None
    predicted_values = continuation_values(predicted)
    matched = sum(1 for left, right in zip(predicted_values, truth_values) if left == right)
    return matched / max(len(predicted_values), len(truth_values))


def continuation_values(tables: list[dict[str, Any]]) -> list[str | None]:
    values: list[str | None] = []
    for table in tables:
        if "logical_table_id" in table or "continued_from_table_id" in table or "continued_to_table_id" in table:
            values.extend(
                [
                    table.get("logical_table_id"),
                    table.get("continued_from_table_id"),
                    table.get("continued_to_table_id"),
                ]
            )
    return values


def numeric_accuracy(predicted: list[dict[str, Any]], truth: list[dict[str, Any]]) -> float | None:
    labeled_truth = [(index, numeric_value(cell)) for index, cell in enumerate(truth) if "numeric" in cell]
    if not labeled_truth:
        return None
    matched = 0
    for index, value in labeled_truth:
        if index >= len(predicted):
            continue
        predicted_value = numeric_value(predicted[index])
        if value is None and predicted_value is None:
            matched += 1
        elif value is not None and predicted_value is not None and abs(value - predicted_value) <= 0.0001:
            matched += 1
    return matched / len(labeled_truth)


def numeric_value(cell: dict[str, Any]) -> float | None:
    numeric = cell.get("numeric")
    if isinstance(numeric, dict):
        if numeric.get("is_numeric") is True and numeric.get("value") is not None:
            return float(numeric["value"])
        return None
    parsed = parse_accounting_number(cell.get("normalized_text") or cell.get("text"))
    return parsed


def parse_accounting_number(value: Any) -> float | None:
    text = normalize_cell(value)
    if not text or text.upper() in {"N/M", "NM"} or text in {"-", "--"}:
        return None
    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1]
    text = text.replace("$", "").replace(",", "").replace(" ", "")
    percent = text.endswith("%")
    if percent:
        text = text[:-1]
    try:
        number = float(text)
    except ValueError:
        return None
    if percent:
        number /= 100.0
    return -number if negative else number


def skipped(entry: Entry, tool: str, reason: str) -> dict[str, Any]:
    return {
        "record_type": "table_compare_result",
        "table_compare_schema_version": TABLE_COMPARE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "tool": tool,
        "status": "skipped",
        "table_case_tags": list(entry.table_case_tags),
        "metrics": empty_metrics(),
        "wall_ms": None,
        "notes": [reason],
    }


def failed(entry: Entry, tool: str, reason: str) -> dict[str, Any]:
    row = skipped(entry, tool, reason)
    row["status"] = "failed"
    return row


def empty_metrics() -> dict[str, None]:
    return {
        "cell_text_accuracy": None,
        "role_accuracy": None,
        "bbox_iou": None,
        "source_span_coverage": None,
        "continuation_accuracy": None,
        "numeric_accuracy": None,
    }


def write_row(output_handle: Any, row: dict[str, Any]) -> None:
    text = json.dumps(row, sort_keys=True) + "\n"
    if output_handle is None:
        print(text, end="")
    else:
        output_handle.write(text)


if __name__ == "__main__":
    raise SystemExit(main())
