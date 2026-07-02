#!/usr/bin/env python3
"""Run the benchmark baseline pipeline and emit a grouped report."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_COMPARE_OUTPUT = "benchmark/eval/outputs/comparison/baseline.jsonl"
DEFAULT_TINY_PROFILE_OUTPUT = "benchmark/eval/outputs/profile/baseline-tiny.jsonl"
DEFAULT_OCR_PROFILE_OUTPUT = "benchmark/eval/outputs/profile/baseline-tiny-ocr.jsonl"
DEFAULT_LARGE_PROFILE_OUTPUT = "benchmark/eval/outputs/profile/baseline-large.jsonl"
DEFAULT_LARGE_OCR_PROFILE_OUTPUT = "benchmark/eval/outputs/profile/baseline-large-ocr-sample.jsonl"
DEFAULT_REPORT_JSON = "benchmark/eval/outputs/profile/baseline-report.json"
DEFAULT_REPORT_MD = "benchmark/eval/outputs/profile/baseline-report.md"


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tiny-manifest", default="benchmark/eval/corpus/manifest.tsv")
    parser.add_argument("--large-manifest", default="benchmark/eval/large/manifest.tsv")
    parser.add_argument("--compare-output", default=DEFAULT_COMPARE_OUTPUT)
    parser.add_argument("--tiny-profile-output", default=DEFAULT_TINY_PROFILE_OUTPUT)
    parser.add_argument("--ocr-profile-output", default=DEFAULT_OCR_PROFILE_OUTPUT)
    parser.add_argument("--large-profile-output", default=DEFAULT_LARGE_PROFILE_OUTPUT)
    parser.add_argument("--large-ocr-profile-output", default=DEFAULT_LARGE_OCR_PROFILE_OUTPUT)
    parser.add_argument("--large-ocr-pages", default="1-10", help="Bounded page range for image-heavy OCR sampling")
    parser.add_argument("--report-json", default=DEFAULT_REPORT_JSON)
    parser.add_argument("--report-md", default=DEFAULT_REPORT_MD)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--large", action="store_true", help="Profile the large manifest when all PDFs are present")
    parser.add_argument("--require-large", action="store_true", help="Fail when large manifest PDFs are missing")
    parser.add_argument("--skip-compare", action="store_true")
    parser.add_argument("--skip-tiny-profile", action="store_true")
    parser.add_argument("--skip-ocr-profile", action="store_true")
    parser.add_argument("--skip-releasefast", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running them")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    python = sys.executable
    commands: list[list[str]] = []

    if not args.skip_releasefast:
        commands.append(["zig", "build", "-Doptimize=ReleaseFast", "--summary", "all"])

    if not args.skip_compare:
        commands.append(
            [
                python,
                "benchmark/eval/compare.py",
                "--pdf-parser-adaptive",
                "--tools",
                "pdf-parser,pymupdf,pypdfium2,pdfplumber",
                "--jsonl",
                "--output",
                args.compare_output,
            ]
        )

    if not args.skip_tiny_profile:
        commands.append(
            [
                python,
                "benchmark/eval/profile_lanes.py",
                "--manifest",
                args.tiny_manifest,
                "--lanes",
                "native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl",
                "--repeat",
                str(args.repeat),
                "--output",
                args.tiny_profile_output,
            ]
        )

    if not args.skip_ocr_profile:
        if ocr_tools_available():
            commands.append(
                [
                    python,
                    "benchmark/eval/profile_lanes.py",
                    "--manifest",
                    args.tiny_manifest,
                    "--lanes",
                    "ocr-routed",
                    "--repeat",
                    "1",
                    "--output",
                    args.ocr_profile_output,
                ]
            )
        else:
            print("Skipping OCR profile: tesseract or pdftoppm is unavailable", file=sys.stderr, flush=True)

    large_ready = manifest_inputs_present(repo_root / args.large_manifest, repo_root)
    if args.large and large_ready:
        commands.append(
            [
                python,
                "benchmark/eval/profile_lanes.py",
                "--manifest",
                args.large_manifest,
                "--lanes",
                "native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl",
                "--exclude-category",
                "scanned_typewritten",
                "--repeat",
                str(args.repeat),
                "--output",
                args.large_profile_output,
            ]
        )
        if args.large_ocr_pages:
            commands.append(
                [
                    python,
                    "benchmark/eval/profile_lanes.py",
                    "--manifest",
                    args.large_manifest,
                    "--lanes",
                    "adaptive-artifact-jsonl,adaptive-stream-jsonl,ocr-routed",
                    "--category",
                    "scanned_typewritten",
                    "--pages",
                    args.large_ocr_pages,
                    "--repeat",
                    "1",
                    "--output",
                    args.large_ocr_profile_output,
                ]
            )
    elif args.large:
        message = f"Large manifest inputs are missing; run fetch_large_corpus.py --download --derive first: {args.large_manifest}"
        if args.require_large:
            print(message, file=sys.stderr, flush=True)
            return 1
        print(f"Skipping large profile: {message}", file=sys.stderr, flush=True)

    analyze_cmd = [
        python,
        "benchmark/eval/analyze_baseline.py",
        "--manifest",
        args.large_manifest,
        "--output",
        args.report_json,
        "--table-output",
        args.report_md,
    ]
    add_existing_jsonl(repo_root, analyze_cmd, "--compare-jsonl", args.compare_output, planned=not args.skip_compare)
    add_existing_jsonl(repo_root, analyze_cmd, "--profile-jsonl", args.tiny_profile_output, planned=not args.skip_tiny_profile)
    add_existing_jsonl(repo_root, analyze_cmd, "--profile-jsonl", args.ocr_profile_output, planned=not args.skip_ocr_profile)
    add_existing_jsonl(repo_root, analyze_cmd, "--profile-jsonl", args.large_profile_output, planned=args.large and large_ready)
    add_existing_jsonl(
        repo_root,
        analyze_cmd,
        "--profile-jsonl",
        args.large_ocr_profile_output,
        planned=args.large and large_ready and bool(args.large_ocr_pages),
    )
    commands.append(analyze_cmd)

    for cmd in commands:
        print_command(cmd)
        if args.dry_run:
            continue
        proc = subprocess.run(cmd, cwd=repo_root, check=False)
        if proc.returncode != 0:
            return proc.returncode
    return 0


def ocr_tools_available() -> bool:
    return shutil.which("tesseract") is not None and shutil.which("pdftoppm") is not None


def manifest_inputs_present(path: Path, repo_root: Path) -> bool:
    if not path.exists():
        return False
    with path.open("r", encoding="utf-8") as handle:
        saw_row = False
        for raw_line in handle:
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if fields[0] == "category":
                continue
            if len(fields) < 3:
                return False
            saw_row = True
            pdf_path = Path(fields[2])
            if not pdf_path.is_absolute():
                pdf_path = repo_root / pdf_path
            if not pdf_path.exists():
                return False
        return saw_row


def add_existing_jsonl(
    repo_root: Path,
    cmd: list[str],
    flag: str,
    value: str,
    *,
    planned: bool,
) -> None:
    path = Path(value)
    if not path.is_absolute():
        path = repo_root / path
    if planned or path.exists():
        cmd.extend([flag, value])


def print_command(cmd: list[str]) -> None:
    print("+ " + " ".join(shell_quote(part) for part in cmd), flush=True)


def shell_quote(value: str) -> str:
    if value and all(char.isalnum() or char in "/._=-,:+" for char in value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


if __name__ == "__main__":
    raise SystemExit(main())
