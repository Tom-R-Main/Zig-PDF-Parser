from __future__ import annotations

import contextlib
import importlib.util
import io
import math
import sys
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "benchmark" / "eval" / "table_compare.py"
SPEC = importlib.util.spec_from_file_location("table_compare_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
table_compare = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = table_compare
SPEC.loader.exec_module(table_compare)


class TableCompareTests(unittest.TestCase):
    def test_top_origin_bbox_is_normalized_to_pdf_coordinates(self) -> None:
        normalized = table_compare.top_origin_bbox_to_pdf([72, 68, 412, 168], 792)

        self.assertEqual([72.0, 624.0, 412.0, 724.0], normalized)
        self.assertAlmostEqual(
            0.96,
            table_compare.bbox_iou(tuple(normalized), (72.0, 628.0, 412.0, 724.0)),
        )

    def test_quality_floor_failure_is_explicit(self) -> None:
        violations = table_compare.quality_violations(
            {"cell_text_accuracy": 0.49, "role_accuracy": None},
            {"cell_text_accuracy": 0.5, "role_accuracy": 0.7},
        )

        self.assertEqual(2, len(violations))
        self.assertIn("below required floor", violations[0])
        self.assertIn("is unavailable", violations[1])

    def test_run_tool_marks_metric_regression_failed(self) -> None:
        entry = table_compare.Entry(
            category="financial_table_stress",
            doc_id="regression",
            pdf_path=Path("/tmp/regression.pdf"),
            truth_text_path=None,
            table_truth_path=None,
            table_case_tags=(),
            table_quality_floors={"pdf-parser": {"cell_text_accuracy": 1.0}},
        )
        original_extract = table_compare.extract_pdf_parser
        try:
            table_compare.extract_pdf_parser = lambda *_args, **_kwargs: [
                {"rows": [[{"text": "wrong"}]]}
            ]
            row = table_compare.run_tool(
                repo_root=ROOT,
                parser_command=Path("/tmp/pdf-parser"),
                entry=entry,
                truth=[{"rows": [[{"text": "expected"}]]}],
                tool="pdf-parser",
                require_baselines=True,
            )
        finally:
            table_compare.extract_pdf_parser = original_extract

        self.assertEqual("failed", row["status"])
        self.assertIn("below required floor", row["notes"][0])

    def test_failed_quality_record_drives_cli_exit(self) -> None:
        entry = table_compare.Entry(
            category="financial_table_stress",
            doc_id="regression",
            pdf_path=Path("/tmp/regression.pdf"),
            truth_text_path=None,
            table_truth_path=Path("/tmp/regression.json"),
            table_case_tags=(),
        )
        failed_row = table_compare.failed(entry, "pdf-parser", "quality regression")

        with (
            mock.patch.object(table_compare, "load_entries", return_value=[entry]),
            mock.patch.object(table_compare, "load_table_truth", return_value=[]),
            mock.patch.object(table_compare, "run_tool", return_value=failed_row),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            exit_code = table_compare.main_with_args_for_test(
                ["--tools", "pdf-parser", "--no-ensure-releasefast"]
            )

        self.assertEqual(1, exit_code)

    def test_quality_floor_passes_at_the_recorded_boundary(self) -> None:
        self.assertEqual(
            [],
            table_compare.quality_violations(
                {"cell_text_accuracy": 0.5, "role_accuracy": 0.7},
                {"cell_text_accuracy": 0.5, "role_accuracy": 0.7},
            ),
        )

    def test_quality_floor_metadata_is_validated(self) -> None:
        self.assertEqual(
            {"pdf-parser": {"cell_text_accuracy": 0.5}},
            table_compare.parse_quality_floors({"pdf-parser": {"cell_text_accuracy": 0.5}}),
        )
        with self.assertRaises(ValueError):
            table_compare.parse_quality_floors({"pdf-parser": {"cell_text_accuracy": 1.1}})
        with self.assertRaises(ValueError):
            table_compare.parse_quality_floors({"pdf-parser": {"cell_text_accuracy": True}})
        with self.assertRaises(ValueError):
            table_compare.parse_quality_floors({"pdf-parser": {"cell_text_accuracy": math.nan}})

    def test_known_unsupported_result_is_visible_but_non_blocking(self) -> None:
        entry = table_compare.Entry(
            category="financial_table_stress",
            doc_id="unsupported",
            pdf_path=Path("/tmp/unsupported.pdf"),
            truth_text_path=None,
            table_truth_path=None,
            table_case_tags=(),
            table_known_unsupported_tools=("pdf-parser",),
        )
        original_extract = table_compare.extract_pdf_parser
        try:
            table_compare.extract_pdf_parser = lambda *_args, **_kwargs: []
            row = table_compare.run_tool(
                repo_root=ROOT,
                parser_command=Path("/tmp/pdf-parser"),
                entry=entry,
                truth=[{"rows": [[{"text": "expected"}]]}],
                tool="pdf-parser",
                require_baselines=True,
            )
        finally:
            table_compare.extract_pdf_parser = original_extract

        self.assertEqual("known_unsupported", row["status"])
        self.assertIn("observational and non-blocking", row["notes"][0])


if __name__ == "__main__":
    unittest.main()
