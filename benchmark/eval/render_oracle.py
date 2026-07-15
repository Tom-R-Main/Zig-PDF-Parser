#!/usr/bin/env python3
"""Render-backed differential checks for extraction geometry.

This is benchmark evidence, not a parser dependency. It renders pages with an
external engine, maps public PDF-coordinate artifacts into raster pixels, and
reports coverage signals for visual QA cases such as clipped text, invisible OCR
layers, ruled tables, image-heavy regions, and rotated geometry.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image


RENDER_ORACLE_SCHEMA_VERSION = "0.1.0"
DEFAULT_RENDERERS = ("poppler",)
ALL_RENDERERS = ("poppler", "pypdfium2", "mutool")
REQUIRED_TRUTH_KEYS = {
    "expected_page_count",
    "expected_issue_tags",
    "min_text_bbox_coverage",
    "max_blank_bbox_rate",
    "min_ruling_pixel_coverage",
    "min_image_region_overlap",
}


@dataclass(frozen=True)
class Entry:
    category: str
    doc_id: str
    pdf_path: Path
    truth_text_path: Path | None
    render_truth_path: Path | None
    visual_case_tags: tuple[str, ...]


@dataclass(frozen=True)
class ViewBox:
    x: float
    y: float
    width: float
    height: float


@dataclass(frozen=True)
class PixelBox:
    x0: int
    y0: int
    x1: int
    y1: int


class OptionalRendererMissing(RuntimeError):
    pass


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="benchmark/eval/corpus/manifest.tsv")
    parser.add_argument("--renderer", default=",".join(DEFAULT_RENDERERS), help="'all' or comma-separated renderer list")
    parser.add_argument("--dpi", type=int, default=144)
    parser.add_argument("--output", help="JSONL output path; stdout when omitted")
    parser.add_argument("--category", action="append", default=[], help="Only inspect matching category; repeatable")
    parser.add_argument("--doc-id", action="append", default=[], help="Only inspect matching doc id; repeatable")
    parser.add_argument("--require-renderers", action="store_true")
    parser.add_argument("--pdf-parser-command", default="zig-out/bin/pdf-parser")
    parser.add_argument("--ensure-releasefast", dest="ensure_releasefast", action="store_true")
    parser.add_argument("--no-ensure-releasefast", dest="ensure_releasefast", action="store_false")
    parser.add_argument("--materialize-dir", help="Write rendered pages and low-coverage crops under this directory")
    parser.set_defaults(ensure_releasefast=True)
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    parser_command = resolve_path(repo_root, args.pdf_parser_command)
    if args.ensure_releasefast:
        ensure_releasefast(repo_root, parser_command)

    entries = filter_entries(
        load_entries(resolve_path(repo_root, args.manifest), repo_root),
        set(args.category),
        set(args.doc_id),
    )
    renderers = parse_renderers(args.renderer)
    output_handle = None
    failure_count = 0
    materialize_dir = resolve_path(repo_root, args.materialize_dir) if args.materialize_dir else None
    if materialize_dir is not None:
        materialize_dir.mkdir(parents=True, exist_ok=True)
    if args.output:
        output_path = resolve_path(repo_root, args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_handle = output_path.open("w", encoding="utf-8")
    try:
        for entry in entries:
            truth = load_render_truth(entry)
            for renderer in renderers:
                rows = run_entry(
                    repo_root=repo_root,
                    parser_command=parser_command,
                    entry=entry,
                    truth=truth,
                    renderer=renderer,
                    dpi=args.dpi,
                    require_renderers=args.require_renderers,
                    materialize_dir=materialize_dir,
                )
                for row in rows:
                    if row["status"] == "failed":
                        failure_count += 1
                    write_row(output_handle, row)
    finally:
        if output_handle is not None:
            output_handle.close()
    return 1 if failure_count else 0


def parse_renderers(value: str) -> tuple[str, ...]:
    if value.strip() == "all":
        return ALL_RENDERERS
    return tuple(renderer.strip() for renderer in value.split(",") if renderer.strip())


def resolve_path(repo_root: Path, value: str | Path | None) -> Path:
    if value is None:
        raise ValueError("path value is required")
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
        if entry.render_truth_path is not None
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
            if fields[0] == "category":
                continue
            if len(fields) < 3:
                raise ValueError(f"Malformed manifest row: {fields!r}")
            meta = metadata.get((fields[0], fields[1]), {})
            truth_text_path = resolve_manifest_path(repo_root, fields[3]) if len(fields) >= 4 and fields[3] else None
            render_truth_path = meta.get("render_truth_path")
            entries.append(
                Entry(
                    category=fields[0],
                    doc_id=fields[1],
                    pdf_path=resolve_manifest_path(repo_root, fields[2]),
                    truth_text_path=truth_text_path,
                    render_truth_path=resolve_manifest_path(repo_root, render_truth_path) if render_truth_path else None,
                    visual_case_tags=tuple(meta.get("visual_case_tags", [])),
                )
            )
    return entries


def load_metadata(path: Path) -> dict[tuple[str, str], dict[str, Any]]:
    if not path.exists():
        return {}
    rows: dict[tuple[str, str], dict[str, Any]] = {}
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                row = json.loads(line)
                rows[(row["category"], row["doc_id"])] = row
    return rows


def resolve_manifest_path(repo_root: Path, value: str | Path) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def load_render_truth(entry: Entry) -> dict[str, Any]:
    if entry.render_truth_path is None:
        raise ValueError(f"{entry.doc_id} is missing render_truth_path metadata")
    with entry.render_truth_path.open("r", encoding="utf-8") as handle:
        truth = json.load(handle)
    validate_render_truth(truth)
    return truth


def validate_render_truth(truth: dict[str, Any]) -> None:
    missing = sorted(REQUIRED_TRUTH_KEYS.difference(truth))
    if missing:
        raise ValueError(f"render truth missing keys: {', '.join(missing)}")
    if not isinstance(truth["expected_issue_tags"], list):
        raise ValueError("expected_issue_tags must be a list")


def run_entry(
    *,
    repo_root: Path,
    parser_command: Path,
    entry: Entry,
    truth: dict[str, Any],
    renderer: str,
    dpi: int,
    require_renderers: bool,
    materialize_dir: Path | None,
) -> list[dict[str, Any]]:
    started = time.perf_counter()
    try:
        with tempfile.TemporaryDirectory(prefix="pdf-parser-render-oracle-") as temp_dir:
            temp_path = Path(temp_dir)
            artifacts = extract_pdf_parser(repo_root, parser_command, entry, temp_path)
            page_count = int(truth["expected_page_count"])
            validate_page_count(artifacts, page_count)
            rows: list[dict[str, Any]] = []
            for page_index in range(page_count):
                try:
                    rendered = render_page(renderer, entry.pdf_path, page_index, dpi, temp_path)
                except OptionalRendererMissing as err:
                    if require_renderers:
                        rows.append(failed(entry, renderer, str(err)))
                    else:
                        rows.append(skipped(entry, renderer, str(err)))
                    continue
                row = evaluate_page(
                    repo_root=repo_root,
                    entry=entry,
                    truth=truth,
                    artifacts=artifacts,
                    image=rendered,
                    renderer=renderer,
                    dpi=dpi,
                    page_index=page_index,
                    materialize_dir=materialize_dir,
                )
                row["wall_ms"] = round((time.perf_counter() - started) * 1000.0, 3)
                rows.append(row)
            return rows
    except Exception as err:
        return [failed(entry, renderer, str(err))]


def extract_pdf_parser(repo_root: Path, parser_command: Path, entry: Entry, temp_path: Path) -> list[dict[str, Any]]:
    output_path = temp_path / "artifacts.jsonl"
    debug_dir = temp_path / "debug"
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
    return read_jsonl(output_path)


def artifact_page_count(artifacts: list[dict[str, Any]]) -> int:
    manifests = [record for record in artifacts if record.get("record_type") == "document_manifest"]
    if len(manifests) != 1:
        raise ValueError(f"expected one document_manifest, got {len(manifests)}")
    value = manifests[0].get("page_count")
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("document_manifest page_count must be a non-negative integer")
    return value


def validate_page_count(artifacts: list[dict[str, Any]], expected_page_count: int) -> None:
    actual_page_count = artifact_page_count(artifacts)
    if actual_page_count != expected_page_count:
        raise ValueError(f"page count mismatch: expected {expected_page_count}, got {actual_page_count}")


def render_page(renderer: str, pdf_path: Path, page_index: int, dpi: int, temp_path: Path) -> Image.Image:
    if renderer == "poppler":
        return render_poppler(pdf_path, page_index, dpi, temp_path)
    if renderer == "mutool":
        return render_mutool(pdf_path, page_index, dpi, temp_path)
    if renderer == "pypdfium2":
        return render_pypdfium2(pdf_path, page_index, dpi)
    raise OptionalRendererMissing(f"unknown renderer: {renderer}")


def build_poppler_command(pdf_path: Path, page_index: int, dpi: int, output_prefix: Path) -> list[str]:
    return [
        "pdftoppm",
        "-q",
        "-png",
        "-singlefile",
        "-r",
        str(dpi),
        "-f",
        str(page_index + 1),
        "-l",
        str(page_index + 1),
        str(pdf_path),
        str(output_prefix),
    ]


def render_poppler(pdf_path: Path, page_index: int, dpi: int, temp_path: Path) -> Image.Image:
    if shutil.which("pdftoppm") is None:
        raise OptionalRendererMissing("pdftoppm is not installed")
    output_prefix = temp_path / f"poppler-page-{page_index + 1:04d}"
    proc = subprocess.run(build_poppler_command(pdf_path, page_index, dpi, output_prefix), text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "pdftoppm failed")
    return Image.open(output_prefix.with_suffix(".png")).convert("RGB")


def render_mutool(pdf_path: Path, page_index: int, dpi: int, temp_path: Path) -> Image.Image:
    if shutil.which("mutool") is None:
        raise OptionalRendererMissing("mutool is not installed")
    output_path = temp_path / f"mutool-page-{page_index + 1:04d}.png"
    cmd = ["mutool", "draw", "-q", "-r", str(dpi), "-o", str(output_path), str(pdf_path), str(page_index + 1)]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "mutool draw failed")
    return Image.open(output_path).convert("RGB")


def render_pypdfium2(pdf_path: Path, page_index: int, dpi: int) -> Image.Image:
    try:
        import pypdfium2 as pdfium  # type: ignore
    except ImportError as err:
        raise OptionalRendererMissing("pypdfium2 is not installed") from err

    doc = pdfium.PdfDocument(str(pdf_path))
    try:
        page = doc[page_index]
        try:
            return page.render(scale=dpi / 72.0).to_pil().convert("RGB")
        finally:
            page.close()
    finally:
        doc.close()


def evaluate_page(
    *,
    repo_root: Path,
    entry: Entry,
    truth: dict[str, Any],
    artifacts: list[dict[str, Any]],
    image: Image.Image,
    renderer: str,
    dpi: int,
    page_index: int,
    materialize_dir: Path | None,
) -> dict[str, Any]:
    page_records = [record for record in artifacts if record.get("page_index") == page_index]
    viewbox = page_viewbox(repo_root, artifacts, page_index) or ViewBox(0.0, 0.0, 612.0, 792.0)
    spans = [record for record in page_records if record.get("record_type") == "span" and record.get("bbox")]
    blocks = [record for record in page_records if record.get("record_type") == "block" and record.get("bbox")]
    tables = [record for record in page_records if record.get("record_type") == "table" and record.get("bbox")]
    routes = [record for record in page_records if record.get("record_type") == "route_trace" and record.get("bbox")]

    text_scores = [ink_density(image, bbox_to_pixels(record["bbox"], viewbox, image.size)) for record in spans]
    text_bbox_coverage = coverage_rate(text_scores, 0.01)
    blank_bbox_rate = 1.0 - coverage_rate(text_scores, 0.001)
    low_ink_rate = low_ink_coverage_rate(text_scores)
    ruling_pixel_coverage = max((ruling_score(image, bbox_to_pixels(table["bbox"], viewbox, image.size)) for table in tables), default=0.0)
    image_region_overlap = max((ink_density(image, bbox_to_pixels(route["bbox"], viewbox, image.size)) for route in routes), default=0.0)

    observed_tags = observed_issue_tags(
        text_bbox_coverage=text_bbox_coverage,
        blank_bbox_rate=blank_bbox_rate,
        low_ink_rate=low_ink_rate,
        ruling_pixel_coverage=ruling_pixel_coverage,
        image_region_overlap=image_region_overlap,
        rotated_geometry=rotation_geometry_observed(viewbox, image.size),
    )
    expectations = expectation_results(
        truth,
        text_bbox_coverage,
        blank_bbox_rate,
        ruling_pixel_coverage,
        image_region_overlap,
        observed_tags,
    )
    materialized_assets = materialize_assets(
        materialize_dir,
        entry,
        renderer,
        page_index,
        image,
        spans,
        viewbox,
    )
    return {
        "record_type": "render_oracle_page",
        "render_oracle_schema_version": RENDER_ORACLE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "pdf_path": str(entry.pdf_path),
        "page_index": page_index,
        "renderer": renderer,
        "dpi": dpi,
        "status": "ok" if all(expectations.values()) else "failed",
        "reason": expectation_failure_reason(expectations),
        "visual_case_tags": list(entry.visual_case_tags),
        "expected_issue_tags": list(truth["expected_issue_tags"]),
        "observed_issue_tags": observed_tags,
        "expectations": expectations,
        "text_bbox_coverage": round(text_bbox_coverage, 6),
        "blank_bbox_rate": round(blank_bbox_rate, 6),
        "low_ink_rate": round(low_ink_rate, 6),
        "ruling_pixel_coverage": round(ruling_pixel_coverage, 6),
        "image_region_overlap": round(image_region_overlap, 6),
        "span_count": len(spans),
        "block_count": len(blocks),
        "table_count": len(tables),
        "route_count": len(routes),
        "viewbox": viewbox.__dict__,
        "rendered_size": {"width": image.size[0], "height": image.size[1]},
        "clipped_or_invisible_flags": [tag for tag in observed_tags if tag in {"clipped_text", "invisible_text"}],
        "materialized_assets": materialized_assets,
        "notes": notes_for_page(truth, viewbox, image.size),
    }


def page_viewbox(repo_root: Path, artifacts: list[dict[str, Any]], page_index: int) -> ViewBox | None:
    for row in artifacts:
        if row.get("record_type") != "debug_asset" or row.get("asset_kind") != "page_overlay_svg":
            continue
        if row.get("page_index") != page_index:
            continue
        raw_path = row.get("path")
        if not raw_path:
            continue
        path = Path(str(raw_path))
        if not path.is_absolute():
            path = repo_root / path
        if path.exists():
            return parse_viewbox(path.read_text(encoding="utf-8", errors="replace"))
    return None


def parse_viewbox(svg_text: str) -> ViewBox:
    match = re.search(r'viewBox="([^"]+)"', svg_text)
    if match is None:
        raise ValueError("SVG overlay is missing viewBox")
    parts = [float(part) for part in match.group(1).replace(",", " ").split()]
    if len(parts) != 4:
        raise ValueError(f"invalid SVG viewBox: {match.group(1)}")
    return ViewBox(parts[0], parts[1], parts[2], parts[3])


def bbox_to_pixels(bbox: dict[str, Any], viewbox: ViewBox, image_size: tuple[int, int]) -> PixelBox:
    scale_x = image_size[0] / viewbox.width
    scale_y = image_size[1] / viewbox.height
    x0 = int(math.floor((float(bbox["x0"]) - viewbox.x) * scale_x))
    x1 = int(math.ceil((float(bbox["x1"]) - viewbox.x) * scale_x))
    y0 = int(math.floor((viewbox.y + viewbox.height - float(bbox["y1"])) * scale_y))
    y1 = int(math.ceil((viewbox.y + viewbox.height - float(bbox["y0"])) * scale_y))
    return clamp_pixel_box(PixelBox(x0, y0, x1, y1), image_size)


def clamp_pixel_box(box: PixelBox, image_size: tuple[int, int]) -> PixelBox:
    width, height = image_size
    return PixelBox(
        max(0, min(width, box.x0)),
        max(0, min(height, box.y0)),
        max(0, min(width, box.x1)),
        max(0, min(height, box.y1)),
    )


def ink_density(image: Image.Image, box: PixelBox) -> float:
    if box.x1 <= box.x0 or box.y1 <= box.y0:
        return 0.0
    crop = image.crop((box.x0, box.y0, box.x1, box.y1)).convert("L")
    total = crop.size[0] * crop.size[1]
    if total == 0:
        return 0.0
    histogram = crop.histogram()
    ink = sum(histogram[:245])
    return ink / total


def ruling_score(image: Image.Image, box: PixelBox) -> float:
    if box.x1 <= box.x0 or box.y1 <= box.y0:
        return 0.0
    crop = image.crop((box.x0, box.y0, box.x1, box.y1)).convert("L")
    width, height = crop.size
    if width == 0 or height == 0:
        return 0.0
    rows = 0
    for y in range(height):
        dark = sum(1 for x in range(width) if crop.getpixel((x, y)) < 80)
        if dark / width >= 0.25:
            rows += 1
    cols = 0
    for x in range(width):
        dark = sum(1 for y in range(height) if crop.getpixel((x, y)) < 80)
        if dark / height >= 0.25:
            cols += 1
    return min(1.0, (rows + cols) / 8.0)


def coverage_rate(values: list[float], threshold: float) -> float:
    if not values:
        return 0.0
    return sum(1 for value in values if value >= threshold) / len(values)


def low_ink_coverage_rate(values: list[float]) -> float:
    if not values:
        return 0.0
    return sum(1 for value in values if 0.001 <= value < 0.01) / len(values)


def observed_issue_tags(
    *,
    text_bbox_coverage: float,
    blank_bbox_rate: float,
    low_ink_rate: float,
    ruling_pixel_coverage: float,
    image_region_overlap: float,
    rotated_geometry: bool,
) -> list[str]:
    tags: set[str] = set()
    if blank_bbox_rate > 0.0:
        tags.add("invisible_text")
    if blank_bbox_rate > 0.0 or low_ink_rate > 0.0 or 0.0 < text_bbox_coverage < 1.0:
        tags.add("clipped_text")
    if ruling_pixel_coverage > 0.0:
        tags.add("ruling_lines")
    if image_region_overlap > 0.0:
        tags.add("image_region")
    if rotated_geometry:
        tags.add("rotated_geometry")
    return sorted(tags)


def rotation_geometry_observed(viewbox: ViewBox, image_size: tuple[int, int]) -> bool:
    viewbox_landscape = viewbox.width > viewbox.height
    image_landscape = image_size[0] > image_size[1]
    return viewbox_landscape != image_landscape


def expectation_results(
    truth: dict[str, Any],
    text_bbox_coverage: float,
    blank_bbox_rate: float,
    ruling_pixel_coverage: float,
    image_region_overlap: float,
    observed_tags: list[str],
) -> dict[str, Any]:
    expected_tags = set(str(tag) for tag in truth["expected_issue_tags"])
    return {
        "issue_tags_ok": expected_tags.issubset(set(observed_tags)),
        "text_bbox_coverage_ok": text_bbox_coverage >= float(truth["min_text_bbox_coverage"]),
        "blank_bbox_rate_ok": blank_bbox_rate <= float(truth["max_blank_bbox_rate"]),
        "ruling_pixel_coverage_ok": ruling_pixel_coverage >= float(truth["min_ruling_pixel_coverage"]),
        "image_region_overlap_ok": image_region_overlap >= float(truth["min_image_region_overlap"]),
    }


def expectation_failure_reason(expectations: dict[str, Any]) -> str | None:
    failed = sorted(key for key, value in expectations.items() if value is not True)
    return None if not failed else f"failed expectations: {', '.join(failed)}"


def materialize_assets(
    materialize_dir: Path | None,
    entry: Entry,
    renderer: str,
    page_index: int,
    image: Image.Image,
    spans: list[dict[str, Any]],
    viewbox: ViewBox,
) -> list[dict[str, Any]]:
    if materialize_dir is None:
        return []
    page_dir = materialize_dir / entry.doc_id
    page_dir.mkdir(parents=True, exist_ok=True)
    assets: list[dict[str, Any]] = []
    page_path = page_dir / f"page-{page_index + 1:04d}.{renderer}.png"
    image.save(page_path)
    assets.append(file_asset("rendered_page_png", page_path))
    for index, span in enumerate(spans[:8]):
        density = ink_density(image, bbox_to_pixels(span["bbox"], viewbox, image.size))
        if density >= 0.01:
            continue
        crop_box = bbox_to_pixels(span["bbox"], viewbox, image.size)
        if crop_box.x1 <= crop_box.x0 or crop_box.y1 <= crop_box.y0:
            continue
        crop = image.crop((crop_box.x0, crop_box.y0, crop_box.x1, crop_box.y1))
        crop_path = page_dir / f"page-{page_index + 1:04d}.{renderer}.low-ink-span-{index:03d}.png"
        crop.save(crop_path)
        assets.append(file_asset("low_ink_crop_png", crop_path))
    return assets


def file_asset(kind: str, path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    return {
        "kind": kind,
        "path": str(path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "byte_length": len(data),
    }


def notes_for_page(truth: dict[str, Any], viewbox: ViewBox, image_size: tuple[int, int]) -> list[str]:
    notes: list[str] = []
    if "rotated_geometry" in truth["expected_issue_tags"] and not rotation_geometry_observed(viewbox, image_size):
        notes.append("rotation_unverified")
    return notes


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def write_row(output_handle, row: dict[str, Any]) -> None:
    line = json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
    if output_handle is None:
        print(line, end="", flush=True)
    else:
        output_handle.write(line)
        output_handle.flush()


def skipped(entry: Entry, renderer: str, reason: str) -> dict[str, Any]:
    return {
        "record_type": "render_oracle_page",
        "render_oracle_schema_version": RENDER_ORACLE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "renderer": renderer,
        "status": "skipped",
        "reason": reason,
    }


def failed(entry: Entry, renderer: str, reason: str) -> dict[str, Any]:
    return {
        "record_type": "render_oracle_page",
        "render_oracle_schema_version": RENDER_ORACLE_SCHEMA_VERSION,
        "category": entry.category,
        "doc_id": entry.doc_id,
        "renderer": renderer,
        "status": "failed",
        "reason": reason,
    }


if __name__ == "__main__":
    raise SystemExit(main())
