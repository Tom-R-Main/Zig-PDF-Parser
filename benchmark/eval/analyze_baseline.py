#!/usr/bin/env python3
"""Summarize comparator and lane-profiler JSONL into a baseline report."""

from __future__ import annotations

import argparse
import json
import statistics
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


BASELINE_REPORT_SCHEMA_VERSION = "0.2.0"


def main() -> int:
    return run_cli()


def main_with_args_for_test(args: list[str]) -> int:
    return run_cli(args)


def run_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compare-jsonl", action="append", default=[], help="Comparator JSONL path; repeatable")
    parser.add_argument("--profile-jsonl", action="append", default=[], help="Lane profiler JSONL path; repeatable")
    parser.add_argument("--manifest", action="append", default=[], help="Corpus manifest readiness path; repeatable")
    parser.add_argument("--output", help="Machine-readable summary JSON path; stdout when omitted")
    parser.add_argument("--table-output", help="Human-readable table path")
    parser.add_argument("--top", type=int, default=10, help="Number of slowest/error records to include")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[2]
    compare_paths = [resolve_path(repo_root, value) for value in args.compare_jsonl]
    profile_paths = [resolve_path(repo_root, value) for value in args.profile_jsonl]
    manifest_paths = [resolve_path(repo_root, value) for value in args.manifest]
    report = build_report(
        compare_paths=compare_paths,
        profile_paths=profile_paths,
        manifest_paths=manifest_paths,
        repo_root=repo_root,
        top=args.top,
    )
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"

    if args.output:
        output_path = resolve_path(repo_root, args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output, encoding="utf-8")
    else:
        print(output, end="")

    if args.table_output:
        table_path = resolve_path(repo_root, args.table_output)
        table_path.parent.mkdir(parents=True, exist_ok=True)
        table_path.write_text(render_table(report), encoding="utf-8")
    return 0


def resolve_path(repo_root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else repo_root / path


def build_report(
    *,
    compare_paths: list[Path],
    profile_paths: list[Path],
    manifest_paths: list[Path],
    repo_root: Path,
    top: int,
) -> dict[str, object]:
    compare_records = [record for path in compare_paths for record in read_jsonl(path)]
    profile_records = [record for path in profile_paths for record in read_jsonl(path)]
    manifest_readiness = summarize_manifests(manifest_paths, repo_root)
    return {
        "baseline_report_schema_version": BASELINE_REPORT_SCHEMA_VERSION,
        "record_type": "baseline_report",
        "inputs": {
            "compare_jsonl": [str(path) for path in compare_paths],
            "profile_jsonl": [str(path) for path in profile_paths],
            "manifests": [str(path) for path in manifest_paths],
        },
        "manifest_readiness": manifest_readiness,
        "compare": summarize_compare(compare_records),
        "profile": summarize_profile(profile_records),
        "slowest_profile_records": slowest_records(profile_records, top),
        "problem_records": problem_records(compare_records, profile_records, top),
        "optimization_candidates": optimization_candidates(profile_records, manifest_readiness, top),
        "next_actions": next_actions(manifest_readiness),
    }


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                data = json.loads(stripped)
            except json.JSONDecodeError as err:
                raise ValueError(f"{path}:{line_number}: invalid JSONL: {err}") from err
            if not isinstance(data, dict):
                raise ValueError(f"{path}:{line_number}: expected JSON object")
            rows.append(data)
    return rows


def summarize_manifests(paths: list[Path], repo_root: Path) -> dict[str, object]:
    summaries = [summarize_manifest(path, repo_root) for path in paths]
    total_count = sum(as_int(summary.get("document_count")) or 0 for summary in summaries)
    present_count = sum(as_int(summary.get("present_count")) or 0 for summary in summaries)
    missing_count = sum(as_int(summary.get("missing_count")) or 0 for summary in summaries)
    by_category: dict[str, Summary] = {}
    for summary in summaries:
        category_data = summary.get("by_category")
        if not isinstance(category_data, dict):
            continue
        for category, data in category_data.items():
            if not isinstance(data, dict):
                continue
            target = by_category.setdefault(category, Summary())
            count = as_int(data.get("document_count")) or 0
            present = as_int(data.get("present_count")) or 0
            missing = as_int(data.get("missing_count")) or 0
            target.count += count
            target.ok_count += present
            target.failed_count += missing
    return {
        "manifest_count": len(paths),
        "document_count": total_count,
        "present_count": present_count,
        "missing_count": missing_count,
        "ready": bool(paths) and missing_count == 0,
        "by_manifest": summaries,
        "by_category": {key: value.to_record() for key, value in sorted(by_category.items())},
    }


def summarize_manifest(path: Path, repo_root: Path) -> dict[str, object]:
    rows = read_manifest_rows(path, repo_root)
    present = [row for row in rows if row["exists"]]
    missing = [row for row in rows if not row["exists"]]
    by_category: dict[str, dict[str, int]] = {}
    for row in rows:
        category = str(row["category"])
        counts = by_category.setdefault(category, {"document_count": 0, "present_count": 0, "missing_count": 0})
        counts["document_count"] += 1
        if row["exists"]:
            counts["present_count"] += 1
        else:
            counts["missing_count"] += 1
    return {
        "path": str(path),
        "document_count": len(rows),
        "present_count": len(present),
        "missing_count": len(missing),
        "ready": len(missing) == 0,
        "by_category": by_category,
        "missing": [
            {
                "category": row["category"],
                "doc_id": row["doc_id"],
                "pdf_path": row["pdf_path"],
            }
            for row in missing
        ],
    }


def read_manifest_rows(path: Path, repo_root: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if fields[0] == "category":
                continue
            if len(fields) < 3:
                raise ValueError(f"{path}:{line_number}: malformed manifest row")
            pdf_path = resolve_path(repo_root, fields[2])
            rows.append(
                {
                    "category": fields[0],
                    "doc_id": fields[1],
                    "pdf_path": str(pdf_path),
                    "exists": pdf_path.exists(),
                }
            )
    return rows


@dataclass
class Summary:
    count: int = 0
    ok_count: int = 0
    skipped_count: int = 0
    failed_count: int = 0
    wall_ms: list[float] = field(default_factory=list)
    latency_ms: list[float] = field(default_factory=list)
    parser_latency_ms: list[float] = field(default_factory=list)
    peak_rss_mb: list[float] = field(default_factory=list)
    output_bytes: list[float] = field(default_factory=list)
    metrics: dict[str, list[float]] = field(default_factory=dict)

    def add_status(self, status: object) -> None:
        self.count += 1
        if status == "ok":
            self.ok_count += 1
        elif status == "skipped":
            self.skipped_count += 1
        elif status == "failed":
            self.failed_count += 1

    def add_number(self, name: str, value: object) -> None:
        number = as_float(value)
        if number is None:
            return
        getattr(self, name).append(number)

    def add_metric(self, name: str, value: object) -> None:
        number = as_float(value)
        if number is None:
            return
        self.metrics.setdefault(name, []).append(number)

    def to_record(self) -> dict[str, object]:
        result: dict[str, object] = {
            "count": self.count,
            "ok_count": self.ok_count,
            "skipped_count": self.skipped_count,
            "failed_count": self.failed_count,
            "wall_ms": numeric_summary(self.wall_ms),
            "latency_ms": numeric_summary(self.latency_ms),
            "parser_latency_ms": numeric_summary(self.parser_latency_ms),
            "peak_rss_mb": numeric_summary(self.peak_rss_mb),
            "output_bytes": numeric_summary(self.output_bytes),
        }
        if self.metrics:
            result["metrics"] = {key: numeric_summary(values) for key, values in sorted(self.metrics.items())}
        return result


def summarize_compare(records: list[dict[str, object]]) -> dict[str, object]:
    by_parser = grouped(records, ("parser",))
    by_category_parser = grouped(records, ("category", "parser"))
    return {
        "record_count": len(records),
        "by_parser": {key: summarize_compare_group(value) for key, value in sorted(by_parser.items())},
        "by_category_parser": {
            key: summarize_compare_group(value) for key, value in sorted(by_category_parser.items())
        },
    }


def summarize_compare_group(records: list[dict[str, object]]) -> dict[str, object]:
    summary = Summary()
    for record in records:
        summary.add_status(record.get("status"))
        summary.add_number("latency_ms", record.get("latency_ms"))
        summary.add_number("wall_ms", record.get("wall_ms"))
        summary.add_number("peak_rss_mb", record.get("peak_rss_mb"))
        metrics = record.get("metrics")
        if isinstance(metrics, dict):
            for name, value in metrics.items():
                summary.add_metric(name, value)
    return summary.to_record()


def summarize_profile(records: list[dict[str, object]]) -> dict[str, object]:
    by_lane = grouped(records, ("lane",))
    by_category_lane = grouped(records, ("category", "lane"))
    return {
        "record_count": len(records),
        "by_lane": {key: summarize_profile_group(value) for key, value in sorted(by_lane.items())},
        "by_category_lane": {key: summarize_profile_group(value) for key, value in sorted(by_category_lane.items())},
    }


def summarize_profile_group(records: list[dict[str, object]]) -> dict[str, object]:
    summary = Summary()
    for record in records:
        summary.add_status(record.get("status"))
        summary.add_number("wall_ms", record.get("wall_ms"))
        summary.add_number("parser_latency_ms", record.get("parser_latency_ms"))
        summary.add_number("peak_rss_mb", record.get("peak_rss_mb"))
        summary.add_number("output_bytes", record.get("output_bytes"))
    return summary.to_record()


def grouped(records: list[dict[str, object]], keys: tuple[str, ...]) -> dict[str, list[dict[str, object]]]:
    groups: dict[str, list[dict[str, object]]] = {}
    for record in records:
        group_key = " / ".join(str(record.get(key, "unknown")) for key in keys)
        groups.setdefault(group_key, []).append(record)
    return groups


def numeric_summary(values: Iterable[float]) -> dict[str, float | int | None]:
    numbers = sorted(values)
    if not numbers:
        return {"count": 0, "mean": None, "median": None, "min": None, "max": None}
    return {
        "count": len(numbers),
        "mean": statistics.fmean(numbers),
        "median": statistics.median(numbers),
        "min": numbers[0],
        "max": numbers[-1],
    }


def as_float(value: object) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def as_int(value: object) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def slowest_records(records: list[dict[str, object]], limit: int) -> list[dict[str, object]]:
    candidates = [record for record in records if as_float(record.get("wall_ms")) is not None]
    candidates.sort(key=lambda record: as_float(record.get("wall_ms")) or 0.0, reverse=True)
    return [compact_profile_record(record) for record in candidates[: max(limit, 0)]]


def problem_records(
    compare_records: list[dict[str, object]],
    profile_records: list[dict[str, object]],
    limit: int,
) -> list[dict[str, object]]:
    problems: list[dict[str, object]] = []
    for record in compare_records:
        if record.get("status") != "ok":
            problems.append(
                {
                    "source": "compare",
                    "doc_id": record.get("doc_id"),
                    "category": record.get("category"),
                    "parser": record.get("parser"),
                    "status": record.get("status"),
                    "reason": record.get("reason"),
                }
            )
    for record in profile_records:
        if record.get("status") != "ok":
            problems.append(
                {
                    "source": "profile",
                    "doc_id": record.get("doc_id"),
                    "category": record.get("category"),
                    "lane": record.get("lane"),
                    "status": record.get("status"),
                    "reason": record.get("reason"),
                }
            )
    return problems[: max(limit, 0)]


def optimization_candidates(
    profile_records: list[dict[str, object]],
    manifest_readiness: dict[str, object],
    limit: int,
) -> list[dict[str, object]]:
    groups = grouped([record for record in profile_records if record.get("status") == "ok"], ("category", "lane"))
    candidates: list[dict[str, object]] = []
    large_ready = bool(manifest_readiness.get("ready"))
    for key, records in groups.items():
        wall_values = [value for value in (as_float(record.get("wall_ms")) for record in records) if value is not None]
        if not wall_values:
            continue
        parser_latency_values = [
            value for value in (as_float(record.get("parser_latency_ms")) for record in records) if value is not None
        ]
        rss_values = [value for value in (as_float(record.get("peak_rss_mb")) for record in records) if value is not None]
        output_values = [value for value in (as_float(record.get("output_bytes")) for record in records) if value is not None]
        categories, lane = split_category_lane(key)
        representative_docs = sorted({str(record.get("doc_id")) for record in records if record.get("doc_id")})[:5]
        median_wall_ms = statistics.median(wall_values)
        candidate = {
            "candidate_id": candidate_id(categories, lane),
            "category": categories,
            "lane": lane,
            "evidence_scope": "large-corpus" if large_ready else "tiny-corpus-only",
            "record_count": len(records),
            "representative_docs": representative_docs,
            "median_wall_ms": median_wall_ms,
            "max_wall_ms": max(wall_values),
            "total_wall_ms": sum(wall_values),
            "median_parser_latency_ms": statistics.median(parser_latency_values) if parser_latency_values else None,
            "max_peak_rss_mb": max(rss_values) if rss_values else None,
            "median_output_bytes": statistics.median(output_values) if output_values else None,
            "suggested_focus": suggested_focus(categories, lane),
            "blocked_by_large_corpus": not large_ready,
        }
        candidates.append(candidate)
    candidates.sort(
        key=lambda record: (
            as_float(record.get("median_wall_ms")) or 0.0,
            as_float(record.get("max_wall_ms")) or 0.0,
        ),
        reverse=True,
    )
    return candidates[: max(limit, 0)]


def split_category_lane(group_key: str) -> tuple[str, str]:
    parts = group_key.split(" / ", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return group_key, "unknown"


def candidate_id(category: str, lane: str) -> str:
    return "candidate-" + slug(category) + "-" + slug(lane)


def slug(value: str) -> str:
    return "".join(char.lower() if char.isalnum() else "-" for char in value).strip("-")


def suggested_focus(category: str, lane: str) -> str:
    if category == "scanned_typewritten" or lane == "ocr-routed":
        return "OCR rasterization/subprocess overhead and page/region routing"
    if "stream-jsonl" in lane:
        return "streaming renderer latency, document_finished timing, and per-page buffering"
    if "artifact-jsonl" in lane:
        return "schema JSON rendering allocations and full-result buffering"
    if category == "financial_tables":
        return "table reconstruction, cell assignment, and provenance matching"
    if category == "forms":
        return "form field extraction and widget/value serialization"
    if category == "clean_born_digital":
        return "native text extraction, object resolution, decompression, and output formatting"
    if category == "adversarial_corrupt":
        return "error recovery and permissive parsing overhead"
    return "profile this category/lane before choosing a hot path"


def next_actions(manifest_readiness: dict[str, object]) -> list[dict[str, object]]:
    actions: list[dict[str, object]] = []
    if manifest_readiness.get("manifest_count") and manifest_readiness.get("missing_count"):
        actions.append(
            {
                "action_id": "populate-large-corpus",
                "kind": "network_fetch",
                "reason": "Large corpus inputs are missing; large-document optimization claims are not yet supported.",
                "commands": [
                    ".venv/bin/python benchmark/eval/fetch_large_corpus.py --download --derive",
                    ".venv/bin/python benchmark/eval/fetch_large_corpus.py --verify",
                    ".venv/bin/python benchmark/eval/run_baseline.py --large --require-large",
                ],
            }
        )
    actions.append(
        {
            "action_id": "optimize-first-measured-hot-path",
            "kind": "optimization_slice",
            "reason": "Choose exactly one top optimization candidate and rerun the baseline wrapper before/after.",
            "commands": [
                ".venv/bin/python benchmark/eval/run_baseline.py --large",
                "zig build test --summary all",
                "zig build eval -- --adaptive --ocr-executable tesseract --ocr-rasterizer pdftoppm --manifest benchmark/eval/corpus/manifest.tsv",
            ],
        }
    )
    return actions


def compact_profile_record(record: dict[str, object]) -> dict[str, object]:
    return {
        "doc_id": record.get("doc_id"),
        "category": record.get("category"),
        "lane": record.get("lane"),
        "repeat_index": record.get("repeat_index"),
        "status": record.get("status"),
        "wall_ms": record.get("wall_ms"),
        "parser_latency_ms": record.get("parser_latency_ms"),
        "peak_rss_mb": record.get("peak_rss_mb"),
        "output_bytes": record.get("output_bytes"),
    }


def render_table(report: dict[str, object]) -> str:
    lines = ["# Baseline Report", ""]
    manifest_readiness = report.get("manifest_readiness")
    if isinstance(manifest_readiness, dict):
        lines.extend(render_manifest_readiness(manifest_readiness))
    compare = report.get("compare")
    if isinstance(compare, dict):
        lines.extend(render_group_table("Comparator By Parser", compare.get("by_parser"), label_name="parser"))
    profile = report.get("profile")
    if isinstance(profile, dict):
        lines.extend(render_group_table("Profiler By Lane", profile.get("by_lane"), label_name="lane"))
    candidates = report.get("optimization_candidates")
    if isinstance(candidates, list):
        lines.extend(render_optimization_candidates(candidates))
    slowest = report.get("slowest_profile_records")
    if isinstance(slowest, list) and slowest:
        lines.extend(["## Slowest Profile Records", ""])
        lines.append("doc_id | category | lane | wall_ms | parser_latency_ms | rss_mb | output_bytes")
        lines.append("--- | --- | --- | ---: | ---: | ---: | ---:")
        for record in slowest:
            if isinstance(record, dict):
                lines.append(
                    " | ".join(
                        [
                            str(record.get("doc_id")),
                            str(record.get("category")),
                            str(record.get("lane")),
                            fmt(record.get("wall_ms")),
                            fmt(record.get("parser_latency_ms")),
                            fmt(record.get("peak_rss_mb")),
                            fmt(record.get("output_bytes")),
                        ]
                    )
                )
        lines.append("")
    return "\n".join(lines)


def render_manifest_readiness(data: dict[str, object]) -> list[str]:
    if not data.get("manifest_count"):
        return []
    lines = ["## Manifest Readiness", ""]
    lines.append(
        f"Documents present: {data.get('present_count', 0)}/{data.get('document_count', 0)}. "
        f"Missing: {data.get('missing_count', 0)}."
    )
    lines.append("")
    categories = data.get("by_category")
    if isinstance(categories, dict) and categories:
        lines.append("category | present/total | missing")
        lines.append("--- | ---: | ---:")
        for category, value in sorted(categories.items()):
            if not isinstance(value, dict):
                continue
            lines.append(
                " | ".join(
                    [
                        str(category),
                        f"{value.get('ok_count', 0)}/{value.get('count', 0)}",
                        str(value.get("failed_count", 0)),
                    ]
                )
            )
        lines.append("")
    manifests = data.get("by_manifest")
    if isinstance(manifests, list):
        for manifest in manifests:
            if not isinstance(manifest, dict) or not manifest.get("missing"):
                continue
            lines.append(f"Missing inputs for `{manifest.get('path')}`:")
            lines.append("")
            for missing in manifest.get("missing", []):
                if isinstance(missing, dict):
                    lines.append(f"- `{missing.get('doc_id')}` ({missing.get('category')}): {missing.get('pdf_path')}")
            lines.append("")
    return lines


def render_optimization_candidates(candidates: list[object]) -> list[str]:
    if not candidates:
        return []
    lines = ["## Optimization Candidates", ""]
    lines.append("candidate | scope | median_wall_ms | max_wall_ms | rss_mb max | focus")
    lines.append("--- | --- | ---: | ---: | ---: | ---")
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        lines.append(
            " | ".join(
                [
                    str(candidate.get("candidate_id")),
                    str(candidate.get("evidence_scope")),
                    fmt(candidate.get("median_wall_ms")),
                    fmt(candidate.get("max_wall_ms")),
                    fmt(candidate.get("max_peak_rss_mb")),
                    str(candidate.get("suggested_focus")),
                ]
            )
        )
    lines.append("")
    return lines


def render_group_table(title: str, groups: object, *, label_name: str) -> list[str]:
    if not isinstance(groups, dict) or not groups:
        return []
    lines = [f"## {title}", ""]
    lines.append(f"{label_name} | ok/total | skipped | failed | wall_ms median | latency_ms median | rss_mb max")
    lines.append("--- | ---: | ---: | ---: | ---: | ---: | ---:")
    for key, value in sorted(groups.items()):
        if not isinstance(value, dict):
            continue
        wall = value.get("wall_ms") if isinstance(value.get("wall_ms"), dict) else {}
        latency = value.get("latency_ms") if isinstance(value.get("latency_ms"), dict) else {}
        parser_latency = value.get("parser_latency_ms") if isinstance(value.get("parser_latency_ms"), dict) else {}
        rss = value.get("peak_rss_mb") if isinstance(value.get("peak_rss_mb"), dict) else {}
        displayed_latency = latency.get("median") if isinstance(latency, dict) and latency.get("median") is not None else (
            parser_latency.get("median") if isinstance(parser_latency, dict) else None
        )
        lines.append(
            " | ".join(
                [
                    str(key),
                    f"{value.get('ok_count', 0)}/{value.get('count', 0)}",
                    str(value.get("skipped_count", 0)),
                    str(value.get("failed_count", 0)),
                    fmt(wall.get("median") if isinstance(wall, dict) else None),
                    fmt(displayed_latency),
                    fmt(rss.get("max") if isinstance(rss, dict) else None),
                ]
            )
        )
    lines.append("")
    return lines


def fmt(value: object) -> str:
    number = as_float(value)
    if number is None:
        return "-"
    if abs(number) >= 100:
        return f"{number:.1f}"
    return f"{number:.3f}"


if __name__ == "__main__":
    raise SystemExit(main())
