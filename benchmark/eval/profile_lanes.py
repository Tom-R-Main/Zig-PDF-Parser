#!/usr/bin/env python3
"""Profile pdf-parser extraction lanes before doing parser optimization."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import resource
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


PROFILE_SCHEMA_VERSION = "0.2.0"
DEFAULT_LANES = ("native-text", "adaptive-artifact-jsonl", "adaptive-stream-jsonl", "ocr-routed")


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path
    password: str | None = None
    page_count: int | None = None
    source_note: str = ""


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="benchmark/eval/large/manifest.tsv")
    parser.add_argument("--lanes", default=",".join(DEFAULT_LANES))
    parser.add_argument("--output", help="JSONL output path; stdout when omitted")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--doc-id", action="append", default=[], help="Only profile matching doc id; repeatable")
    parser.add_argument("--category", action="append", default=[], help="Only profile matching category; repeatable")
    parser.add_argument("--exclude-doc-id", action="append", default=[], help="Skip matching doc id; repeatable")
    parser.add_argument("--exclude-category", action="append", default=[], help="Skip matching category; repeatable")
    parser.add_argument("--pages", help="Optional page range passed through to pdf-parser commands")
    parser.add_argument("--ocr-pages", help="Optional page range passed only to the ocr-routed lane")
    parser.add_argument("--pdf-parser-command", default="zig-out/bin/pdf-parser")
    parser.add_argument("--ensure-releasefast", dest="ensure_releasefast", action="store_true")
    parser.add_argument("--no-ensure-releasefast", dest="ensure_releasefast", action="store_false")
    parser.add_argument("--require-tools", action="store_true")
    parser.add_argument("--ocr-executable", default="tesseract")
    parser.add_argument("--ocr-rasterizer", default="pdftoppm")
    parser.add_argument("--ocr-dpi", type=int, default=200)
    parser.add_argument("--ocr-color", action="store_true", help="Rasterize OCR pages as RGB instead of default grayscale")
    parser.add_argument(
        "--enable-ocr-in-adaptive-lanes",
        action="store_true",
        help="Allow adaptive-artifact-jsonl and adaptive-stream-jsonl lanes to invoke OCR; by default OCR is isolated to ocr-routed",
    )
    parser.set_defaults(ensure_releasefast=True)
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    parser_command = resolve_command_path(repo_root, args.pdf_parser_command)
    if args.ensure_releasefast:
        ensure_releasefast(repo_root, parser_command)
    entries = filter_entries(
        load_manifest(repo_root / args.manifest, repo_root),
        set(args.doc_id),
        set(args.category),
        set(args.exclude_doc_id),
        set(args.exclude_category),
    )
    lanes = tuple(lane.strip() for lane in args.lanes.split(",") if lane.strip())
    output_handle = None
    failure_count = 0
    if args.output:
        path = repo_root / args.output if not Path(args.output).is_absolute() else Path(args.output)
        path.parent.mkdir(parents=True, exist_ok=True)
        output_handle = path.open("w", encoding="utf-8")
    try:
        for entry in entries:
            for lane in lanes:
                for repeat_index in range(args.repeat):
                    row = run_lane(
                        repo_root=repo_root,
                        parser_command=parser_command,
                        entry=entry,
                        lane=lane,
                        repeat_index=repeat_index,
                        require_tools=args.require_tools,
                        ocr_executable=args.ocr_executable,
                        ocr_rasterizer=args.ocr_rasterizer,
                        ocr_dpi=args.ocr_dpi,
                        ocr_color=args.ocr_color,
                        enable_ocr_in_adaptive_lanes=args.enable_ocr_in_adaptive_lanes,
                        pages=args.pages,
                        ocr_pages=args.ocr_pages,
                    )
                    if row["status"] != "ok":
                        failure_count += 1
                    write_row(output_handle, row)
    finally:
        if output_handle is not None:
            output_handle.close()
    return 1 if args.require_tools and failure_count else 0


def write_row(output_handle, row: dict[str, object]) -> None:
    line = json.dumps(row, sort_keys=True) + "\n"
    if output_handle is None:
        print(line, end="", flush=True)
    else:
        output_handle.write(line)
        output_handle.flush()


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


def load_manifest(path: Path, repo_root: Path) -> list[Entry]:
    rows: list[Entry] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for fields in reader:
            if not fields or not fields[0] or fields[0].startswith("#"):
                continue
            if fields[0] == "category":
                continue
            if len(fields) < 3:
                raise ValueError(f"Malformed manifest row: {fields!r}")
            password = fields[3] if len(fields) >= 4 and fields[3] and not is_truth_path(fields[3]) else None
            page_count = int(fields[4]) if len(fields) >= 5 and fields[4].isdigit() else None
            source_note = fields[5] if len(fields) >= 6 else ""
            rows.append(
                Entry(
                    category=fields[0],
                    doc_id=fields[1],
                    pdf_path=(repo_root / fields[2]).resolve(),
                    password=password,
                    page_count=page_count,
                    source_note=source_note,
                )
            )
    return rows


def is_truth_path(value: str) -> bool:
    return value.endswith(".txt") or value.endswith(".json")


def filter_entries(
    entries: list[Entry],
    doc_ids: set[str],
    categories: set[str],
    excluded_doc_ids: set[str],
    excluded_categories: set[str],
) -> list[Entry]:
    return [
        entry
        for entry in entries
        if (not doc_ids or entry.doc_id in doc_ids)
        and (not categories or entry.category in categories)
        and entry.doc_id not in excluded_doc_ids
        and entry.category not in excluded_categories
    ]


def run_lane(
    *,
    repo_root: Path,
    parser_command: Path,
    entry: Entry,
    lane: str,
    repeat_index: int,
    require_tools: bool,
    ocr_executable: str,
    ocr_rasterizer: str,
    ocr_dpi: int,
    ocr_color: bool,
    enable_ocr_in_adaptive_lanes: bool,
    pages: str | None,
    ocr_pages: str | None,
) -> dict[str, object]:
    if not entry.pdf_path.exists():
        return skipped(entry, lane, repeat_index, f"missing input: {entry.pdf_path}")
    if lane == "ocr-routed" and not tools_available((ocr_executable, ocr_rasterizer)):
        reason = f"missing OCR tools: {ocr_executable}, {ocr_rasterizer}"
        if require_tools:
            return failed(entry, lane, repeat_index, reason)
        return skipped(entry, lane, repeat_index, reason)
    try:
        input_sha256 = sha256_file(entry.pdf_path)
    except OSError as err:
        return failed(entry, lane, repeat_index, f"sha256 failed: {err}")
    with tempfile.NamedTemporaryFile(prefix=f"pdf-parser-{lane}-", suffix=".out", delete=False) as handle:
        output_path = Path(handle.name)
    try:
        cmd = build_lane_command(
            parser_command,
            entry,
            lane,
            output_path,
            ocr_executable,
            ocr_rasterizer,
            ocr_dpi,
            ocr_color,
            enable_ocr_in_adaptive_lanes,
            lane_pages(lane, pages, ocr_pages),
        )
        started = time.perf_counter()
        proc = run_timed(cmd, cwd=repo_root)
        wall_ms = (time.perf_counter() - started) * 1000.0
        output_bytes = output_path.stat().st_size if output_path.exists() else 0
        parser_latency_ms = extract_parser_latency(output_path, lane)
        status = "ok" if proc.returncode == 0 else "failed"
        reason = None if proc.returncode == 0 else (proc.stderr.strip() or f"exit {proc.returncode}")
        return {
            "profile_schema_version": PROFILE_SCHEMA_VERSION,
            "record_type": "profile_lane_result",
            "doc_id": entry.doc_id,
            "category": entry.category,
            "lane": lane,
            "repeat_index": repeat_index,
            "status": status,
            "reason": reason,
            "input_sha256": input_sha256,
            "pages": entry.page_count,
            "page_range": lane_pages(lane, pages, ocr_pages),
            "wall_ms": wall_ms,
            "parser_latency_ms": parser_latency_ms,
            "peak_rss_mb": proc.peak_rss_mb,
            "output_bytes": output_bytes,
            "ocr_dpi": ocr_dpi if lane == "ocr-routed" else None,
            "ocr_color": ocr_color if lane == "ocr-routed" else None,
            "adaptive_ocr_enabled": enable_ocr_in_adaptive_lanes if lane.startswith("adaptive-") else None,
            "source_note": entry.source_note,
        }
    finally:
        try:
            output_path.unlink()
        except FileNotFoundError:
            pass


def tools_available(names: tuple[str, ...]) -> bool:
    return all(shutil.which(name) is not None or Path(name).exists() for name in names)


def build_lane_command(
    parser_command: Path,
    entry: Entry,
    lane: str,
    output_path: Path,
    ocr_executable: str,
    ocr_rasterizer: str,
    ocr_dpi: int,
    ocr_color: bool,
    enable_ocr_in_adaptive_lanes: bool,
    pages: str | None,
) -> list[str]:
    base = [str(parser_command)]
    if lane == "native-text":
        cmd = base + ["extract", "-f", "text", "-o", str(output_path), str(entry.pdf_path)]
    elif lane == "adaptive-artifact-jsonl":
        cmd = base + [
            "extract-adaptive",
            "--input",
            str(entry.pdf_path),
            "--format",
            "artifact-jsonl",
            "--output",
            str(output_path),
        ]
        if not enable_ocr_in_adaptive_lanes:
            cmd.append("--no-ocr")
    elif lane == "adaptive-stream-jsonl":
        cmd = base + [
            "extract-adaptive",
            "--input",
            str(entry.pdf_path),
            "--format",
            "stream-jsonl",
            "--output",
            str(output_path),
        ]
        if not enable_ocr_in_adaptive_lanes:
            cmd.append("--no-ocr")
    elif lane == "ocr-routed":
        cmd = base + [
            "extract-adaptive",
            "--input",
            str(entry.pdf_path),
            "--format",
            "stream-jsonl",
            "--ocr-executable",
            ocr_executable,
            "--ocr-rasterizer",
            ocr_rasterizer,
            "--ocr-dpi",
            str(ocr_dpi),
            "--output",
            str(output_path),
        ]
        if ocr_color:
            cmd.append("--ocr-color")
    else:
        raise SystemExit(f"Unknown profile lane: {lane}")
    if entry.password:
        cmd.extend(["--password", entry.password])
    if pages:
        cmd.extend(["--pages", pages])
    return cmd


def lane_pages(lane: str, pages: str | None, ocr_pages: str | None) -> str | None:
    if lane == "ocr-routed" and ocr_pages:
        return ocr_pages
    return pages


@dataclass(frozen=True)
class TimedProcess:
    returncode: int
    stderr: str
    peak_rss_mb: float | None


def run_timed(cmd: list[str], *, cwd: Path) -> TimedProcess:
    timed_cmd = time_wrapper(cmd)
    proc = subprocess.run(timed_cmd, cwd=cwd, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False)
    return TimedProcess(
        returncode=proc.returncode,
        stderr=proc.stderr,
        peak_rss_mb=parse_peak_rss(proc.stderr),
    )


def time_wrapper(cmd: list[str]) -> list[str]:
    if not Path("/usr/bin/time").exists():
        return cmd
    if sys.platform == "darwin":
        return ["/usr/bin/time", "-l", *cmd]
    return ["/usr/bin/time", "-v", *cmd]


def parse_peak_rss(stderr: str) -> float | None:
    for line in stderr.splitlines():
        stripped = line.strip()
        if stripped.endswith("maximum resident set size"):
            value = stripped.split()[0]
            try:
                return float(value) / (1024.0 * 1024.0)
            except ValueError:
                return None
        if stripped.startswith("Maximum resident set size"):
            try:
                return float(stripped.rsplit(" ", 1)[-1]) / 1024.0
            except ValueError:
                return None
    return current_peak_rss_mb()


def extract_parser_latency(output_path: Path, lane: str) -> float | None:
    if lane != "adaptive-stream-jsonl" and lane != "ocr-routed":
        return None
    try:
        with output_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if '"record_type":"document_finished"' not in line and '"record_type": "document_finished"' not in line:
                    continue
                data = json.loads(line)
                value = data.get("elapsed_ms")
                return float(value) if value is not None else None
    except (OSError, json.JSONDecodeError):
        return None
    return None


def skipped(entry: Entry, lane: str, repeat_index: int, reason: str) -> dict[str, object]:
    result = base_record(entry, lane, repeat_index)
    result.update({"status": "skipped", "reason": reason})
    return result


def failed(entry: Entry, lane: str, repeat_index: int, reason: str) -> dict[str, object]:
    result = base_record(entry, lane, repeat_index)
    result.update({"status": "failed", "reason": reason})
    return result


def base_record(entry: Entry, lane: str, repeat_index: int) -> dict[str, object]:
    return {
        "profile_schema_version": PROFILE_SCHEMA_VERSION,
        "record_type": "profile_lane_result",
        "doc_id": entry.doc_id,
        "category": entry.category,
        "lane": lane,
        "repeat_index": repeat_index,
        "pages": entry.page_count,
        "page_range": None,
        "wall_ms": None,
        "parser_latency_ms": None,
        "peak_rss_mb": None,
        "output_bytes": 0,
        "input_sha256": None,
        "source_note": entry.source_note,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def current_peak_rss_mb() -> float:
    rss = float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    if sys.platform == "darwin":
        return rss / (1024.0 * 1024.0)
    return rss / 1024.0


if __name__ == "__main__":
    raise SystemExit(main())
