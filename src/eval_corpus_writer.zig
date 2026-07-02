//! Deterministic writer for the tiny checked-in evaluation corpus.

const std = @import("std");
const runtime = @import("runtime.zig");
const testpdf = @import("testpdf.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

const Fixture = struct {
    category: []const u8,
    doc_id: []const u8,
    pdf_name: []const u8,
    truth: []const u8,
    table_truth: ?[]const u8 = null,
    reading_order_truth: ?[]const u8 = null,
    formula_truth: ?[]const u8 = null,
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
        .generate = testpdf.generateFormulaPdf,
    },
    .{
        .category = "scanned_typewritten",
        .doc_id = "image-only-page",
        .pdf_name = "image-only-page.pdf",
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
        .truth =
        \\Table 2.
        \\Account Revenue Expense Net
        \\Total revenue 1,200 (950) 250
        \\Services* * excludes setup fees -300 (450) (750)
        \\
        ,
        .table_truth =
        \\[
        \\  {
        \\    "rows": [
        \\      [
        \\        { "text": "Account" },
        \\        { "text": "Revenue" },
        \\        { "text": "Expense" },
        \\        { "text": "Net" }
        \\      ],
        \\      [
        \\        { "text": "Total revenue" },
        \\        { "text": "1,200" },
        \\        { "text": "(950)" },
        \\        { "text": "250" }
        \\      ],
        \\      [
        \\        { "text": "Services* * excludes setup fees" },
        \\        { "text": "-300" },
        \\        { "text": "(450)" },
        \\        { "text": "(750)" }
        \\      ]
        \\    ]
        \\  }
        \\]
        \\
        ,
        .generate = testpdf.generateComplexFinancialTablePdf,
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
        .generate = testpdf.generateAllFormFieldsPdf,
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
    try manifest_writer.writeAll("# category\tdoc_id\tpdf_path\ttruth_text_path\ttruth_table_json_path_optional\ttruth_reading_order_path_optional\ttruth_formula_path_optional\n");

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
        try writeOptionalManifestFields(
            manifest_writer,
            &.{ table_truth_path, reading_order_truth_path, formula_truth_path },
        );
        try manifest_writer.writeByte('\n');
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/corpus/manifest.tsv", .{root});
    defer allocator.free(manifest_path);
    try writeFile(manifest_path, manifest.items);
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
