from __future__ import annotations

import importlib.util
import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVAL_DIR = ROOT / "benchmark" / "eval"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


compare = load_module("compare", EVAL_DIR / "compare.py")
fetch_large_corpus = load_module("fetch_large_corpus", EVAL_DIR / "fetch_large_corpus.py")
profile_lanes = load_module("profile_lanes", EVAL_DIR / "profile_lanes.py")
analyze_baseline = load_module("analyze_baseline", EVAL_DIR / "analyze_baseline.py")
run_baseline = load_module("run_baseline", EVAL_DIR / "run_baseline.py")
structural_compare = load_module("structural_compare", EVAL_DIR / "structural_compare.py")
font_compare = load_module("font_compare", EVAL_DIR / "font_compare.py")
render_oracle = load_module("render_oracle", EVAL_DIR / "render_oracle.py")


class BenchmarkHygieneTests(unittest.TestCase):
    def test_compare_ensure_releasefast_rebuilds_even_when_binary_exists(self) -> None:
        calls: list[list[str]] = []

        class Proc:
            returncode = 0
            stderr = ""
            stdout = ""

        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "pdf-parser-eval"
            binary.write_text("existing debug binary placeholder", encoding="utf-8")
            config = compare.PdfParserConfig(
                runner="binary",
                eval_command=binary,
                ensure_releasefast=True,
            )
            original_run = compare.subprocess.run
            try:
                compare.subprocess.run = lambda cmd, **kwargs: (calls.append(cmd), Proc())[1]
                compare.ensure_pdf_parser_eval_binary(Path(temp_dir), config)
            finally:
                compare.subprocess.run = original_run

        self.assertEqual([["zig", "build", "-Doptimize=ReleaseFast", "--summary", "all"]], calls)

    def test_profile_ensure_releasefast_rebuilds_even_when_binary_exists(self) -> None:
        calls: list[list[str]] = []

        class Proc:
            returncode = 0
            stderr = ""
            stdout = ""

        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "pdf-parser"
            binary.write_text("existing debug binary placeholder", encoding="utf-8")
            original_run = profile_lanes.subprocess.run
            try:
                profile_lanes.subprocess.run = lambda cmd, **kwargs: (calls.append(cmd), Proc())[1]
                profile_lanes.ensure_releasefast(Path(temp_dir), binary)
            finally:
                profile_lanes.subprocess.run = original_run

        self.assertEqual([["zig", "build", "-Doptimize=ReleaseFast", "--summary", "all"]], calls)

    def test_compare_uses_releasefast_eval_binary_by_default(self) -> None:
        entry = compare.Entry(
            category="clean_born_digital",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            truth_path=Path("/tmp/doc.txt"),
        )
        config = compare.PdfParserConfig(
            runner="binary",
            eval_command=Path("/repo/zig-out/bin/pdf-parser-eval"),
            ensure_releasefast=True,
        )

        cmd = compare.build_pdf_parser_command(entry, adaptive=True, config=config)

        self.assertEqual("/repo/zig-out/bin/pdf-parser-eval", cmd[0])
        self.assertIn("--adaptive", cmd)
        self.assertNotIn("build", cmd[:3])

    def test_compare_legacy_zig_build_runner_remains_available(self) -> None:
        entry = compare.Entry(
            category="clean_born_digital",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            truth_path=Path("/tmp/doc.txt"),
        )
        config = compare.PdfParserConfig(
            runner="zig-build",
            eval_command=Path("ignored"),
            ensure_releasefast=False,
        )

        cmd = compare.build_pdf_parser_command(entry, adaptive=False, config=config)

        self.assertEqual(["zig", "build", "eval", "--"], cmd[:4])

    def test_compare_table_and_jsonl_include_wall_ms(self) -> None:
        entry = compare.Entry(
            category="clean_born_digital",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            truth_path=Path("/tmp/doc.txt"),
        )
        row = compare.row(
            entry=entry,
            parser="pdf-parser",
            status="ok",
            metrics={"cer": 0.0, "wer": 0.0, "token_f1": 1.0},
            latency_ms=1.25,
            wall_ms=9.5,
            peak_rss_mb=4.0,
        )

        self.assertEqual(9.5, row["wall_ms"])
        self.assertIn("wall_ms", compare.render_table([row]).splitlines()[0])
        self.assertEqual(9.5, json.loads(compare.render_jsonl([row]))["wall_ms"])

    def test_structural_compare_classifies_parser_and_qpdf_outcomes(self) -> None:
        self.assertEqual("both_ok", structural_compare.classify(0, "ok", 0, 0))
        self.assertEqual("both_warn", structural_compare.classify(0, "recovered", 3, 1))
        self.assertEqual("pdf_parser_more_strict", structural_compare.classify(0, "recovered", 0, 0))
        self.assertEqual("qpdf_more_strict", structural_compare.classify(0, "ok", 3, 1))
        self.assertEqual("parser_failed", structural_compare.classify(1, None, 0, 0))

    def test_structural_compare_ignores_qpdf_success_footer(self) -> None:
        warnings = structural_compare.qpdf_warning_lines(
            "No syntax or stream encoding errors found; the file may still contain\n"
            "errors that qpdf cannot detect\n",
            "",
        )
        self.assertEqual([], warnings)

    def test_structural_compare_manifest_and_jsonl_are_stable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pdf_path = temp_path / "fixture.pdf"
            pdf_path.write_bytes(b"%PDF placeholder\n")
            manifest_path = temp_path / "manifest.tsv"
            manifest_path.write_text(
                f"adversarial_corrupt\tbad-startxref\t{pdf_path}\tignored-truth.txt\n",
                encoding="utf-8",
            )

            entries = structural_compare.load_manifest(manifest_path, ROOT)
            self.assertEqual(1, len(entries))
            self.assertEqual("bad-startxref", entries[0].doc_id)

            row = structural_compare.skipped_record(entries[0], "missing_qpdf", "qpdf unavailable")
            rendered = structural_compare.render_jsonl([row])
            record = json.loads(rendered)
            self.assertEqual("structural_compare", record["record_type"])
            self.assertEqual("skipped", record["classification"])

    def test_fetch_large_corpus_parses_sources_and_qpdf_recipes(self) -> None:
        rows = fetch_large_corpus.load_sources(EVAL_DIR / "large" / "sources.tsv", ROOT)
        self.assertGreaterEqual(len(rows), 6)
        source = ROOT / "benchmark/eval/raw_cache/large/text-100.pdf"
        dest = ROOT / "benchmark/eval/raw_cache/large/object-stream-heavy.pdf"

        object_stream_cmd = fetch_large_corpus.qpdf_command("qpdf", source, dest, "object-streams", "")
        encrypted_cmd = fetch_large_corpus.qpdf_command("qpdf", source, dest, "encrypt-aes256", "benchmark-password")

        self.assertIn("--object-streams=generate", object_stream_cmd)
        self.assertEqual(["qpdf", "--encrypt", "benchmark-password", "benchmark-password-owner", "256"], encrypted_cmd[:5])

    def test_profile_lane_commands_are_host_surface_commands(self) -> None:
        entry = profile_lanes.Entry(
            category="clean_born_digital",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            password="benchmark-password",
            page_count=100,
        )

        adaptive_cmd = profile_lanes.build_lane_command(
            Path("/repo/zig-out/bin/pdf-parser"),
            entry,
            "adaptive-artifact-jsonl",
            Path("/tmp/out.jsonl"),
            "tesseract",
            "pdftoppm",
            200,
            False,
            False,
            None,
        )

        self.assertEqual(["/repo/zig-out/bin/pdf-parser", "extract-adaptive"], adaptive_cmd[:2])
        self.assertIn("artifact-jsonl", adaptive_cmd)
        self.assertIn("--no-ocr", adaptive_cmd)
        self.assertNotIn("--ocr-dpi", adaptive_cmd)

        ocr_cmd = profile_lanes.build_lane_command(
            Path("/repo/zig-out/bin/pdf-parser"),
            entry,
            "ocr-routed",
            Path("/tmp/out.jsonl"),
            "tesseract",
            "pdftoppm",
            200,
            True,
            False,
            "1-10",
        )

        self.assertEqual(["/repo/zig-out/bin/pdf-parser", "extract-adaptive"], ocr_cmd[:2])
        self.assertIn("stream-jsonl", ocr_cmd)
        self.assertIn("--password", ocr_cmd)
        self.assertIn("--ocr-dpi", ocr_cmd)
        self.assertIn("200", ocr_cmd)
        self.assertIn("--ocr-color", ocr_cmd)
        self.assertIn("--pages", ocr_cmd)
        self.assertIn("1-10", ocr_cmd)
        self.assertNotIn("--no-ocr", ocr_cmd)

    def test_profile_lane_pages_can_bound_only_ocr_lane(self) -> None:
        self.assertEqual("1-10", profile_lanes.lane_pages("ocr-routed", None, "1-10"))
        self.assertEqual("5-6", profile_lanes.lane_pages("ocr-routed", "5-6", None))
        self.assertEqual("5-6", profile_lanes.lane_pages("adaptive-stream-jsonl", "5-6", "1-10"))
        self.assertIsNone(profile_lanes.lane_pages("adaptive-artifact-jsonl", None, "1-10"))

    def test_profile_lane_requires_explicit_full_scanned_ocr(self) -> None:
        scanned = profile_lanes.Entry(
            category="scanned_typewritten",
            doc_id="scan",
            pdf_path=Path("/tmp/scan.pdf"),
        )
        text = profile_lanes.Entry(
            category="clean_born_digital",
            doc_id="text",
            pdf_path=Path("/tmp/text.pdf"),
        )

        self.assertTrue(profile_lanes.ocr_full_run_guard(scanned, "ocr-routed", None, None, False))
        self.assertFalse(profile_lanes.ocr_full_run_guard(scanned, "ocr-routed", None, "1-10", False))
        self.assertFalse(profile_lanes.ocr_full_run_guard(scanned, "ocr-routed", "1-10", None, False))
        self.assertFalse(profile_lanes.ocr_full_run_guard(scanned, "ocr-routed", None, None, True))
        self.assertFalse(profile_lanes.ocr_full_run_guard(text, "ocr-routed", None, None, False))
        self.assertFalse(profile_lanes.ocr_full_run_guard(scanned, "adaptive-stream-jsonl", None, None, False))

    def test_font_compare_loads_metadata_sidecar_and_truth(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pdf_path = temp_path / "font.pdf"
            text_path = temp_path / "font.txt"
            truth_path = temp_path / "font.json"
            pdf_path.write_bytes(b"%PDF placeholder\n")
            text_path.write_text("Correct ActualText replacement\n", encoding="utf-8")
            truth_path.write_text(
                json.dumps(
                    {
                        "expected_text": "Correct ActualText replacement",
                        "expect_actual_text": True,
                        "expect_unicode_map_error": False,
                        "expected_writing_mode": 0,
                        "required_glyph_trace_fields": ["record_type", "bbox"],
                    }
                ),
                encoding="utf-8",
            )
            manifest_path = temp_path / "manifest.tsv"
            manifest_path.write_text(
                f"weird_fonts\tactualtext-repair\t{pdf_path}\t{text_path}\n",
                encoding="utf-8",
            )
            metadata_path = temp_path / "metadata.jsonl"
            metadata_path.write_text(
                json.dumps(
                    {
                        "category": "weird_fonts",
                        "doc_id": "actualtext-repair",
                        "font_truth_path": str(truth_path),
                        "font_case_tags": ["actualtext", "marked-content"],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            entries = font_compare.load_entries(manifest_path, ROOT)
            truth = font_compare.load_font_truth(entries[0])

        self.assertEqual("actualtext-repair", entries[0].doc_id)
        self.assertEqual(("actualtext", "marked-content"), entries[0].font_case_tags)
        self.assertTrue(truth["expect_actual_text"])

    def test_font_compare_validates_truth_shape(self) -> None:
        with self.assertRaises(ValueError):
            font_compare.validate_font_truth({"expected_text": "missing fields"})

    def test_font_compare_optional_baseline_skip(self) -> None:
        entry = font_compare.Entry(
            category="weird_fonts",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            truth_text_path=Path("/tmp/doc.txt"),
            font_truth_path=None,
            font_case_tags=("type3",),
        )

        row = font_compare.skipped(entry, "pymupdf", "PyMuPDF is not installed")

        self.assertEqual("font_compare_result", row["record_type"])
        self.assertEqual("skipped", row["status"])
        self.assertEqual(["type3"], row["font_case_tags"])

    def test_font_compare_pdf_parser_expectations_use_glyph_traces(self) -> None:
        truth = {
            "expected_text": "日本",
            "expect_actual_text": False,
            "expect_unicode_map_error": False,
            "expected_writing_mode": 1,
            "required_glyph_trace_fields": ["record_type", "bbox", "writing_mode"],
        }
        result = {
            "text": "日本",
            "glyph_traces": [
                {
                    "record_type": "glyph_trace",
                    "bbox": {"x0": 0, "y0": 0, "x1": 1, "y1": 1},
                    "writing_mode": 1,
                    "unicode_map_error": False,
                    "actual_text": False,
                }
            ],
        }

        expectations = font_compare.expectation_results("pdf-parser", truth, result)

        self.assertTrue(expectations["vertical_writing_ok"])
        self.assertTrue(expectations["unicode_map_error_ok"])
        self.assertTrue(expectations["required_glyph_trace_fields_ok"])

    def test_font_compare_metrics_are_normalized(self) -> None:
        metrics = font_compare.text_metrics("Correct   text", "Correct text")

        self.assertEqual(0.0, metrics["cer"])
        self.assertEqual(0.0, metrics["wer"])
        self.assertEqual(1.0, metrics["token_f1"])

    def test_render_oracle_loads_metadata_sidecar_and_truth(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pdf_path = temp_path / "visual.pdf"
            text_path = temp_path / "visual.txt"
            truth_path = temp_path / "render.json"
            pdf_path.write_bytes(b"%PDF placeholder\n")
            text_path.write_text("Visual truth\n", encoding="utf-8")
            truth_path.write_text(
                json.dumps(
                    {
                        "expected_page_count": 1,
                        "expected_issue_tags": ["clipped_text"],
                        "min_text_bbox_coverage": 0.0,
                        "max_blank_bbox_rate": 1.0,
                        "min_ruling_pixel_coverage": 0.0,
                        "min_image_region_overlap": 0.0,
                    }
                ),
                encoding="utf-8",
            )
            manifest_path = temp_path / "manifest.tsv"
            manifest_path.write_text(
                f"visual_truth\tclipped-text\t{pdf_path}\t{text_path}\n",
                encoding="utf-8",
            )
            metadata_path = temp_path / "metadata.jsonl"
            metadata_path.write_text(
                json.dumps(
                    {
                        "category": "visual_truth",
                        "doc_id": "clipped-text",
                        "render_truth_path": str(truth_path),
                        "visual_case_tags": ["clipped_text"],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            entries = render_oracle.load_entries(manifest_path, ROOT)
            truth = render_oracle.load_render_truth(entries[0])

        self.assertEqual("clipped-text", entries[0].doc_id)
        self.assertEqual(("clipped_text",), entries[0].visual_case_tags)
        self.assertEqual(["clipped_text"], truth["expected_issue_tags"])

    def test_render_oracle_validates_truth_shape(self) -> None:
        with self.assertRaises(ValueError):
            render_oracle.validate_render_truth({"expected_page_count": 1})

    def test_render_oracle_bbox_to_pixels_inverts_y_axis(self) -> None:
        viewbox = render_oracle.ViewBox(0.0, 0.0, 612.0, 792.0)
        bbox = {"x0": 72, "y0": 700, "x1": 172, "y1": 724}

        box = render_oracle.bbox_to_pixels(bbox, viewbox, (1224, 1584))

        self.assertEqual(render_oracle.PixelBox(144, 136, 344, 184), box)

    def test_render_oracle_builds_poppler_command(self) -> None:
        cmd = render_oracle.build_poppler_command(Path("/tmp/doc.pdf"), 2, 144, Path("/tmp/page"))

        self.assertEqual("pdftoppm", cmd[0])
        self.assertIn("-singlefile", cmd)
        self.assertEqual("3", cmd[cmd.index("-f") + 1])
        self.assertEqual("144", cmd[cmd.index("-r") + 1])

    def test_render_oracle_skipped_missing_renderer_record_is_stable(self) -> None:
        entry = render_oracle.Entry(
            category="visual_truth",
            doc_id="doc",
            pdf_path=Path("/tmp/doc.pdf"),
            truth_text_path=None,
            render_truth_path=None,
            visual_case_tags=("image_region",),
        )

        row = render_oracle.skipped(entry, "mutool", "mutool is not installed")

        self.assertEqual("render_oracle_page", row["record_type"])
        self.assertEqual("0.1.0", row["render_oracle_schema_version"])
        self.assertEqual("skipped", row["status"])

    def test_render_oracle_pixel_density_classifies_ink(self) -> None:
        image = render_oracle.Image.new("RGB", (20, 20), "white")
        for y in range(5, 15):
            for x in range(5, 15):
                image.putpixel((x, y), (0, 0, 0))

        density = render_oracle.ink_density(image, render_oracle.PixelBox(0, 0, 20, 20))

        self.assertAlmostEqual(0.25, density)

    def test_render_oracle_jsonl_rows_parse_line_by_line(self) -> None:
        row = {
            "record_type": "render_oracle_page",
            "render_oracle_schema_version": "0.1.0",
            "status": "ok",
        }
        output = io.StringIO()

        render_oracle.write_row(output, row)

        self.assertEqual(row, json.loads(output.getvalue()))

    def test_profile_output_jsonl_parses_line_by_line(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            pdf_path = Path(temp_dir) / "missing.pdf"
            manifest_path = Path(temp_dir) / "manifest.tsv"
            output_path = Path(temp_dir) / "profile.jsonl"
            manifest_path.write_text(
                f"clean_born_digital\tmissing\t{pdf_path}\t\t1\tmissing test fixture\n",
                encoding="utf-8",
            )

            exit_code = profile_lanes.main_with_args_for_test(
                [
                    "--manifest",
                    str(manifest_path),
                    "--lanes",
                    "native-text",
                    "--output",
                    str(output_path),
                    "--no-ensure-releasefast",
                ]
            )

            self.assertEqual(0, exit_code)
            records = [json.loads(line) for line in output_path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual("profile_lane_result", records[0]["record_type"])
            self.assertIn("output_sha256", records[0])
            self.assertIsNone(records[0]["output_sha256"])

    def test_profile_output_hash_is_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            pdf_path = temp_path / "fixture.pdf"
            pdf_path.write_bytes(b"%PDF placeholder\n")
            parser_path = temp_path / "fake-parser"
            parser_path.write_text(
                "#!/bin/sh\n"
                "out=''\n"
                "previous=''\n"
                "for arg in \"$@\"; do\n"
                "  if [ \"$previous\" = '-o' ] || [ \"$previous\" = '--output' ]; then out=\"$arg\"; fi\n"
                "  previous=\"$arg\"\n"
                "done\n"
                "printf 'profile-output\\n' > \"$out\"\n",
                encoding="utf-8",
            )
            parser_path.chmod(0o755)
            entry = profile_lanes.Entry(
                category="clean_born_digital",
                doc_id="fixture",
                pdf_path=pdf_path,
                page_count=1,
            )

            row = profile_lanes.run_lane(
                repo_root=ROOT,
                parser_command=parser_path,
                entry=entry,
                lane="native-text",
                repeat_index=0,
                require_tools=False,
                ocr_executable="tesseract",
                ocr_rasterizer="pdftoppm",
                ocr_dpi=200,
                ocr_color=False,
                hash_output=True,
                enable_ocr_in_adaptive_lanes=False,
                pages=None,
                ocr_pages=None,
                allow_full_ocr=False,
            )

            self.assertEqual("ok", row["status"])
            self.assertEqual(hashlib.sha256(b"profile-output\n").hexdigest(), row["output_sha256"])

    def test_analyze_baseline_summarizes_compare_and_profile_jsonl(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            compare_path = Path(temp_dir) / "compare.jsonl"
            profile_path = Path(temp_dir) / "profile.jsonl"
            manifest_path = Path(temp_dir) / "manifest.tsv"
            present_pdf = Path(temp_dir) / "present.pdf"
            output_path = Path(temp_dir) / "report.json"
            table_path = Path(temp_dir) / "report.md"
            present_pdf.write_bytes(b"%PDF placeholder\n")
            manifest_path.write_text(
                "\n".join(
                    [
                        "category\tdoc_id\tpdf_path",
                        f"clean_born_digital\tpresent\t{present_pdf}",
                        f"clean_born_digital\tmissing\t{Path(temp_dir) / 'missing.pdf'}",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            compare_path.write_text(
                json.dumps(
                    {
                        "doc_id": "doc",
                        "category": "clean_born_digital",
                        "parser": "pdf-parser",
                        "status": "ok",
                        "metrics": {"cer": 0.0, "wer": 0.0, "token_f1": 1.0},
                        "latency_ms": 3.0,
                        "wall_ms": 7.0,
                        "peak_rss_mb": 12.0,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            profile_path.write_text(
                json.dumps(
                    {
                        "record_type": "profile_lane_result",
                        "doc_id": "doc",
                        "category": "clean_born_digital",
                        "lane": "native-text",
                        "repeat_index": 0,
                        "status": "ok",
                        "wall_ms": 5.0,
                        "parser_latency_ms": None,
                        "peak_rss_mb": 10.0,
                        "output_bytes": 1234,
                        "output_sha256": "abc123",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            exit_code = analyze_baseline.main_with_args_for_test(
                [
                    "--compare-jsonl",
                    str(compare_path),
                    "--profile-jsonl",
                    str(profile_path),
                    "--manifest",
                    str(manifest_path),
                    "--output",
                    str(output_path),
                    "--table-output",
                    str(table_path),
                ]
            )

            self.assertEqual(0, exit_code)
            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual("baseline_report", report["record_type"])
            self.assertFalse(report["manifest_readiness"]["ready"])
            self.assertEqual(1, report["manifest_readiness"]["missing_count"])
            self.assertEqual(1, report["compare"]["record_count"])
            self.assertEqual(1, report["profile"]["record_count"])
            self.assertEqual(1, len(report["optimization_candidates"]))
            self.assertEqual("tiny-corpus-only", report["optimization_candidates"][0]["evidence_scope"])
            self.assertEqual("populate-large-corpus", report["next_actions"][0]["action_id"])
            self.assertIn("pdf-parser", report["compare"]["by_parser"])
            self.assertIn("native-text", report["profile"]["by_lane"])
            hashes = report["profile"]["by_lane"]["native-text"]["output_hashes"]
            self.assertEqual(1, hashes["count"])
            self.assertEqual(1, hashes["distinct_count"])
            self.assertTrue(hashes["stable"])
            table = table_path.read_text(encoding="utf-8")
            self.assertIn("Manifest Readiness", table)
            self.assertIn("Comparator By Parser", table)
            self.assertIn("Optimization Candidates", table)
            self.assertIn("candidate | scope | max_wall_ms | median_wall_ms", table)
            self.assertIn("output hashes", table)
            self.assertIn("stable 1/1", table)

    def test_analyze_profile_hash_summary_detects_drift(self) -> None:
        summary = analyze_baseline.summarize_profile_group(
            [
                {"status": "ok", "doc_id": "same-doc", "wall_ms": 1.0, "output_sha256": "aaa"},
                {"status": "ok", "doc_id": "same-doc", "wall_ms": 1.1, "output_sha256": "bbb"},
                {"status": "ok", "doc_id": "same-doc", "wall_ms": 1.2},
            ]
        )

        self.assertEqual(2, summary["output_hashes"]["count"])
        self.assertEqual(2, summary["output_hashes"]["distinct_count"])
        self.assertEqual(["same-doc"], summary["output_hashes"]["unstable_keys"])
        self.assertFalse(summary["output_hashes"]["stable"])

    def test_analyze_profile_hash_summary_allows_distinct_document_hashes(self) -> None:
        summary = analyze_baseline.summarize_profile_group(
            [
                {"status": "ok", "doc_id": "doc-a", "wall_ms": 1.0, "output_sha256": "aaa"},
                {"status": "ok", "doc_id": "doc-b", "wall_ms": 1.1, "output_sha256": "bbb"},
            ]
        )

        self.assertEqual(2, summary["output_hashes"]["count"])
        self.assertEqual(2, summary["output_hashes"]["distinct_count"])
        self.assertEqual([], summary["output_hashes"]["unstable_keys"])
        self.assertTrue(summary["output_hashes"]["stable"])

    def test_run_baseline_dry_run_prints_pipeline_commands(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exit_code = run_baseline.main_with_args_for_test(
                [
                    "--dry-run",
                    "--skip-releasefast",
                    "--skip-ocr-profile",
                    "--repeat",
                    "1",
                ]
            )

        self.assertEqual(0, exit_code)
        self.assertIn("benchmark/eval/compare.py", stdout.getvalue())

    def test_run_baseline_hash_output_reaches_profile_commands(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exit_code = run_baseline.main_with_args_for_test(
                [
                    "--dry-run",
                    "--skip-releasefast",
                    "--skip-compare",
                    "--skip-ocr-profile",
                    "--repeat",
                    "1",
                    "--hash-output",
                ]
            )

        self.assertEqual(0, exit_code)
        lines = stdout.getvalue().splitlines()
        profile_lines = [line for line in lines if "benchmark/eval/profile_lanes.py" in line]
        analyze_lines = [line for line in lines if "benchmark/eval/analyze_baseline.py" in line]
        self.assertTrue(profile_lines)
        self.assertTrue(all("--hash-output" in line for line in profile_lines))
        self.assertTrue(analyze_lines)
        self.assertTrue(all("--hash-output" not in line for line in analyze_lines))

    def test_run_baseline_manifest_inputs_present_detects_missing_large_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "manifest.tsv"
            present_pdf = Path(temp_dir) / "present.pdf"
            present_pdf.write_bytes(b"%PDF placeholder\n")
            manifest_path.write_text(
                f"category\tdoc_id\tpdf_path\nclean_born_digital\tpresent\t{present_pdf}\n",
                encoding="utf-8",
            )

            self.assertTrue(run_baseline.manifest_inputs_present(manifest_path, ROOT))

            manifest_path.write_text(
                f"category\tdoc_id\tpdf_path\nclean_born_digital\tmissing\t{Path(temp_dir) / 'missing.pdf'}\n",
                encoding="utf-8",
            )

            self.assertFalse(run_baseline.manifest_inputs_present(manifest_path, ROOT))

    def test_run_baseline_require_large_fails_when_inputs_are_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "manifest.tsv"
            manifest_path.write_text(
                f"category\tdoc_id\tpdf_path\nclean_born_digital\tmissing\t{Path(temp_dir) / 'missing.pdf'}\n",
                encoding="utf-8",
            )
            stdout = io.StringIO()
            stderr = io.StringIO()

            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                exit_code = run_baseline.main_with_args_for_test(
                    [
                        "--large",
                        "--require-large",
                        "--large-manifest",
                        str(manifest_path),
                        "--dry-run",
                        "--skip-releasefast",
                        "--skip-compare",
                        "--skip-tiny-profile",
                        "--skip-ocr-profile",
                    ]
                )

            self.assertEqual(1, exit_code)
            self.assertIn("Large manifest inputs are missing", stderr.getvalue())

    def test_analyze_baseline_candidates_prioritize_large_outliers(self) -> None:
        records = [
            {
                "category": "financial_tables",
                "doc_id": f"tiny-{index}",
                "lane": "adaptive-artifact-jsonl",
                "status": "ok",
                "wall_ms": 5.0,
            }
            for index in range(20)
        ]
        records.append(
            {
                "category": "financial_tables",
                "doc_id": "large-sec",
                "lane": "adaptive-artifact-jsonl",
                "status": "ok",
                "wall_ms": 59000.0,
            }
        )
        records.append(
            {
                "category": "manuals",
                "doc_id": "reference",
                "lane": "adaptive-artifact-jsonl",
                "status": "ok",
                "wall_ms": 17000.0,
            }
        )

        candidates = analyze_baseline.optimization_candidates(records, {"ready": True}, 2)

        self.assertEqual("candidate-financial-tables-adaptive-artifact-jsonl", candidates[0]["candidate_id"])
        self.assertEqual(59000.0, candidates[0]["max_wall_ms"])


if __name__ == "__main__":
    unittest.main()
