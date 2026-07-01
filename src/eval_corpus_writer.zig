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
        .generate = testpdf.generateFormulaPdf,
    },
    .{
        .category = "scanned_typewritten",
        .doc_id = "image-only-page",
        .pdf_name = "image-only-page.pdf",
        .truth =
        \\Scanned typewritten page requires OCR to recover this text.
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
        .generate = testpdf.generateTablePdf,
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
    try manifest_writer.writeAll("# category\tdoc_id\tpdf_path\ttruth_text_path\n");

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

        try manifest_writer.print("{s}\t{s}\t{s}\t{s}\n", .{
            fixture.category,
            fixture.doc_id,
            pdf_path,
            truth_path,
        });
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/corpus/manifest.tsv", .{root});
    defer allocator.free(manifest_path);
    try writeFile(manifest_path, manifest.items);
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
