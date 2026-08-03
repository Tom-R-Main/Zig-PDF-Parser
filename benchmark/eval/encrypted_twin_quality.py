#!/usr/bin/env python3
"""Gate encrypted extraction against its unencrypted source twin."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parser", type=Path, default=Path("zig-out/bin/pdf-parser"))
    parser.add_argument("--plain", type=Path, default=Path("benchmark/eval/raw_cache/large/text-100.pdf"))
    parser.add_argument(
        "--encrypted",
        type=Path,
        default=Path("benchmark/eval/raw_cache/large/encrypted-text-100.pdf"),
    )
    parser.add_argument("--password", default="benchmark-password")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def normalize(text: str) -> str:
    return " ".join(text.split())


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def page_count(text: str) -> int:
    trimmed = text.rstrip()
    return 0 if not trimmed else trimmed.count("\f") + 1


def compare_twin_outputs(plain: str, encrypted: str, plain_raw: str, encrypted_raw: str) -> dict[str, object]:
    normalized_plain = normalize(plain)
    normalized_encrypted = normalize(encrypted)
    checks = {
        "normalized_text_equal": normalized_plain == normalized_encrypted,
        "page_count_equal": page_count(plain) == page_count(encrypted),
        "raw_recall_equal": plain_raw == encrypted_raw,
        "encrypted_output_nonempty": bool(normalized_encrypted),
    }
    return {
        "record_type": "encrypted_twin_quality",
        "status": "pass" if all(checks.values()) else "fail",
        "checks": checks,
        "plain": {
            "page_count": page_count(plain),
            "normalized_sha256": sha256(normalized_plain),
            "raw_sha256": sha256(plain_raw),
        },
        "encrypted": {
            "page_count": page_count(encrypted),
            "normalized_sha256": sha256(normalized_encrypted),
            "raw_sha256": sha256(encrypted_raw),
        },
    }


def extract(parser: Path, pdf: Path, *, password: str | None, raw_recall: bool) -> str:
    command = [str(parser), "extract", "--format", "text"]
    if raw_recall:
        command.append("--raw-recall")
    if password is not None:
        command.extend(["--password", password])
    command.append(str(pdf))
    process = subprocess.run(command, text=True, capture_output=True, check=False, timeout=300)
    if process.returncode != 0:
        reason = process.stderr.strip() or f"exit {process.returncode}"
        raise RuntimeError(f"extraction failed for {pdf}: {reason}")
    return process.stdout


def main() -> int:
    args = parse_args()
    for path in (args.parser, args.plain, args.encrypted):
        if not path.exists():
            raise SystemExit(f"missing required path: {path}")

    report = compare_twin_outputs(
        extract(args.parser, args.plain, password=None, raw_recall=False),
        extract(args.parser, args.encrypted, password=args.password, raw_recall=False),
        extract(args.parser, args.plain, password=None, raw_recall=True),
        extract(args.parser, args.encrypted, password=args.password, raw_recall=True),
    )
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
