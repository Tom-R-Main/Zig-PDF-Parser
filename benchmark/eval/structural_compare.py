#!/usr/bin/env python3
"""Compare pdf-parser structural checks with qpdf --check over a manifest."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path


@dataclass(frozen=True)
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str
    wall_ms: float


def main() -> int:
    return main_with_args(None)


def main_with_args_for_test(argv: list[str]) -> int:
    return main_with_args(argv)


def main_with_args(argv: list[str] | None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="benchmark/eval/corpus/manifest.tsv")
    parser.add_argument("--output", required=True, help="JSONL output path")
    parser.add_argument("--pdf-parser-command", default="zig-out/bin/pdf-parser")
    parser.add_argument("--qpdf-command", default="qpdf")
    parser.add_argument("--strict", action="store_true", help="Run pdf-parser check in strict mode")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    manifest_path = resolve_path(repo_root, args.manifest)
    output_path = resolve_path(repo_root, args.output)
    pdf_parser_command = resolve_path(repo_root, args.pdf_parser_command)

    rows = [
        compare_entry(
            repo_root,
            entry,
            pdf_parser_command=pdf_parser_command,
            qpdf_command=args.qpdf_command,
            strict=args.strict,
        )
        for entry in load_manifest(manifest_path, repo_root)
    ]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_jsonl(rows), encoding="utf-8")
    return 0


def resolve_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def load_manifest(path: Path, repo_root: Path) -> list[Entry]:
    entries: list[Entry] = []
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            raise ValueError(f"{path}:{line_number}: malformed manifest row")
        category, doc_id, pdf_path = fields[:3]
        entries.append(Entry(category=category, doc_id=doc_id, pdf_path=resolve_path(repo_root, pdf_path)))
    return entries


def compare_entry(
    repo_root: Path,
    entry: Entry,
    *,
    pdf_parser_command: Path,
    qpdf_command: str,
    strict: bool,
) -> dict[str, object]:
    if not entry.pdf_path.exists():
        return skipped_record(entry, "missing_pdf", f"Missing PDF: {entry.pdf_path}")

    parser_cmd = [str(pdf_parser_command), "check", "--format", "json"]
    if strict:
        parser_cmd.append("--strict")
    parser_cmd.append(str(entry.pdf_path))

    parser_result = run_command(parser_cmd, repo_root)
    qpdf_result = run_command([qpdf_command, "--check", str(entry.pdf_path)], repo_root)
    parser_report = parse_parser_report(parser_result.stdout)
    parser_status = parser_report.get("status") if isinstance(parser_report.get("status"), str) else None
    diagnostics = parser_report.get("diagnostics") if isinstance(parser_report.get("diagnostics"), list) else []
    qpdf_warnings = qpdf_warning_lines(qpdf_result.stdout, qpdf_result.stderr)

    return {
        "record_type": "structural_compare",
        "category": entry.category,
        "doc_id": entry.doc_id,
        "pdf_path": str(entry.pdf_path),
        "classification": classify(parser_result.exit_code, parser_status, qpdf_result.exit_code, len(qpdf_warnings)),
        "pdf_parser": {
            "exit_code": parser_result.exit_code,
            "status": parser_status,
            "diagnostic_count": len(diagnostics),
            "diagnostic_codes": diagnostic_codes(diagnostics),
            "wall_ms": parser_result.wall_ms,
            "stderr": parser_result.stderr.strip(),
        },
        "qpdf": {
            "exit_code": qpdf_result.exit_code,
            "warning_count": len(qpdf_warnings),
            "warnings": qpdf_warnings,
            "wall_ms": qpdf_result.wall_ms,
            "stderr": qpdf_result.stderr.strip(),
        },
    }


def run_command(cmd: list[str], cwd: Path) -> CommandResult:
    started = time.perf_counter()
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)
    return CommandResult(
        exit_code=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        wall_ms=(time.perf_counter() - started) * 1000.0,
    )


def parse_parser_report(stdout: str) -> dict[str, object]:
    for line in reversed(stdout.splitlines()):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        return value if isinstance(value, dict) else {}
    return {}


def diagnostic_codes(diagnostics: Iterable[object]) -> list[str]:
    codes: list[str] = []
    for diagnostic in diagnostics:
        if isinstance(diagnostic, dict) and isinstance(diagnostic.get("code"), str):
            codes.append(diagnostic["code"])
    return codes


def qpdf_warning_lines(stdout: str, stderr: str) -> list[str]:
    lines: list[str] = []
    for raw_line in (stdout + "\n" + stderr).splitlines():
        line = raw_line.strip()
        if not line:
            continue
        lowered = line.lower()
        if lowered.startswith("no syntax or stream encoding errors found"):
            continue
        if lowered == "errors that qpdf cannot detect":
            continue
        if "warning" in lowered or "error" in lowered or "damaged" in lowered:
            lines.append(line)
    return lines


def classify(
    parser_exit_code: int,
    parser_status: str | None,
    qpdf_exit_code: int,
    qpdf_warning_count: int,
) -> str:
    if parser_exit_code != 0:
        return "parser_failed"
    parser_warned = parser_status in {"recovered", "failed"}
    qpdf_warned = qpdf_exit_code != 0 or qpdf_warning_count > 0
    if not parser_warned and not qpdf_warned:
        return "both_ok"
    if parser_warned and qpdf_warned:
        return "both_warn"
    if parser_warned and not qpdf_warned:
        return "pdf_parser_more_strict"
    return "qpdf_more_strict"


def skipped_record(entry: Entry, reason: str, message: str) -> dict[str, object]:
    return {
        "record_type": "structural_compare",
        "category": entry.category,
        "doc_id": entry.doc_id,
        "pdf_path": str(entry.pdf_path),
        "classification": "skipped",
        "reason": reason,
        "message": message,
    }


def render_jsonl(rows: list[dict[str, object]]) -> str:
    return "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows)


if __name__ == "__main__":
    raise SystemExit(main())
