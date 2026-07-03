//! Deterministic writer for the tiny checked-in evaluation corpus.

const std = @import("std");
const runtime = @import("runtime.zig");
const testpdf = @import("testpdf.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

const Fixture = struct {
    category: []const u8,
    doc_id: []const u8,
    pdf_name: []const u8,
    source_note: []const u8 = "deterministic reduced fixture generated in-repo",
    license_status: []const u8 = "redistributable synthetic reduction",
    expected_ocr_pages: u32 = 0,
    expected_table_regions: u32 = 0,
    expected_formula_regions: u32 = 0,
    truth: []const u8,
    table_truth: ?[]const u8 = null,
    reading_order_truth: ?[]const u8 = null,
    formula_truth: ?[]const u8 = null,
    formula_json_truth: ?[]const u8 = null,
    form_json_truth: ?[]const u8 = null,
    font_truth: ?[]const u8 = null,
    font_case_tags: []const []const u8 = &.{},
    render_truth: ?[]const u8 = null,
    visual_case_tags: []const []const u8 = &.{},
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
};

const fixtures = [_]Fixture{
    .{
        .category = "clean_born_digital",
        .doc_id = "clean-native",
        .pdf_name = "clean-native.pdf",
        .truth =
        \\Clean born digital text has enough native glyph coverage for extraction.
        \\The page is deliberately dense so sparse text does not dominate routing.
        \\Unicode metadata is present through a ToUnicode map for the font.
        \\Normal top to bottom ordering keeps reading order confidence high.
        \\This fixture should remain on the native fast path without OCR.
        \\Additional words add page coverage and realistic paragraph length.
        \\Adaptive routing should report use native for this document page.
        \\
        ,
        .generate = testpdf.generateCleanNativePdf,
    },
    .{
        .category = "academic_two_column",
        .doc_id = "two-column",
        .pdf_name = "two-column.pdf",
        .truth =
        \\Chapter 1
        \\Left column first line
        \\Left column second line
        \\Left column third line
        \\Right column first line
        \\Right column second line
        \\Right column third line
        \\42
        \\
        ,
        .reading_order_truth =
        \\Chapter 1
        \\Left column first line
        \\Left column second line
        \\Left column third line
        \\Right column first line
        \\Right column second line
        \\Right column third line
        \\42
        \\
        ,
        .generate = testpdf.generateTwoColumnPdf,
    },
    .{
        .category = "scientific_math",
        .doc_id = "math-notation",
        .pdf_name = "math-notation.pdf",
        .expected_formula_regions = 3,
        .truth =
        \\Formula 1.
        \\E=mc^2++++////^^^^____
        \\alpha+beta/gamma====
        \\sum(x_i^2)>=delta++++
        \\normal paragraph text
        \\
        ,
        .formula_truth =
        \\E=mc^2++++////^^^^____
        \\alpha+beta/gamma====
        \\sum(x_i^2)>=delta++++
        \\
        ,
        .formula_json_truth =
        \\[
        \\  {"page":0,"text":"E=mc^2++++////^^^^____"},
        \\  {"page":0,"text":"alpha+beta/gamma===="},
        \\  {"page":0,"text":"sum(x_i^2)>=delta++++"}
        \\]
        \\
        ,
        .generate = testpdf.generateFormulaPdf,
    },
    .{
        .category = "scanned_typewritten",
        .doc_id = "image-only-page",
        .pdf_name = "image-only-page.pdf",
        .expected_ocr_pages = 1,
        .truth =
        \\SCANNED TYPEWRITTEN
        \\
        ,
        .generate = testpdf.generateImageOnlyPdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "aligned-financials",
        .pdf_name = "aligned-financials.pdf",
        .expected_table_regions = 4,
        .truth =
        \\Table 1.
        \\Year Revenue Margin
        \\2019 100 20
        \\2020 125 23
        \\2021 140 25
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Year" },
        \\        { "text": "Revenue" },
        \\        { "text": "Margin" }
        \\      ],
        \\      [
        \\        { "text": "2019" },
        \\        { "text": "100" },
        \\        { "text": "20" }
        \\      ],
        \\      [
        \\        { "text": "2020" },
        \\        { "text": "125" },
        \\        { "text": "23" }
        \\      ],
        \\      [
        \\        { "text": "2021" },
        \\        { "text": "140" },
        \\        { "text": "25" }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "complex-financials",
        .pdf_name = "complex-financials.pdf",
        .expected_table_regions = 4,
        .truth =
        \\Table 2.
        \\Account Revenue Expense Net
        \\Total revenue 1,200 (950) 250
        \\Services* -300 (450) (750)
        \\* excludes setup fees
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Revenue", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Expense", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Net", "role": "header", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Total revenue", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "1,200", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(950)", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "250", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Services*", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "-300", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(450)", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(750)", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "* excludes setup fees", "role": "note", "rowspan": 1, "colspan": 4 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateComplexFinancialTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "ruled-financials",
        .pdf_name = "ruled-financials.pdf",
        .source_note = "reduced fixture modeling ruled statement tables found in filings and invoices",
        .expected_table_regions = 3,
        .truth =
        \\Ruled Statement
        \\Account Q1 Q2
        \\Cash 1,000 (200)
        \\Debt -50 (75)
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Q1", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Q2", "role": "header", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Cash", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "1,000", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(200)", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Debt", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "-50", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(75)", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateRuledFinancialTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "ruled-multiline-financials",
        .pdf_name = "ruled-multiline-financials.pdf",
        .source_note = "reduced fixture modeling a ruled statement row whose label wraps inside one cell",
        .expected_table_regions = 4,
        .truth =
        \\Multiline Statement
        \\Account Actual Variance
        \\Deferred revenue 1,250 (300)
        \\Support 400 -25
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Actual", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Variance", "role": "header", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Deferred revenue", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "1,250", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(300)", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Support", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "400", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "-25", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateRuledMultilineFinancialTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "merged-cells-financials",
        .pdf_name = "merged-cells-financials.pdf",
        .source_note = "reduced fixture modeling merged statement headers with missing internal rulings",
        .expected_table_regions = 2,
        .truth =
        \\Merged Header Statement
        \\Operating metrics
        \\Account Actual Budget
        \\Revenue 1,200 1,050
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Operating metrics", "role": "header", "rowspan": 1, "colspan": 3 }
        \\      ],
        \\      [
        \\        { "text": "Account", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Actual", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Budget", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Revenue", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "1,200", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "1,050", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateMergedCellFinancialTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "rowspan-financials",
        .pdf_name = "rowspan-financials.pdf",
        .source_note = "reduced fixture modeling a financial section label spanning multiple ruled rows",
        .expected_table_regions = 3,
        .truth =
        \\Rowspan Statement
        \\Category Q1 Q2
        \\Assets 1,000 450
        \\300 125
        \\Liabilities (700) (200)
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Category", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Q1", "role": "header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "Q2", "role": "header", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Assets", "role": "row_header", "rowspan": 2, "colspan": 1 },
        \\        { "text": "1,000", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "450", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "300", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "125", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ],
        \\      [
        \\        { "text": "Liabilities", "role": "row_header", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(700)", "role": "data", "rowspan": 1, "colspan": 1 },
        \\        { "text": "(200)", "role": "data", "rowspan": 1, "colspan": 1 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateRowspanFinancialTablePdf,
    },
    .{
        .category = "financial_tables",
        .doc_id = "multipage-statement",
        .pdf_name = "multipage-statement.pdf",
        .source_note = "reduced fixture modeling repeated financial statement headers across pages",
        .expected_table_regions = 2,
        .truth =
        \\Statement page 1
        \\Account Amount
        \\Cash 1,000
        \\Inventory 450
        \\Statement page 2
        \\Account Amount
        \\Debt (300)
        \\Equity 1,150
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account", "role": "header", "page": 0 },
        \\        { "text": "Amount", "role": "header", "page": 0 }
        \\      ],
        \\      [
        \\        { "text": "Cash", "role": "row_header", "page": 0 },
        \\        { "text": "1,000", "role": "data", "page": 0 }
        \\      ],
        \\      [
        \\        { "text": "Inventory", "role": "row_header", "page": 0 },
        \\        { "text": "450", "role": "data", "page": 0 }
        \\      ]
        \\    ]
        \\  },
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account", "role": "header", "page": 1 },
        \\        { "text": "Amount", "role": "header", "page": 1 }
        \\      ],
        \\      [
        \\        { "text": "Debt", "role": "row_header", "page": 1 },
        \\        { "text": "(300)", "role": "data", "page": 1 }
        \\      ],
        \\      [
        \\        { "text": "Equity", "role": "row_header", "page": 1 },
        \\        { "text": "1,150", "role": "data", "page": 1 }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateMultipageFinancialStatementPdf,
    },
    .{
        .category = "forms",
        .doc_id = "acroform-fields",
        .pdf_name = "acroform-fields.pdf",
        .truth =
        \\All Fields
        \\email user@example.com
        \\country USA
        \\
        ,
        .form_json_truth =
        \\[
        \\  {"name":"email","type":"text","value":"user@example.com"},
        \\  {"name":"country","type":"choice","value":"USA"}
        \\]
        \\
        ,
        .generate = testpdf.generateAllFormFieldsPdf,
    },
    .{
        .category = "forms",
        .doc_id = "realistic-widget-fields",
        .pdf_name = "realistic-widget-fields.pdf",
        .source_note = "reduced fixture modeling nested AcroForm widgets with name-valued buttons",
        .truth =
        \\Profile Form
        \\profile.first_name Ada
        \\profile.email ada@example.com
        \\subscribe Yes
        \\cadence Quarterly
        \\country USA
        \\
        ,
        .form_json_truth =
        \\[
        \\  {"name":"profile.first_name","type":"text","value":"Ada"},
        \\  {"name":"profile.email","type":"text","value":"ada@example.com"},
        \\  {"name":"subscribe","type":"button","value":"Yes"},
        \\  {"name":"cadence","type":"button","value":"Quarterly"},
        \\  {"name":"country","type":"choice","value":"USA"}
        \\]
        \\
        ,
        .generate = testpdf.generateRealisticWidgetFieldsPdf,
    },
    .{
        .category = "forms",
        .doc_id = "inherited-widget-fields",
        .pdf_name = "inherited-widget-fields.pdf",
        .source_note = "reduced fixture modeling AcroForm widgets inheriting field type and value from parent dictionaries",
        .truth =
        \\Inherited Widgets
        \\consent.agree Yes
        \\preferences.region EMEA
        \\profile.phone 555-0100
        \\
        ,
        .form_json_truth =
        \\[
        \\  {"name":"consent.agree","type":"button","value":"Yes"},
        \\  {"name":"preferences.region","type":"choice","value":"EMEA"},
        \\  {"name":"profile.phone","type":"text","value":"555-0100"}
        \\]
        \\
        ,
        .generate = testpdf.generateInheritedWidgetFieldsPdf,
    },
    .{
        .category = "scanned_typewritten",
        .doc_id = "mixed-native-scan",
        .pdf_name = "mixed-native-scan.pdf",
        .source_note = "reduced fixture modeling a page with native text plus a dominant scanned region",
        .expected_ocr_pages = 1,
        .truth =
        \\Native cover text
        \\SCANNED TYPEWRITTEN
        \\
        ,
        .generate = testpdf.generateMixedNativeScanPdf,
    },
    .{
        .category = "weird_fonts",
        .doc_id = "actualtext-repair",
        .pdf_name = "actualtext-repair.pdf",
        .source_note = "synthetic marked-content fixture where ActualText repairs intentionally wrong visible glyph text",
        .truth =
        \\Correct ActualText replacement
        \\
        ,
        .font_truth =
        \\{
        \\  "expected_text": "Correct ActualText replacement",
        \\  "expect_actual_text": true,
        \\  "expect_unicode_map_error": false,
        \\  "expected_writing_mode": 0,
        \\  "required_glyph_trace_fields": ["record_type", "page_index", "span_id", "bbox", "source_code", "source_bytes", "text", "font_name", "font_size", "writing_mode", "generated", "hyphen", "unicode_map_error", "actual_text", "mcid"]
        \\}
        \\
        ,
        .font_case_tags = &.{ "actualtext", "marked-content" },
        .generate = testpdf.generateActualTextRepairPdf,
    },
    .{
        .category = "weird_fonts",
        .doc_id = "type3-simple",
        .pdf_name = "type3-simple.pdf",
        .source_note = "synthetic Type3 font fixture using WinAnsi text and deterministic width metadata",
        .truth =
        \\Type3 simple text
        \\
        ,
        .font_truth =
        \\{
        \\  "expected_text": "Type3 simple text",
        \\  "expect_actual_text": false,
        \\  "expect_unicode_map_error": false,
        \\  "expected_writing_mode": 0,
        \\  "required_glyph_trace_fields": ["record_type", "page_index", "span_id", "bbox", "text", "font_name", "font_size", "writing_mode", "unicode_map_error", "actual_text", "mcid"]
        \\}
        \\
        ,
        .font_case_tags = &.{ "type3", "winansi" },
        .generate = testpdf.generateType3SimplePdf,
    },
    .{
        .category = "weird_fonts",
        .doc_id = "type3-tounicode",
        .pdf_name = "type3-tounicode.pdf",
        .source_note = "synthetic Type3 font fixture where ToUnicode remaps raw ABC glyph codes to XYZ text",
        .truth =
        \\XYZ
        \\
        ,
        .font_truth =
        \\{
        \\  "expected_text": "XYZ",
        \\  "expect_actual_text": false,
        \\  "expect_unicode_map_error": false,
        \\  "expected_writing_mode": 0,
        \\  "required_glyph_trace_fields": ["record_type", "page_index", "span_id", "bbox", "source_code", "source_bytes", "text", "font_name", "font_size", "writing_mode", "unicode_map_error", "actual_text", "mcid"]
        \\}
        \\
        ,
        .font_case_tags = &.{ "type3", "tounicode" },
        .generate = testpdf.generateType3ToUnicodePdf,
    },
    .{
        .category = "weird_fonts",
        .doc_id = "identity-h-broken",
        .pdf_name = "identity-h-broken.pdf",
        .source_note = "synthetic Identity-H fixture without ToUnicode and a suspicious control CID",
        .truth =
        \\Broken identity
        \\
        ,
        .font_truth =
        \\{
        \\  "expected_text": "Broken identity",
        \\  "expect_actual_text": false,
        \\  "expect_unicode_map_error": true,
        \\  "expected_writing_mode": 0,
        \\  "required_glyph_trace_fields": ["record_type", "page_index", "span_id", "bbox", "source_code", "source_bytes", "text", "font_name", "font_size", "writing_mode", "unicode_map_error", "actual_text", "mcid"]
        \\}
        \\
        ,
        .font_case_tags = &.{ "identity-h", "missing-tounicode", "unicode-map-error" },
        .generate = testpdf.generateIdentityHBrokenPdf,
    },
    .{
        .category = "weird_fonts",
        .doc_id = "identity-v-vertical-cjk",
        .pdf_name = "identity-v-vertical-cjk.pdf",
        .source_note = "synthetic Identity-V fixture with ToUnicode Japanese text and vertical writing mode evidence",
        .truth =
        \\日本
        \\
        ,
        .font_truth =
        \\{
        \\  "expected_text": "日本",
        \\  "expect_actual_text": false,
        \\  "expect_unicode_map_error": false,
        \\  "expected_writing_mode": 1,
        \\  "required_glyph_trace_fields": ["record_type", "page_index", "span_id", "bbox", "source_code", "source_bytes", "text", "font_name", "font_size", "writing_mode", "unicode_map_error", "actual_text", "mcid"]
        \\}
        \\
        ,
        .font_case_tags = &.{ "identity-v", "vertical-cjk", "tounicode" },
        .generate = testpdf.generateIdentityVVerticalCjkPdf,
    },
    .{
        .category = "visual_truth",
        .doc_id = "rotated-page-text",
        .pdf_name = "rotated-page-text.pdf",
        .source_note = "synthetic rotated page fixture for render-backed geometry checks",
        .truth =
        \\Rotated page text
        \\
        ,
        .render_truth =
        \\{
        \\  "expected_page_count": 1,
        \\  "expected_issue_tags": ["rotated_geometry"],
        \\  "min_text_bbox_coverage": 0.0,
        \\  "max_blank_bbox_rate": 1.0,
        \\  "min_ruling_pixel_coverage": 0.0,
        \\  "min_image_region_overlap": 0.0
        \\}
        \\
        ,
        .visual_case_tags = &.{"rotated_geometry"},
        .generate = testpdf.generateRotatedPageTextPdf,
    },
    .{
        .category = "visual_truth",
        .doc_id = "clipped-text",
        .pdf_name = "clipped-text.pdf",
        .source_note = "synthetic clipping fixture where extracted text geometry may exceed rendered ink",
        .truth =
        \\Clipped fixture
        \\Clipped hidden tail
        \\
        ,
        .render_truth =
        \\{
        \\  "expected_page_count": 1,
        \\  "expected_issue_tags": ["clipped_text"],
        \\  "min_text_bbox_coverage": 0.0,
        \\  "max_blank_bbox_rate": 1.0,
        \\  "min_ruling_pixel_coverage": 0.0,
        \\  "min_image_region_overlap": 0.0
        \\}
        \\
        ,
        .visual_case_tags = &.{"clipped_text"},
        .generate = testpdf.generateClippedTextPdf,
    },
    .{
        .category = "visual_truth",
        .doc_id = "invisible-ocr-layer",
        .pdf_name = "invisible-ocr-layer.pdf",
        .source_note = "synthetic white-on-white text fixture modeling hidden OCR layers",
        .truth =
        \\Visible anchor
        \\Invisible OCR Layer
        \\
        ,
        .render_truth =
        \\{
        \\  "expected_page_count": 1,
        \\  "expected_issue_tags": ["invisible_text"],
        \\  "min_text_bbox_coverage": 0.0,
        \\  "max_blank_bbox_rate": 1.0,
        \\  "min_ruling_pixel_coverage": 0.0,
        \\  "min_image_region_overlap": 0.0
        \\}
        \\
        ,
        .visual_case_tags = &.{"invisible_text"},
        .generate = testpdf.generateInvisibleOcrLayerPdf,
    },
    .{
        .category = "visual_truth",
        .doc_id = "ruled-table-pixels",
        .pdf_name = "ruled-table-pixels.pdf",
        .source_note = "synthetic ruled table fixture for rendered ruling-line verification",
        .expected_table_regions = 3,
        .truth =
        \\Ruled Statement
        \\Account Q1 Q2
        \\Cash 1,000 (200)
        \\Debt -50 (75)
        \\
        ,
        .render_truth =
        \\{
        \\  "expected_page_count": 1,
        \\  "expected_issue_tags": ["ruling_lines"],
        \\  "min_text_bbox_coverage": 0.2,
        \\  "max_blank_bbox_rate": 0.8,
        \\  "min_ruling_pixel_coverage": 0.2,
        \\  "min_image_region_overlap": 0.0
        \\}
        \\
        ,
        .visual_case_tags = &.{"ruling_lines"},
        .generate = testpdf.generateRuledFinancialTablePdf,
    },
    .{
        .category = "visual_truth",
        .doc_id = "mixed-image-region",
        .pdf_name = "mixed-image-region.pdf",
        .source_note = "synthetic native text plus scanned image region fixture for crop verification",
        .expected_ocr_pages = 1,
        .truth =
        \\Native cover text
        \\SCANNED TYPEWRITTEN
        \\
        ,
        .render_truth =
        \\{
        \\  "expected_page_count": 1,
        \\  "expected_issue_tags": ["image_region"],
        \\  "min_text_bbox_coverage": 0.1,
        \\  "max_blank_bbox_rate": 0.9,
        \\  "min_ruling_pixel_coverage": 0.0,
        \\  "min_image_region_overlap": 0.0
        \\}
        \\
        ,
        .visual_case_tags = &.{"image_region"},
        .generate = testpdf.generateMixedNativeScanPdf,
    },
    .{
        .category = "adversarial_corrupt",
        .doc_id = "missing-page-type",
        .pdf_name = "missing-page-type.pdf",
        .truth =
        \\Adversarial page tree omits the page type but should still extract text.
        \\
        ,
        .generate = generateAdversarialPdf,
    },
};

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const root = if (args.len >= 2) args[1] else "benchmark/eval";
    try runtime.createDirPathCwd(root);
    try writeFixtures(allocator, root);
}

fn writeFixtures(allocator: std.mem.Allocator, root: []const u8) !void {
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);
    var manifest_writer = runtime.arrayListWriter(&manifest, allocator);
    try manifest_writer.writeAll("# category\tdoc_id\tpdf_path\ttruth_text_path\ttruth_table_json_path_optional\ttruth_reading_order_path_optional\ttruth_formula_path_optional\ttruth_formula_json_path_optional\ttruth_form_json_path_optional\n");

    var metadata: std.ArrayList(u8) = .empty;
    defer metadata.deinit(allocator);
    const metadata_writer = runtime.arrayListWriter(&metadata, allocator);

    for (fixtures) |fixture| {
        const corpus_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/corpus/{s}",
            .{ root, fixture.category },
        );
        defer allocator.free(corpus_dir);
        const truth_dir = try std.fmt.allocPrint(
            allocator,
            "{s}/ground_truth/page_text/{s}",
            .{ root, fixture.category },
        );
        defer allocator.free(truth_dir);
        try runtime.createDirPathCwd(corpus_dir);
        try runtime.createDirPathCwd(truth_dir);

        const pdf_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ corpus_dir, fixture.pdf_name },
        );
        defer allocator.free(pdf_path);
        const truth_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}.txt",
            .{ truth_dir, fixture.doc_id },
        );
        defer allocator.free(truth_path);

        const pdf = try fixture.generate(allocator);
        defer allocator.free(pdf);
        try writeFile(pdf_path, pdf);
        try writeFile(truth_path, fixture.truth);

        try manifest_writer.print("{s}\t{s}\t{s}\t{s}", .{
            fixture.category,
            fixture.doc_id,
            pdf_path,
            truth_path,
        });
        const table_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "tables",
            fixture.category,
            fixture.doc_id,
            "json",
            fixture.table_truth,
        );
        defer if (table_truth_path) |path| allocator.free(path);
        const reading_order_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "reading_order",
            fixture.category,
            fixture.doc_id,
            "txt",
            fixture.reading_order_truth,
        );
        defer if (reading_order_truth_path) |path| allocator.free(path);
        const formula_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "formulas",
            fixture.category,
            fixture.doc_id,
            "txt",
            fixture.formula_truth,
        );
        defer if (formula_truth_path) |path| allocator.free(path);
        const formula_json_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "formulas_json",
            fixture.category,
            fixture.doc_id,
            "json",
            fixture.formula_json_truth,
        );
        defer if (formula_json_truth_path) |path| allocator.free(path);
        const form_json_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "form_fields",
            fixture.category,
            fixture.doc_id,
            "json",
            fixture.form_json_truth,
        );
        defer if (form_json_truth_path) |path| allocator.free(path);
        const font_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "fonts",
            fixture.category,
            fixture.doc_id,
            "json",
            fixture.font_truth,
        );
        defer if (font_truth_path) |path| allocator.free(path);
        const render_truth_path = try writeOptionalTruth(
            allocator,
            root,
            "render_oracle",
            fixture.category,
            fixture.doc_id,
            "json",
            fixture.render_truth,
        );
        defer if (render_truth_path) |path| allocator.free(path);
        try writeFixtureMetadata(metadata_writer, fixture, pdf_path, truth_path, font_truth_path, render_truth_path, pdf);
        try writeOptionalManifestFields(
            manifest_writer,
            &.{ table_truth_path, reading_order_truth_path, formula_truth_path, formula_json_truth_path, form_json_truth_path },
        );
        try manifest_writer.writeByte('\n');
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/corpus/manifest.tsv", .{root});
    defer allocator.free(manifest_path);
    try writeFile(manifest_path, manifest.items);

    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/corpus/metadata.jsonl", .{root});
    defer allocator.free(metadata_path);
    try writeFile(metadata_path, metadata.items);
}

fn writeFixtureMetadata(
    writer: anytype,
    fixture: Fixture,
    pdf_path: []const u8,
    truth_path: []const u8,
    font_truth_path: ?[]const u8,
    render_truth_path: ?[]const u8,
    pdf: []const u8,
) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pdf, &digest, .{});
    var digest_hex: [64]u8 = undefined;
    writeHexLower(&digest_hex, &digest);

    try writer.writeAll("{\"category\":\"");
    try writeJsonEscaped(writer, fixture.category);
    try writer.writeAll("\",\"doc_id\":\"");
    try writeJsonEscaped(writer, fixture.doc_id);
    try writer.writeAll("\",\"pdf_path\":\"");
    try writeJsonEscaped(writer, pdf_path);
    try writer.writeAll("\",\"truth_text_path\":\"");
    try writeJsonEscaped(writer, truth_path);
    if (font_truth_path) |path| {
        try writer.writeAll("\",\"font_truth_path\":\"");
        try writeJsonEscaped(writer, path);
    }
    if (render_truth_path) |path| {
        try writer.writeAll("\",\"render_truth_path\":\"");
        try writeJsonEscaped(writer, path);
    }
    try writer.writeAll("\",\"source_note\":\"");
    try writeJsonEscaped(writer, fixture.source_note);
    try writer.writeAll("\",\"license_status\":\"");
    try writeJsonEscaped(writer, fixture.license_status);
    try writer.writeAll("\",\"sha256\":\"");
    try writer.writeAll(&digest_hex);
    try writer.print("\",\"expected_ocr_pages\":{},\"expected_table_regions\":{},\"expected_formula_regions\":{},\"font_case_tags\":[", .{
        fixture.expected_ocr_pages,
        fixture.expected_table_regions,
        fixture.expected_formula_regions,
    });
    for (fixture.font_case_tags, 0..) |tag, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeJsonEscaped(writer, tag);
        try writer.writeByte('"');
    }
    try writer.writeAll("],\"visual_case_tags\":[");
    for (fixture.visual_case_tags, 0..) |tag, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeJsonEscaped(writer, tag);
        try writer.writeByte('"');
    }
    try writer.writeAll("]}\n");
}

fn writeHexLower(out: *[64]u8, bytes: *const [32]u8) void {
    const alphabet = "0123456789abcdef";
    for (bytes.*, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

fn writeOptionalManifestFields(writer: anytype, fields: []const ?[]const u8) !void {
    var field_count = fields.len;
    while (field_count > 0 and fields[field_count - 1] == null) {
        field_count -= 1;
    }

    for (fields[0..field_count]) |field| {
        try writer.writeByte('\t');
        if (field) |value| try writer.writeAll(value);
    }
}

fn writeOptionalTruth(
    allocator: std.mem.Allocator,
    root: []const u8,
    kind: []const u8,
    category: []const u8,
    doc_id: []const u8,
    extension: []const u8,
    content: ?[]const u8,
) !?[]u8 {
    const bytes = content orelse return null;
    const truth_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/ground_truth/{s}/{s}",
        .{ root, kind, category },
    );
    defer allocator.free(truth_dir);
    try runtime.createDirPathCwd(truth_dir);

    const truth_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.{s}",
        .{ truth_dir, doc_id, extension },
    );
    errdefer allocator.free(truth_path);
    try writeFile(truth_path, bytes);
    return truth_path;
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = try runtime.createFileCwd(path);
    defer runtime.closeFile(file);
    try runtime.writeAllFile(file, bytes);
}

fn generateAdversarialPdf(allocator: std.mem.Allocator) ![]u8 {
    return testpdf.generatePdfWithoutPageType(
        allocator,
        "Adversarial page tree omits the page type but should still extract text.",
    );
}
