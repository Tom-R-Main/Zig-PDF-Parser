//! JSONL evaluation runner.
//!
//! Usage:
//!   zig build eval -- sample.pdf --truth-text ground_truth/sample.txt

const std = @import("std");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");
const eval = @import("eval.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

const Options = struct {
    pdf_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    truth_text_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    doc_id: ?[]const u8 = null,
    parser: []const u8 = "pdf-parser",
    category: eval.CorpusCategory = .clean_born_digital,
    mode: zpdf.FullTextMode = .accuracy,
    reading_order_score: ?f64 = null,
    table_f1: ?f64 = null,
    teds: ?f64 = null,
    grits: ?f64 = null,
    formula_bleu: ?f64 = null,
    formula_cdm: ?f64 = null,
    native_pages: ?u32 = null,
    ocr_pages: u32 = 0,
    table_regions: u32 = 0,
    formula_regions: u32 = 0,
};

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = parseArgs(args[1..]) catch |err| {
        try printUsage();
        if (err == error.HelpRequested) return;
        return err;
    };

    if (options.manifest_path) |manifest_path| {
        const jsonl = try runManifest(allocator, options, manifest_path);
        defer allocator.free(jsonl);
        try writeOutput(options.output_path, jsonl);
        return;
    }

    if (options.pdf_path == null) {
        try printUsage();
        return;
    }

    const jsonl = try evaluateOneToJsonl(allocator, options);
    defer allocator.free(jsonl);
    try writeOutput(options.output_path, jsonl);
}

const ManifestEntry = struct {
    category: eval.CorpusCategory,
    doc_id: []const u8,
    pdf_path: []const u8,
    truth_text_path: []const u8,
};

fn runManifest(
    allocator: std.mem.Allocator,
    base_options: Options,
    manifest_path: []const u8,
) ![]u8 {
    const manifest = try runtime.readFileAllocAlignedCwd(allocator, manifest_path, .fromByteUnits(1));
    defer allocator.free(manifest);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, manifest, '\n');
    while (line_it.next()) |raw_line| {
        const entry = try parseManifestLine(raw_line) orelse continue;
        var options = base_options;
        options.pdf_path = entry.pdf_path;
        options.truth_text_path = entry.truth_text_path;
        options.doc_id = entry.doc_id;
        options.category = entry.category;
        options.output_path = null;
        options.manifest_path = null;

        const jsonl = try evaluateOneToJsonl(allocator, options);
        defer allocator.free(jsonl);
        try out.appendSlice(allocator, jsonl);
    }

    return out.toOwnedSlice(allocator);
}

fn parseManifestLine(raw_line: []const u8) !?ManifestEntry {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return null;

    var fields = std.mem.splitScalar(u8, line, '\t');
    const category_text = fields.next() orelse return error.MalformedManifest;
    const doc_id = fields.next() orelse return error.MalformedManifest;
    const pdf_path = fields.next() orelse return error.MalformedManifest;
    const truth_text_path = fields.next() orelse return error.MalformedManifest;
    if (fields.next() != null) return error.MalformedManifest;

    return .{
        .category = eval.CorpusCategory.parse(category_text) orelse return error.UnknownCategory,
        .doc_id = doc_id,
        .pdf_path = pdf_path,
        .truth_text_path = truth_text_path,
    };
}

fn evaluateOneToJsonl(allocator: std.mem.Allocator, options: Options) ![]u8 {
    const pdf_path = options.pdf_path orelse return error.MissingInput;
    var truth_text: ?[]align(1) u8 = null;
    defer if (truth_text) |text| allocator.free(text);
    if (options.truth_text_path) |path| {
        truth_text = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }

    const start_rss = eval.currentPeakRssMb();
    _ = start_rss;
    const start_ns = runtime.nanoTimestamp();

    const doc = try zpdf.Document.openWithConfig(allocator, pdf_path, zpdf.ErrorConfig.permissive());
    const page_count: u32 = @intCast(doc.pages.items.len);
    const extracted = try doc.extractAllTextWithMode(allocator, options.mode);
    doc.close();
    defer allocator.free(extracted);

    const elapsed_ns = runtime.nanoTimestamp() - start_ns;
    const peak_rss_mb = eval.currentPeakRssMb();

    var text_metrics: eval.TextMetrics = .{};
    if (truth_text) |truth| {
        text_metrics = try eval.evaluateText(allocator, .{
            .prediction = extracted,
            .ground_truth = truth,
        });
    }

    const samples = [_]i128{elapsed_ns};
    const latency = try eval.latencyFromSamples(allocator, page_count, &samples, peak_rss_mb);
    const doc_id = options.doc_id orelse std.fs.path.basename(pdf_path);
    const result: eval.DocumentResult = .{
        .doc_id = doc_id,
        .parser = options.parser,
        .category = options.category,
        .pages = page_count,
        .text = text_metrics,
        .reading_order_score = options.reading_order_score,
        .table = .{
            .detection = .{ .f1 = options.table_f1 },
            .teds = options.teds,
            .grits = options.grits,
        },
        .formula = .{
            .bleu = options.formula_bleu,
            .cdm = options.formula_cdm,
        },
        .latency = latency,
        .counters = .{
            .native_pages = options.native_pages orelse if (extracted.len == 0) 0 else page_count,
            .ocr_pages = options.ocr_pages,
            .table_regions = options.table_regions,
            .formula_regions = options.formula_regions,
        },
    };

    return eval.resultToJsonl(allocator, result);
}

fn writeOutput(output_path: ?[]const u8, jsonl: []const u8) !void {
    if (output_path) |path| {
        const file = try runtime.createFileCwd(path);
        defer runtime.closeFile(file);
        try runtime.writeAllFile(file, jsonl);
    } else {
        try runtime.writeAllStdout(jsonl);
    }
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.manifest_path = args[index];
        } else if (std.mem.eql(u8, arg, "--truth-text")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_text_path = args[index];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--doc-id")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.doc_id = args[index];
        } else if (std.mem.eql(u8, arg, "--parser")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.parser = args[index];
        } else if (std.mem.eql(u8, arg, "--category")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.category = eval.CorpusCategory.parse(args[index]) orelse return error.UnknownCategory;
        } else if (std.mem.eql(u8, arg, "--reading-order-score")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.reading_order_score = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--table-f1")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.table_f1 = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--teds")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.teds = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--grits")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.grits = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--formula-bleu")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.formula_bleu = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--formula-cdm")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.formula_cdm = try parseScore(args[index]);
        } else if (std.mem.eql(u8, arg, "--native-pages")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.native_pages = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--ocr-pages")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_pages = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--table-regions")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.table_regions = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--formula-regions")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.formula_regions = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--fast")) {
            options.mode = .fast;
        } else if (std.mem.eql(u8, arg, "--accuracy")) {
            options.mode = .accuracy;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (options.pdf_path == null) {
            options.pdf_path = arg;
        } else {
            return error.TooManyInputs;
        }
    }
    return options;
}

fn parseScore(text: []const u8) !f64 {
    const score = try std.fmt.parseFloat(f64, text);
    if (score < 0 or score > 1) return error.ScoreOutOfRange;
    return score;
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var bw = runtime.stdoutWriter(&buf);
    const stdout = &bw.interface;
    defer stdout.flush() catch {};

    try stdout.writeAll(
        \\pdf-parser-eval - per-document parser evaluation
        \\
        \\Usage:
        \\  zig build eval -- <input.pdf> [options]
        \\  zig build eval -- --manifest benchmark/eval/corpus/manifest.tsv
        \\
        \\Options:
        \\  --manifest FILE         TSV corpus manifest: category, doc_id, pdf, truth
        \\  --truth-text FILE       Plain-text ground truth for CER/WER/token metrics
        \\  --category NAME         Corpus category, e.g. clean_born_digital
        \\  --doc-id ID             Stable document id for JSONL output
        \\  --parser NAME           Parser label (default: pdf-parser)
        \\  --fast                  Use fast native extraction mode
        \\  --accuracy              Use accuracy extraction mode (default)
        \\  -o, --output FILE       Write one JSONL record to file
        \\  --reading-order-score N External reading-order score, 0..1
        \\  --table-f1 N            External table detection F1, 0..1
        \\  --teds N                External table TEDS score, 0..1
        \\  --grits N               External table GriTS score, 0..1
        \\  --formula-bleu N        External formula BLEU score, 0..1
        \\  --formula-cdm N         External formula render/CDM score, 0..1
        \\  --native-pages N        Native-text page count override
        \\  --ocr-pages N           OCR-routed page count
        \\  --table-regions N       Table-routed region count
        \\  --formula-regions N     Formula-routed region count
        \\
        \\Categories:
        \\  clean_born_digital, academic_two_column, scientific_math,
        \\  scanned_typewritten, patents, financial_tables, legal_contracts,
        \\  manuals, forms, adversarial_corrupt
        \\
    );
}

test "eval runner parses category and options" {
    const options = try parseArgs(&.{
        "sample.pdf",
        "--truth-text",
        "truth.txt",
        "--category",
        "scientific_math",
        "--doc-id",
        "sample",
        "--fast",
        "--reading-order-score",
        "0.75",
        "--table-f1",
        "0.8",
        "--teds",
        "0.7",
        "--grits",
        "0.6",
        "--formula-bleu",
        "0.9",
        "--formula-cdm",
        "0.5",
        "--ocr-pages",
        "1",
    });
    try std.testing.expectEqualStrings("sample.pdf", options.pdf_path.?);
    try std.testing.expectEqualStrings("truth.txt", options.truth_text_path.?);
    try std.testing.expectEqual(eval.CorpusCategory.scientific_math, options.category);
    try std.testing.expectEqual(zpdf.FullTextMode.fast, options.mode);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), options.reading_order_score.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), options.table_f1.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), options.teds.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), options.grits.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), options.formula_bleu.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), options.formula_cdm.?, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), options.ocr_pages);
}

test "eval runner parses manifest option" {
    const options = try parseArgs(&.{
        "--manifest",
        "benchmark/eval/corpus/manifest.tsv",
        "--parser",
        "candidate",
    });
    try std.testing.expectEqualStrings("benchmark/eval/corpus/manifest.tsv", options.manifest_path.?);
    try std.testing.expectEqualStrings("candidate", options.parser);
}

test "eval runner parses manifest rows" {
    const entry = (try parseManifestLine(
        "scientific_math\tmath-notation\tcorpus/scientific_math/math-notation.pdf\ttruth/math-notation.txt\r",
    )).?;
    try std.testing.expectEqual(eval.CorpusCategory.scientific_math, entry.category);
    try std.testing.expectEqualStrings("math-notation", entry.doc_id);
    try std.testing.expectEqualStrings("corpus/scientific_math/math-notation.pdf", entry.pdf_path);
    try std.testing.expectEqualStrings("truth/math-notation.txt", entry.truth_text_path);
    try std.testing.expect((try parseManifestLine("# comment")) == null);
}
