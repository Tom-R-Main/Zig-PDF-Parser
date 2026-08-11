#!/usr/bin/env python3
"""Generate the deterministic reading-order graph V0 experiment corpus."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parent / "reading_order"


@dataclass(frozen=True)
class Text:
    id: str
    value: str
    x: int
    y: int
    size: int = 12


@dataclass(frozen=True)
class Fixture:
    family: str
    split: str
    category: str
    texts: tuple[Text, ...]
    required: tuple[tuple[str, str], ...]
    forbidden: tuple[tuple[str, str], ...] = ()
    ambiguous: tuple[tuple[str, str], ...] = ()
    relations: tuple[tuple[str, str, str], ...] = ()
    valid_orders: tuple[tuple[str, ...], ...] = ()
    stream_order: tuple[str, ...] = ()
    tagged: bool = False

    @property
    def doc_id(self) -> str:
        return f"reading-order-{self.family}-{self.split}"


def fixture(
    family: str,
    split: str,
    category: str,
    texts: list[Text],
    required: list[tuple[str, str]],
    **kwargs: object,
) -> Fixture:
    return Fixture(
        family=family,
        split=split,
        category=category,
        texts=tuple(texts),
        required=tuple(required),
        **kwargs,
    )


def fixtures() -> list[Fixture]:
    result: list[Fixture] = []
    for split, suffix in (("dev", "A"), ("holdout", "B")):
        result.extend(
            [
                fixture(
                    "spanning-heading",
                    split,
                    "academic_two_column",
                    [
                        Text("heading", f"{suffix} Methods and Results", 72, 748, 18),
                        Text("left_1", f"{suffix} Left evidence one", 72, 706),
                        Text("left_2", f"{suffix} Left evidence two", 72, 680),
                        Text("right_1", f"{suffix} Right evidence one", 330, 706),
                        Text("right_2", f"{suffix} Right evidence two", 330, 680),
                    ],
                    [
                        ("heading", "left_1"),
                        ("heading", "right_1"),
                        ("left_1", "left_2"),
                        ("right_1", "right_2"),
                        ("left_2", "right_1"),
                    ],
                    tagged=split == "holdout",
                ),
                fixture(
                    "asymmetric-columns",
                    split,
                    "academic_two_column",
                    [
                        Text("left_1", f"{suffix} Long left opening", 72, 730),
                        Text("left_2", f"{suffix} Long left middle", 72, 704),
                        Text("left_3", f"{suffix} Long left closing", 72, 678),
                        Text("right_1", f"{suffix} Short right opening", 350, 716),
                        Text("right_2", f"{suffix} Short right closing", 350, 690),
                    ],
                    [
                        ("left_1", "left_2"),
                        ("left_2", "left_3"),
                        ("left_3", "right_1"),
                        ("right_1", "right_2"),
                    ],
                ),
                fixture(
                    "sidebar",
                    split,
                    "visual_truth",
                    [
                        Text("body_1", f"{suffix} Main narrative opens", 72, 730),
                        Text("body_2", f"{suffix} Main narrative continues", 72, 700),
                        Text("body_3", f"{suffix} Main narrative closes", 72, 660),
                        Text("sidebar", f"{suffix} Sidebar context", 410, 684, 10),
                    ],
                    [("body_1", "body_2"), ("body_2", "body_3")],
                    ambiguous=(("sidebar", "body_2"),),
                    valid_orders=(
                        ("body_1", "sidebar", "body_2", "body_3"),
                        ("body_1", "body_2", "sidebar", "body_3"),
                    ),
                ),
                fixture(
                    "caption",
                    split,
                    "visual_truth",
                    [
                        Text("body_1", f"{suffix} Analysis before figure", 72, 730),
                        Text("figure", f"{suffix} Figure region anchor", 180, 620, 10),
                        Text("caption", f"Figure {suffix}. Observed trend caption", 150, 590, 10),
                        Text("body_2", f"{suffix} Analysis after figure", 72, 540),
                    ],
                    [("body_1", "figure"), ("figure", "caption"), ("caption", "body_2")],
                    relations=(("caption_of", "caption", "figure"),),
                ),
                fixture(
                    "footnote",
                    split,
                    "visual_truth",
                    [
                        Text("body_ref", f"{suffix} Claim marker * reference", 72, 720),
                        Text("body_next", f"{suffix} Supporting body paragraph", 72, 680),
                        Text("footnote", f"* {suffix} Footnote qualification", 72, 170, 8),
                    ],
                    [("body_ref", "body_next"), ("body_next", "footnote")],
                    relations=(("footnote_of", "footnote", "body_ref"),),
                ),
                fixture(
                    "wrap-around",
                    split,
                    "visual_truth",
                    [
                        Text("top", f"{suffix} Text above illustration", 72, 740),
                        Text("left_wrap", f"{suffix} Left wrapped text", 72, 650),
                        Text("right_wrap", f"{suffix} Right wrapped text", 360, 630),
                        Text("bottom", f"{suffix} Text below illustration", 72, 540),
                    ],
                    [("top", "left_wrap"), ("top", "right_wrap"), ("left_wrap", "bottom"), ("right_wrap", "bottom")],
                    ambiguous=(("left_wrap", "right_wrap"),),
                    valid_orders=(
                        ("top", "left_wrap", "right_wrap", "bottom"),
                        ("top", "right_wrap", "left_wrap", "bottom"),
                    ),
                ),
                fixture(
                    "table-prose",
                    split,
                    "financial_tables",
                    [
                        Text("intro", f"{suffix} Quarterly summary introduction", 72, 748),
                        Text("header", f"{suffix} Year Revenue Margin", 90, 680),
                        Text("row_1", f"{suffix} 2025 100 20", 90, 654),
                        Text("row_2", f"{suffix} 2026 125 24", 90, 628),
                        Text("conclusion", f"{suffix} Quarterly summary conclusion", 72, 560),
                    ],
                    [("intro", "header"), ("header", "row_1"), ("row_1", "row_2"), ("row_2", "conclusion")],
                ),
                fixture(
                    "stream-mismatch",
                    split,
                    "academic_two_column",
                    [
                        Text("left_1", f"{suffix} Visual left first", 72, 720),
                        Text("left_2", f"{suffix} Visual left second", 72, 690),
                        Text("right_1", f"{suffix} Visual right first", 340, 720),
                        Text("right_2", f"{suffix} Visual right second", 340, 690),
                    ],
                    [("left_1", "left_2"), ("left_2", "right_1"), ("right_1", "right_2")],
                    forbidden=(("right_1", "left_1"),),
                    stream_order=("right_1", "right_2", "left_1", "left_2"),
                    tagged=split == "holdout",
                ),
            ]
        )
    return result


def pdf_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def rendered_value(text: Text) -> str:
    if text.size >= 16 or text.value.startswith("Figure ") or text.value.startswith("* "):
        return text.value
    return f"1. {text.value}"


def build_pdf(spec: Fixture) -> bytes:
    by_id = {text.id: text for text in spec.texts}
    order = spec.stream_order or tuple(text.id for text in spec.texts)
    commands: list[str] = []
    for mcid, text_id in enumerate(order):
        text = by_id[text_id]
        if spec.tagged:
            commands.append(f"/P <</MCID {mcid}>> BDC")
        commands.append(
            f"BT /F1 {text.size} Tf 1 0 0 1 {text.x} {text.y} Tm ({pdf_escape(rendered_value(text))}) Tj ET"
        )
        if spec.tagged:
            commands.append("EMC")
    content = ("\n".join(commands) + "\n").encode("ascii")

    catalog = "<< /Type /Catalog /Pages 2 0 R >>"
    page_extra = ""
    objects: list[bytes] = []
    if spec.tagged:
        catalog = "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> >>"
        page_extra = " /StructParents 0"
    objects.extend(
        [
            catalog.encode("ascii"),
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            (
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                f"{page_extra} /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
            ).encode("ascii"),
            b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"endstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
    )
    if spec.tagged:
        struct_refs = " ".join(f"{8 + index} 0 R" for index in range(len(order)))
        objects.append(f"<< /Type /StructTreeRoot /K 7 0 R >>".encode("ascii"))
        objects.append(
            f"<< /Type /StructElem /S /Document /Pg 3 0 R /K [{struct_refs}] >>".encode("ascii")
        )
        for mcid in range(len(order)):
            objects.append(
                f"<< /Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K {mcid} >>".encode("ascii")
            )

    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, body in enumerate(objects, start=1):
        offsets.append(len(output))
        output.extend(f"{number} 0 obj\n".encode("ascii"))
        output.extend(body)
        output.extend(b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    output.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii")
    )
    return bytes(output)


def truth_document(spec: Fixture) -> dict[str, object]:
    forbidden = spec.forbidden or ((spec.required[0][1], spec.required[0][0]),)
    return {
        "version": 1,
        "nodes": [
            {"id": text.id, "page_index": 0, "text_anchor": text.value}
            for text in spec.texts
        ],
        "required_precedence": list(spec.required),
        "forbidden_precedence": list(forbidden),
        "ambiguous_pairs": list(spec.ambiguous),
        "relations": [
            {"type": relation, "from": source, "to": target}
            for relation, source, target in spec.relations
        ],
        "valid_orders": list(spec.valid_orders),
    }


def main() -> None:
    corpus = ROOT / "corpus"
    text_truth = ROOT / "ground_truth" / "page_text"
    graph_truth = ROOT / "ground_truth" / "reading_graph"
    for directory in (corpus, text_truth, graph_truth):
        directory.mkdir(parents=True, exist_ok=True)

    manifest_rows = [
        "# category\tdoc_id\tpdf_path\ttruth_text_path\ttruth_table_json_path_optional\ttruth_reading_order_path_optional\ttruth_formula_path_optional\ttruth_formula_json_path_optional\ttruth_form_json_path_optional\ttruth_reading_graph_path_optional"
    ]
    metadata_rows: list[str] = []
    for spec in fixtures():
        pdf_path = corpus / f"{spec.doc_id}.pdf"
        text_path = text_truth / f"{spec.doc_id}.txt"
        graph_path = graph_truth / f"{spec.doc_id}.json"
        pdf_path.write_bytes(build_pdf(spec))
        by_id = {text.id: text for text in spec.texts}
        default_order = spec.valid_orders[0] if spec.valid_orders else tuple(text.id for text in spec.texts)
        text_path.write_text("\n".join(rendered_value(by_id[node_id]) for node_id in default_order) + "\n", encoding="utf-8")
        graph_path.write_text(json.dumps(truth_document(spec), indent=2) + "\n", encoding="utf-8")
        manifest_rows.append(
            "\t".join(
                [
                    spec.category,
                    spec.doc_id,
                    str(pdf_path.relative_to(ROOT.parent.parent.parent)),
                    str(text_path.relative_to(ROOT.parent.parent.parent)),
                    "",
                    "",
                    "",
                    "",
                    "",
                    str(graph_path.relative_to(ROOT.parent.parent.parent)),
                ]
            )
        )
        metadata_rows.append(
            json.dumps(
                {
                    "doc_id": spec.doc_id,
                    "family": spec.family,
                    "reading_order_split": spec.split,
                    "tagged": spec.tagged,
                    "expected_ocr_pages": 0,
                },
                sort_keys=True,
            )
        )

    (ROOT / "manifest.tsv").write_text("\n".join(manifest_rows) + "\n", encoding="utf-8")
    (ROOT / "metadata.jsonl").write_text("\n".join(metadata_rows) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
