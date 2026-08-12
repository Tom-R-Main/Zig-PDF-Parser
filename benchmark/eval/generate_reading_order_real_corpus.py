#!/usr/bin/env python3
"""Prepare the frozen PDF-READORDER-02 real-page experiment corpus.

The source annual report is deliberately kept in the ignored large-document
cache. This script verifies its exact digest, derives twelve one-page PDFs,
and writes the relation truth used by the optional experiment lane.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


EVAL_ROOT = Path(__file__).resolve().parent
REPO_ROOT = EVAL_ROOT.parent.parent
DEFAULT_SOURCE = EVAL_ROOT / "raw_cache" / "large" / "table-heavy-sec.pdf"
OUTPUT_ROOT = EVAL_ROOT / "reading_order_real"
SOURCE_SHA256 = "943cec3d492a966b4b29a15154aaf7c46a81465c958510c44301b0ffa01e4d5e"


@dataclass(frozen=True)
class Node:
    id: str
    anchor: str


@dataclass(frozen=True)
class Fixture:
    page: int
    split: str
    family: str
    nodes: tuple[Node, ...]
    required: tuple[tuple[str, str], ...]
    forbidden: tuple[tuple[str, str], ...]
    ambiguous: tuple[tuple[str, str], ...]

    @property
    def doc_id(self) -> str:
        return f"reading-order-real-sec-{self.page:03d}-{self.split}"


def fixture(
    page: int,
    split: str,
    family: str,
    nodes: list[tuple[str, str]],
    required: list[tuple[str, str]],
    forbidden: list[tuple[str, str]],
    ambiguous: list[tuple[str, str]],
) -> Fixture:
    return Fixture(
        page=page,
        split=split,
        family=family,
        nodes=tuple(Node(*node) for node in nodes),
        required=tuple(required),
        forbidden=tuple(forbidden),
        ambiguous=tuple(ambiguous),
    )


def fixtures() -> tuple[Fixture, ...]:
    return (
        fixture(
            5,
            "dev",
            "two-column-callouts",
            [
                ("left_heading", "To our shareholders"),
                ("left_section", "Delivering consistent, long-term results"),
                ("left_tail", "Net interest income reached a low"),
                ("stat_card", "net income in 2024"),
                ("right_chart", "2024 BAC stock performance"),
                ("right_body", "every employee’s responsibility to find"),
                ("right_section", "Creating opportunity for those"),
            ],
            [
                ("left_heading", "left_section"),
                ("left_section", "left_tail"),
                ("right_chart", "right_body"),
                ("right_body", "right_section"),
            ],
            [("right_body", "left_heading")],
            [("stat_card", "right_body"), ("stat_card", "right_section")],
        ),
        fixture(
            6,
            "dev",
            "staggered-columns-quote",
            [
                ("top_right", "These communities needed a bank"),
                ("left_start", "U.S. capitalism is still the engine"),
                ("left_tail", "our roots run as deep as in the U.S"),
                ("quote", "source of strength for those"),
                ("right_after", "assess how to help all our stakeholders"),
                ("right_list", "When we listen, we hear our stakeholders"),
            ],
            [
                ("top_right", "left_start"),
                ("left_start", "left_tail"),
                ("quote", "right_after"),
                ("right_after", "right_list"),
            ],
            [("right_after", "top_right")],
            [("quote", "left_tail")],
        ),
        fixture(
            8,
            "dev",
            "parallel-columns-stat-cards",
            [
                ("left_heading", "Delivering for our clients"),
                ("left_body", "One way we are unique"),
                ("left_stat", "digital client logins"),
                ("left_tail", "For our Global Banking clients"),
                ("right_start", "Across our wealth management businesses"),
                ("right_stat", "wealth management client"),
                ("right_body", "Global Banking also delivered"),
                ("right_tail", "strong, diversified deposit franchise"),
            ],
            [
                ("left_heading", "left_body"),
                ("left_body", "left_tail"),
                ("right_start", "right_body"),
                ("right_body", "right_tail"),
            ],
            [("right_body", "left_heading")],
            [("left_stat", "right_start"), ("right_stat", "left_body")],
        ),
        fixture(
            12,
            "dev",
            "column-continuation-callouts",
            [
                ("left_top", "Bank of America Student Leaders program"),
                ("left_mid", "Our commitment to provide important support"),
                ("left_lower", "world’s most well-known sporting events"),
                ("left_end", "communities in times of crisis"),
                ("left_stat", "philanthropic impact from"),
                ("right_top", "devastation caused by Hurricane Helene"),
                ("right_mid", "teammates actively invest their own time"),
                ("right_lower", "invest in opportunities to help improve lives"),
                ("right_stat", "volunteer hours recorded"),
            ],
            [
                ("left_top", "left_mid"),
                ("left_mid", "left_lower"),
                ("left_lower", "left_end"),
                ("left_end", "right_top"),
                ("right_top", "right_mid"),
                ("right_mid", "right_lower"),
            ],
            [("right_top", "left_end")],
            [("left_stat", "right_stat")],
        ),
        fixture(
            18,
            "dev",
            "side-label-two-column",
            [
                ("side_label", "eight lines of business | retail banking"),
                ("heading", "Empowering clients with solutions"),
                ("intro", "Retail Banking brings together"),
                ("left_section", "Driving Responsible Growth"),
                ("left_body", "Retail Banking team supports"),
                ("right_bullets", "Keep the Change"),
                ("right_section", "Providing tools to help clients"),
                ("right_body", "extensive personalized support"),
            ],
            [
                ("heading", "intro"),
                ("intro", "left_section"),
                ("left_section", "left_body"),
                ("left_body", "right_bullets"),
                ("right_bullets", "right_section"),
                ("right_section", "right_body"),
            ],
            [("right_section", "heading")],
            [("side_label", "right_body")],
        ),
        fixture(
            20,
            "dev",
            "column-continuation-stat",
            [
                ("side_label", "eight lines of business | preferred banking"),
                ("heading", "Delivering financial solutions that meet"),
                ("intro", "In Preferred Banking, we support clients"),
                ("left_body", "Our team provides clients and small businesses"),
                ("stat", "Preferred Banking teammates"),
                ("left_section", "Investing in financial centers"),
                ("right_continuation", "destinations to serve more clients"),
                ("right_close", "plan to open more than 200"),
            ],
            [
                ("heading", "intro"),
                ("intro", "left_body"),
                ("left_body", "left_section"),
                ("left_section", "right_continuation"),
                ("right_continuation", "right_close"),
            ],
            [("right_continuation", "left_section")],
            [("side_label", "right_continuation"), ("stat", "right_continuation")],
        ),
        fixture(
            22,
            "holdout",
            "asymmetric-columns-callouts",
            [
                ("side_label", "eight lines of business | merrill"),
                ("heading", "Providing a comprehensive"),
                ("intro", "Merrill advisors serve"),
                ("left_section", "Harnessing our industry leadership"),
                ("left_body", "Merrill’s financial advisors are at the center"),
                ("left_lower", "Leveraging an extended team"),
                ("left_stat", "fee-based AUM flows"),
                ("right_top", "Working in partnership with ISG specialists"),
                ("right_section", "Providing clients all Bank of America"),
                ("right_body", "In addition to our investment platform"),
                ("right_stat", "banking accounts opened"),
            ],
            [
                ("heading", "intro"),
                ("intro", "left_section"),
                ("left_section", "left_body"),
                ("left_body", "left_lower"),
                ("left_lower", "right_top"),
                ("right_top", "right_section"),
                ("right_section", "right_body"),
            ],
            [("right_top", "left_section")],
            [("side_label", "right_body"), ("left_stat", "right_top"), ("right_stat", "left_lower")],
        ),
        fixture(
            24,
            "holdout",
            "uneven-columns-bullets",
            [
                ("side_label", "eight lines of business | private bank"),
                ("heading", "Providing a customized wealth management"),
                ("intro", "Private Bank provides wealth management solutions"),
                ("left_section", "Meeting the comprehensive needs"),
                ("left_lower", "Delivering Responsible Growth"),
                ("left_stat", "net new client relationships"),
                ("right_top", "Our client-focused growth strategy"),
                ("right_bullet", "Grow deposit, loan and investment accounts"),
                ("right_close", "Prioritize investments in technology"),
            ],
            [
                ("heading", "intro"),
                ("intro", "left_section"),
                ("left_section", "left_lower"),
                ("left_lower", "right_top"),
                ("right_top", "right_bullet"),
                ("right_bullet", "right_close"),
            ],
            [("right_top", "left_lower")],
            [("side_label", "right_bullet"), ("left_stat", "right_top")],
        ),
        fixture(
            30,
            "holdout",
            "image-offset-two-column",
            [
                ("side_label", "global corporate & investment banking"),
                ("heading", "Helping our clients succeed"),
                ("intro", "Global Corporate & Investment Banking"),
                ("left_section", "Focusing on client needs"),
                ("left_body", "corporate and investment banking clients depend"),
                ("left_quote", "Strong investment banking results"),
                ("right_top", "focus on key business opportunities"),
                ("right_stat", "increase in investment banking"),
                ("right_body", "In investment banking, we maintained"),
            ],
            [
                ("heading", "intro"),
                ("intro", "left_section"),
                ("left_section", "left_body"),
                ("left_body", "right_top"),
                ("right_top", "right_body"),
            ],
            [("right_top", "left_body")],
            [("side_label", "right_body"), ("left_quote", "right_stat")],
        ),
        fixture(
            37,
            "holdout",
            "parallel-columns-quote",
            [
                ("quote", "driven by a client-first"),
                ("left_body", "At Bank of America, we are driven"),
                ("left_tail", "Germany has a longstanding commitment"),
                ("right_top", "organization working across Germany"),
                ("right_stat", "teammates in Germany"),
                ("right_mid", "support our clients’ needs related"),
                ("right_tail", "International business contributing"),
            ],
            [
                ("quote", "left_body"),
                ("left_body", "left_tail"),
                ("right_top", "right_mid"),
                ("right_mid", "right_tail"),
            ],
            [("right_mid", "quote")],
            [("quote", "right_top"), ("right_stat", "left_body")],
        ),
        fixture(
            43,
            "holdout",
            "section-split-columns",
            [
                ("heading", "Using the power of every connection"),
                ("top_body", "Through our workforce development"),
                ("stat", "invested in workforce partners"),
                ("left_section", "Delivering skill-specific learning"),
                ("left_lower", "Connecting the expertise of our teammates"),
                ("right_section", "Advancing local workforce efforts"),
                ("right_body", "By partnering with employers"),
            ],
            [
                ("heading", "top_body"),
                ("top_body", "left_section"),
                ("left_section", "left_lower"),
                ("right_section", "right_body"),
            ],
            [("right_section", "heading")],
            [("stat", "right_section"), ("left_lower", "right_section")],
        ),
        fixture(
            49,
            "holdout",
            "stat-grid-and-prose",
            [
                ("heading", "Attracting talent"),
                ("top_body", "Building a strong pipeline of talent"),
                ("stats_heading", "2024 hiring statistics"),
                ("stats_grid", "Pathways hires from"),
                ("right_section", "Supporting career development"),
                ("right_body", "ways we invest in our teammates"),
                ("right_tail", "drive innovative learning"),
            ],
            [
                ("heading", "top_body"),
                ("right_section", "right_body"),
                ("right_body", "right_tail"),
            ],
            [("right_section", "heading")],
            [("stats_heading", "right_section"), ("stats_grid", "right_body")],
        ),
    )


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_truth(path: Path, spec: Fixture) -> None:
    document = {
        "version": 1,
        "nodes": [
            {"id": node.id, "page_index": 0, "text_anchor": node.anchor}
            for node in spec.nodes
        ],
        "required_precedence": list(spec.required),
        "forbidden_precedence": list(spec.forbidden),
        "ambiguous_pairs": list(spec.ambiguous),
        "relations": [],
        "valid_orders": [],
    }
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_file():
        raise SystemExit(f"missing source PDF: {source}")
    actual_digest = digest(source)
    if actual_digest != SOURCE_SHA256:
        raise SystemExit(
            f"source SHA-256 mismatch: expected {SOURCE_SHA256}, got {actual_digest}"
        )
    qpdf = shutil.which("qpdf")
    pdftotext = shutil.which("pdftotext")
    if qpdf is None or pdftotext is None:
        raise SystemExit("qpdf and pdftotext are required")

    corpus = OUTPUT_ROOT / "corpus"
    graph_truth = OUTPUT_ROOT / "ground_truth" / "reading_graph"
    for directory in (corpus, graph_truth):
        directory.mkdir(parents=True, exist_ok=True)

    manifest_rows = [
        "# category\tdoc_id\tpdf_path\ttruth_text_path\ttruth_table_json_path_optional\ttruth_reading_order_path_optional\ttruth_formula_path_optional\ttruth_formula_json_path_optional\ttruth_form_json_path_optional\ttruth_reading_graph_path_optional"
    ]
    metadata_rows: list[str] = []
    for spec in fixtures():
        pdf_path = corpus / f"{spec.doc_id}.pdf"
        # Full source-derived text stays beside the ignored derived PDF rather
        # than becoming a checked-in ground-truth transcription.
        text_path = corpus / f"{spec.doc_id}.txt"
        graph_path = graph_truth / f"{spec.doc_id}.json"
        subprocess.run(
            [
                qpdf,
                "--deterministic-id",
                "--object-streams=disable",
                str(source),
                "--pages",
                ".",
                str(spec.page),
                "--",
                str(pdf_path),
            ],
            check=True,
        )
        extracted = subprocess.run(
            [pdftotext, "-layout", str(pdf_path), "-"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.replace("\f", "").rstrip()
        text_path.write_text(extracted + "\n", encoding="utf-8")
        write_truth(graph_path, spec)
        manifest_rows.append(
            "\t".join(
                [
                    "visual_truth",
                    spec.doc_id,
                    str(pdf_path.relative_to(REPO_ROOT)),
                    str(text_path.relative_to(REPO_ROOT)),
                    "",
                    "",
                    "",
                    "",
                    "",
                    str(graph_path.relative_to(REPO_ROOT)),
                ]
            )
        )
        metadata_rows.append(
            json.dumps(
                {
                    "doc_id": spec.doc_id,
                    "expected_ocr_pages": 0,
                    "family": spec.family,
                    "reading_order_split": spec.split,
                    "source_page": spec.page,
                    "source_sha256": SOURCE_SHA256,
                    "tagged": False,
                },
                sort_keys=True,
            )
        )

    manifest = "\n".join(manifest_rows) + "\n"
    metadata = "\n".join(metadata_rows) + "\n"
    manifest_path = OUTPUT_ROOT / "manifest.tsv"
    metadata_path = OUTPUT_ROOT / "metadata.jsonl"
    if args.check:
        if not manifest_path.is_file() or manifest_path.read_text(encoding="utf-8") != manifest:
            raise SystemExit("reading-order real manifest is stale")
        if not metadata_path.is_file() or metadata_path.read_text(encoding="utf-8") != metadata:
            raise SystemExit("reading-order real metadata is stale")
        return
    manifest_path.write_text(manifest, encoding="utf-8")
    metadata_path.write_text(metadata, encoding="utf-8")


if __name__ == "__main__":
    main()
