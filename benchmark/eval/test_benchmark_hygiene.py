from __future__ import annotations

import importlib.util
import contextlib
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
            table = table_path.read_text(encoding="utf-8")
            self.assertIn("Manifest Readiness", table)
            self.assertIn("Comparator By Parser", table)
            self.assertIn("Optimization Candidates", table)
            self.assertIn("candidate | scope | max_wall_ms | median_wall_ms", table)

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
