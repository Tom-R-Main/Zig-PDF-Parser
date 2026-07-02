from __future__ import annotations

import importlib.util
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


class BenchmarkHygieneTests(unittest.TestCase):
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

        cmd = profile_lanes.build_lane_command(
            Path("/repo/zig-out/bin/pdf-parser"),
            entry,
            "adaptive-stream-jsonl",
            Path("/tmp/out.jsonl"),
            "tesseract",
            "pdftoppm",
        )

        self.assertEqual(["/repo/zig-out/bin/pdf-parser", "extract-adaptive"], cmd[:2])
        self.assertIn("stream-jsonl", cmd)
        self.assertIn("--password", cmd)

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


if __name__ == "__main__":
    unittest.main()
