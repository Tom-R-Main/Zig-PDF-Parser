#!/usr/bin/env python3
"""Fetch and derive local large-corpus PDFs for performance benchmarks."""

from __future__ import annotations

import argparse
import csv
import hashlib
import shutil
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path


DEFAULT_SOURCES = "benchmark/eval/large/sources.tsv"
DOWNLOAD_USER_AGENT = "pdf-parser-benchmark/0.1 contact local-benchmark@example.invalid"


@dataclass(frozen=True)
class SourceRow:
    doc_id: str
    category: str
    kind: str
    url: str
    source_doc_id: str
    cache_path: Path
    derive_recipe: str
    password: str
    sha256: str
    license_status: str
    source_note: str


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", default=DEFAULT_SOURCES, help="TSV source/derivative manifest")
    parser.add_argument("--dry-run", action="store_true", help="Print planned actions without writing files")
    parser.add_argument("--download", action="store_true", help="Download source PDFs")
    parser.add_argument("--derive", action="store_true", help="Create qpdf-derived benchmark PDFs")
    parser.add_argument("--verify", action="store_true", help="Verify expected files and SHA256 values")
    parser.add_argument("--force", action="store_true", help="Overwrite existing cache files")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    rows = load_sources(repo_root / args.sources, repo_root)
    if args.dry_run or not (args.download or args.derive or args.verify):
        print_plan(rows)
    status = 0
    if args.download:
        status |= download_sources(rows, force=args.force, dry_run=args.dry_run)
    if args.derive:
        status |= derive_sources(rows, force=args.force, dry_run=args.dry_run)
    if args.verify:
        status |= verify_sources(rows)
    return status


def load_sources(path: Path, repo_root: Path) -> list[SourceRow]:
    rows: list[SourceRow] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader((line for line in handle if not line.startswith("#")), delimiter="\t")
        required = {
            "doc_id",
            "category",
            "kind",
            "url",
            "source_doc_id",
            "cache_path",
            "derive_recipe",
            "password",
            "sha256",
            "license_status",
            "source_note",
        }
        if reader.fieldnames is None or not required.issubset(set(reader.fieldnames)):
            missing = sorted(required - set(reader.fieldnames or ()))
            raise SystemExit(f"Malformed sources manifest; missing columns: {', '.join(missing)}")
        for raw in reader:
            cache_path = repo_root / raw["cache_path"]
            rows.append(
                SourceRow(
                    doc_id=raw["doc_id"],
                    category=raw["category"],
                    kind=raw["kind"],
                    url=raw["url"],
                    source_doc_id=raw["source_doc_id"],
                    cache_path=cache_path,
                    derive_recipe=raw["derive_recipe"],
                    password=raw["password"],
                    sha256=raw["sha256"],
                    license_status=raw["license_status"],
                    source_note=raw["source_note"],
                )
            )
    return rows


def print_plan(rows: list[SourceRow]) -> None:
    for row in rows:
        if row.kind == "source":
            action = f"download {row.url}"
        elif row.kind == "derived":
            action = f"derive {row.derive_recipe} from {row.source_doc_id}"
        else:
            action = f"unknown kind {row.kind}"
        print(f"{row.doc_id}\t{row.category}\t{row.cache_path}\t{action}")


def download_sources(rows: list[SourceRow], *, force: bool, dry_run: bool) -> int:
    status = 0
    for row in rows:
        if row.kind != "source":
            continue
        if not row.url:
            print(f"{row.doc_id}: source row has no URL", file=sys.stderr)
            status = 1
            continue
        if row.cache_path.exists() and not force:
            print(f"{row.doc_id}: exists, skipping {row.cache_path}")
            continue
        print(f"{row.doc_id}: download {row.url} -> {row.cache_path}")
        if dry_run:
            continue
        row.cache_path.parent.mkdir(parents=True, exist_ok=True)
        download_url(row.url, row.cache_path)
    return status


def download_url(url: str, dest: Path) -> None:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": DOWNLOAD_USER_AGENT,
            "Accept": "application/pdf,*/*",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response, dest.open("wb") as handle:
        shutil.copyfileobj(response, handle)


def derive_sources(rows: list[SourceRow], *, force: bool, dry_run: bool) -> int:
    rows_by_id = {row.doc_id: row for row in rows}
    qpdf = shutil.which("qpdf")
    if qpdf is None:
        print("qpdf is required for --derive", file=sys.stderr)
        return 1
    status = 0
    for row in rows:
        if row.kind != "derived":
            continue
        source = rows_by_id.get(row.source_doc_id)
        if source is None:
            print(f"{row.doc_id}: missing source_doc_id {row.source_doc_id}", file=sys.stderr)
            status = 1
            continue
        if not source.cache_path.exists():
            print(f"{row.doc_id}: source file missing: {source.cache_path}", file=sys.stderr)
            status = 1
            continue
        if row.cache_path.exists() and not force:
            print(f"{row.doc_id}: exists, skipping {row.cache_path}")
            continue
        cmd = qpdf_command(qpdf, source.cache_path, row.cache_path, row.derive_recipe, row.password)
        print(f"{row.doc_id}: {' '.join(cmd)}")
        if dry_run:
            continue
        row.cache_path.parent.mkdir(parents=True, exist_ok=True)
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            print(proc.stderr.strip() or f"{row.doc_id}: qpdf exited {proc.returncode}", file=sys.stderr)
            status = 1
    return status


def qpdf_command(qpdf: str, source: Path, dest: Path, recipe: str, password: str) -> list[str]:
    if recipe.startswith("pages:"):
        pages = recipe.removeprefix("pages:")
        return [qpdf, str(source), "--pages", str(source), pages, "--", str(dest)]
    if recipe == "object-streams":
        return [qpdf, "--object-streams=generate", str(source), str(dest)]
    if recipe == "encrypt-aes256":
        user_password = password or "benchmark-password"
        owner_password = f"{user_password}-owner"
        return [qpdf, "--encrypt", user_password, owner_password, "256", "--", str(source), str(dest)]
    raise SystemExit(f"Unknown derive recipe: {recipe}")


def verify_sources(rows: list[SourceRow]) -> int:
    status = 0
    for row in rows:
        if not row.cache_path.exists():
            print(f"{row.doc_id}: missing {row.cache_path}", file=sys.stderr)
            status = 1
            continue
        actual = sha256_file(row.cache_path)
        if row.sha256 and actual != row.sha256:
            print(f"{row.doc_id}: sha256 mismatch {actual} != {row.sha256}", file=sys.stderr)
            status = 1
        else:
            print(f"{row.doc_id}: ok {actual}")
    return status


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    raise SystemExit(main())
