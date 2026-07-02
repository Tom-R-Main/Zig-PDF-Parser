//! JSONL evaluation runner.
//!
//! Usage:
//!   zig build eval -- sample.pdf --truth-text ground_truth/sample.txt

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");
const eval = @import("eval.zig");
const layout = @import("layout.zig");
const testpdf = @import("testpdf.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

const ExtractionMode = enum {
    native,
    adaptive,
};

const Options = struct {
    pdf_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    truth_text_path: ?[]const u8 = null,
    truth_table_json_path: ?[]const u8 = null,
    truth_reading_order_path: ?[]const u8 = null,
    truth_formula_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    doc_id: ?[]const u8 = null,
    parser: []const u8 = "pdf-parser",
    category: eval.CorpusCategory = .clean_born_digital,
    mode: zpdf.FullTextMode = .accuracy,
    extraction_mode: ExtractionMode = .native,
    enable_ocr: bool = true,
    ocr_config: zpdf.OcrConfig = .{},
    reading_order_score: ?f64 = null,
    table_f1: ?f64 = null,
    teds: ?f64 = null,
    grits: ?f64 = null,
    formula_bleu: ?f64 = null,
    formula_cdm: ?f64 = null,
    native_pages: ?u32 = null,
    ocr_pages: ?u32 = null,
    table_regions: ?u32 = null,
    formula_regions: ?u32 = null,
};

const ExtractionOutput = struct {
    text: []u8,
    counters: eval.ExtractionCounters = .{},
    adaptive: ?zpdf.AdaptiveResult = null,

    fn deinit(self: *ExtractionOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.adaptive) |*result| result.deinit();
    }
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
    truth_table_json_path: ?[]const u8 = null,
    truth_reading_order_path: ?[]const u8 = null,
    truth_formula_path: ?[]const u8 = null,
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
        options.truth_table_json_path = entry.truth_table_json_path;
        options.truth_reading_order_path = entry.truth_reading_order_path;
        options.truth_formula_path = entry.truth_formula_path;
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
    const truth_table_json_path = optionalManifestField(fields.next());
    const truth_reading_order_path = optionalManifestField(fields.next());
    const truth_formula_path = optionalManifestField(fields.next());
    if (fields.next() != null) return error.MalformedManifest;

    return .{
        .category = eval.CorpusCategory.parse(category_text) orelse return error.UnknownCategory,
        .doc_id = doc_id,
        .pdf_path = pdf_path,
        .truth_text_path = truth_text_path,
        .truth_table_json_path = truth_table_json_path,
        .truth_reading_order_path = truth_reading_order_path,
        .truth_formula_path = truth_formula_path,
    };
}

fn optionalManifestField(field: ?[]const u8) ?[]const u8 {
    const value = field orelse return null;
    return if (value.len == 0) null else value;
}

fn evaluateOneToJsonl(allocator: std.mem.Allocator, options: Options) ![]u8 {
    const pdf_path = options.pdf_path orelse return error.MissingInput;
    var truth_text: ?[]align(1) u8 = null;
    defer if (truth_text) |text| allocator.free(text);
    if (options.truth_text_path) |path| {
        truth_text = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }
    var truth_table_json: ?[]align(1) u8 = null;
    defer if (truth_table_json) |json| allocator.free(json);
    if (options.truth_table_json_path) |path| {
        truth_table_json = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }
    var truth_reading_order: ?[]align(1) u8 = null;
    defer if (truth_reading_order) |text| allocator.free(text);
    if (options.truth_reading_order_path) |path| {
        truth_reading_order = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }
    var truth_formula: ?[]align(1) u8 = null;
    defer if (truth_formula) |text| allocator.free(text);
    if (options.truth_formula_path) |path| {
        truth_formula = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }

    const start_rss = eval.currentPeakRssMb();
    _ = start_rss;
    const start_ns = runtime.nanoTimestamp();

    var doc = try zpdf.Document.openWithConfig(allocator, pdf_path, zpdf.ErrorConfig.permissive());
    defer doc.close();
    const page_count: u32 = @intCast(doc.pages.items.len);
    var extraction = try extractForEvaluation(allocator, doc, options, page_count);
    defer extraction.deinit(allocator);

    var reading_order_score = options.reading_order_score;
    if (truth_reading_order) |truth| {
        const order_metrics = try eval.evaluateText(allocator, .{
            .prediction = extraction.text,
            .ground_truth = truth,
        });
        reading_order_score = order_metrics.local_alignment;
    }
    var table_cell_accuracy: ?f64 = null;
    if (truth_table_json) |truth_json| {
        const predicted_table_json = try renderDocumentTablesJson(allocator, doc);
        defer allocator.free(predicted_table_json);
        table_cell_accuracy = try evaluateTableCellAccuracy(allocator, predicted_table_json, truth_json);
    }
    var formula_metrics: eval.FormulaMetrics = .{
        .bleu = options.formula_bleu,
        .cdm = options.formula_cdm,
    };
    if (truth_formula) |truth| {
        const predicted_formula = try renderDocumentFormulaText(allocator, doc);
        defer allocator.free(predicted_formula);
        const formula_text_metrics = try eval.evaluateText(allocator, .{
            .prediction = predicted_formula,
            .ground_truth = truth,
        });
        formula_metrics.bleu = formula_text_metrics.bleu4;
        formula_metrics.edit_distance = formula_text_metrics.normalized_edit_distance;
    }

    const elapsed_ns = runtime.nanoTimestamp() - start_ns;
    const peak_rss_mb = eval.currentPeakRssMb();

    var text_metrics: eval.TextMetrics = .{};
    if (truth_text) |truth| {
        text_metrics = try eval.evaluateText(allocator, .{
            .prediction = extraction.text,
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
        .reading_order_score = reading_order_score,
        .table = .{
            .detection = .{ .f1 = options.table_f1 },
            .teds = options.teds,
            .grits = options.grits,
            .cell_accuracy = table_cell_accuracy,
        },
        .formula = formula_metrics,
        .latency = latency,
        .counters = .{
            .native_pages = options.native_pages orelse extraction.counters.native_pages,
            .ocr_pages = options.ocr_pages orelse extraction.counters.ocr_pages,
            .table_regions = options.table_regions orelse extraction.counters.table_regions,
            .formula_regions = options.formula_regions orelse extraction.counters.formula_regions,
        },
    };

    return eval.resultToJsonl(allocator, result);
}

fn extractForEvaluation(
    allocator: std.mem.Allocator,
    doc: *zpdf.Document,
    options: Options,
    page_count: u32,
) !ExtractionOutput {
    switch (options.extraction_mode) {
        .native => {
            const text = try doc.extractAllTextWithMode(allocator, options.mode);
            errdefer allocator.free(text);
            return .{
                .text = text,
                .counters = .{
                    .native_pages = if (text.len == 0) 0 else page_count,
                },
            };
        },
        .adaptive => {
            var result = try doc.extractAdaptive(allocator, .{
                .enable_ocr = options.enable_ocr,
                .ocr_config = options.ocr_config,
            });
            errdefer result.deinit();
            var text = try result.render(allocator, .text);
            text = try appendFormFieldText(allocator, doc, text);
            errdefer allocator.free(text);
            return .{
                .text = text,
                .counters = try adaptiveCounters(allocator, &result, page_count),
                .adaptive = result,
            };
        },
    }
}

fn appendFormFieldText(allocator: std.mem.Allocator, doc: *zpdf.Document, text: []u8) ![]u8 {
    errdefer allocator.free(text);

    const form_text = try doc.extractFormFieldText(allocator);
    defer allocator.free(form_text);
    if (form_text.len == 0) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text);
    if (out.items.len > 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, form_text);
    allocator.free(text);
    return out.toOwnedSlice(allocator);
}

fn adaptiveCounters(
    allocator: std.mem.Allocator,
    result: *const zpdf.AdaptiveResult,
    page_count: u32,
) !eval.ExtractionCounters {
    var pages_with_native_text = try allocator.alloc(bool, page_count);
    defer allocator.free(pages_with_native_text);
    @memset(pages_with_native_text, false);

    var pages_with_fresh_ocr = try allocator.alloc(bool, page_count);
    defer allocator.free(pages_with_fresh_ocr);
    @memset(pages_with_fresh_ocr, false);

    var table_regions: u32 = 0;
    var formula_regions: u32 = 0;

    for (result.reconciled.spans) |span| {
        const page_index = span.span.page_index;
        if (page_index >= page_count) continue;
        if (span.chosen_source == .fresh_ocr) {
            pages_with_fresh_ocr[page_index] = true;
        } else if (span.chosen_source == .native_pdf) {
            pages_with_native_text[page_index] = true;
        }
    }

    for (result.region_routes) |route| {
        if (route.route.needs_table_model) table_regions += 1;
        if (route.route.needs_formula_model) formula_regions += 1;
    }

    return .{
        .native_pages = countTrue(pages_with_native_text),
        .ocr_pages = countTrue(pages_with_fresh_ocr),
        .table_regions = table_regions,
        .formula_regions = formula_regions,
    };
}

fn countTrue(values: []const bool) u32 {
    var count: u32 = 0;
    for (values) |value| {
        if (value) count += 1;
    }
    return count;
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

fn renderDocumentTablesJson(allocator: std.mem.Allocator, doc: *zpdf.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('[');
    for (0..doc.pages.items.len) |page_index| {
        if (page_index > 0) try writer.writeByte(',');
        try doc.writePageTablesJson(page_index, allocator, writer);
    }
    try writer.writeByte(']');

    return out.toOwnedSlice(allocator);
}

fn renderDocumentFormulaText(allocator: std.mem.Allocator, doc: *zpdf.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    for (0..doc.pages.items.len) |page_index| {
        const page = doc.pages.items[page_index];
        const page_width = page.media_box[2] - page.media_box[0];
        const spans = try doc.extractTextWithBounds(page_index, allocator);
        defer zpdf.Document.freeTextSpans(allocator, spans);

        var page_layout = try layout.analyzeLayout(allocator, spans, page_width);
        defer page_layout.deinit();

        for (page_layout.blocks) |block| {
            if (block.kind != .formula_candidate) continue;
            if (out.items.len > 0) try writer.writeByte('\n');
            try writeBlockText(writer, block);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn writeBlockText(writer: anytype, block: layout.LayoutBlock) !void {
    for (block.lines, 0..) |line, line_index| {
        if (line_index > 0) try writer.writeByte('\n');
        for (line.words, 0..) |word, word_index| {
            if (word_index > 0) try writer.writeByte(' ');
            try writer.writeAll(word.bounds.text);
        }
    }
}

fn evaluateTableCellAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !f64 {
    const predicted = try extractTableCellTexts(allocator, predicted_json);
    defer freeStringList(allocator, predicted);
    const truth = try extractTableCellTexts(allocator, truth_json);
    defer freeStringList(allocator, truth);

    if (truth.len == 0) return if (predicted.len == 0) 1.0 else 0.0;

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (std.mem.eql(u8, predicted[index], truth[index])) matched += 1;
    }

    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn extractTableCellTexts(allocator: std.mem.Allocator, json: []const u8) ![][]u8 {
    var cells: std.ArrayList([]u8) = .empty;
    errdefer {
        for (cells.items) |cell| allocator.free(cell);
        cells.deinit(allocator);
    }

    var cursor: usize = 0;
    const needle = "\"text\"";
    while (std.mem.indexOf(u8, json[cursor..], needle)) |relative_index| {
        var pos = cursor + relative_index + needle.len;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') {
            cursor = pos;
            continue;
        }
        pos += 1;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != '"') {
            cursor = pos;
            continue;
        }
        pos += 1;
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);

        while (pos < json.len) : (pos += 1) {
            const byte = json[pos];
            if (byte == '"') {
                pos += 1;
                break;
            }
            if (byte == '\\' and pos + 1 < json.len) {
                pos += 1;
                try text.append(allocator, switch (json[pos]) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => json[pos],
                });
            } else {
                try text.append(allocator, byte);
            }
        }

        try cells.append(allocator, try text.toOwnedSlice(allocator));
        cursor = pos;
    }

    return cells.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
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
        } else if (std.mem.eql(u8, arg, "--truth-table-json")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_table_json_path = args[index];
        } else if (std.mem.eql(u8, arg, "--truth-reading-order")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_reading_order_path = args[index];
        } else if (std.mem.eql(u8, arg, "--truth-formula")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_formula_path = args[index];
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
        } else if (std.mem.eql(u8, arg, "--adaptive")) {
            options.extraction_mode = .adaptive;
        } else if (std.mem.eql(u8, arg, "--disable-ocr")) {
            options.enable_ocr = false;
        } else if (std.mem.eql(u8, arg, "--ocr-executable")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.executable = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-rasterizer")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.rasterizer_executable = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-lang")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.lang = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-dpi")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.dpi = try std.fmt.parseInt(u32, args[index], 10);
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
        \\  --manifest FILE         TSV corpus manifest: category, doc_id, pdf, text truth, optional specialist truths
        \\  --truth-text FILE       Plain-text ground truth for CER/WER/token metrics
        \\  --truth-table-json FILE Table JSON ground truth for cell text accuracy
        \\  --truth-reading-order FILE Reading-order text truth for local-alignment score
        \\  --truth-formula FILE    Formula text truth for formula BLEU/edit-distance
        \\  --category NAME         Corpus category, e.g. clean_born_digital
        \\  --doc-id ID             Stable document id for JSONL output
        \\  --parser NAME           Parser label (default: pdf-parser)
        \\  --fast                  Use fast native extraction mode
        \\  --accuracy              Use accuracy extraction mode (default)
        \\  --adaptive              Use adaptive extraction, including OCR when routed
        \\  --disable-ocr           Keep adaptive OCR routes traceable but do not invoke OCR
        \\  --ocr-executable FILE   Tesseract executable for adaptive OCR
        \\  --ocr-rasterizer FILE   pdftoppm-compatible rasterizer for adaptive OCR
        \\  --ocr-lang LANG         Tesseract language code (default: eng)
        \\  --ocr-dpi N             Rasterization DPI for adaptive OCR
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
        "--truth-table-json",
        "tables.json",
        "--truth-reading-order",
        "reading.txt",
        "--truth-formula",
        "formula.txt",
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
        "--adaptive",
        "--ocr-executable",
        "fake-tesseract",
        "--ocr-rasterizer",
        "fake-rasterizer",
        "--ocr-lang",
        "eng+equ",
        "--ocr-dpi",
        "200",
        "--ocr-pages",
        "1",
    });
    try std.testing.expectEqualStrings("sample.pdf", options.pdf_path.?);
    try std.testing.expectEqualStrings("truth.txt", options.truth_text_path.?);
    try std.testing.expectEqualStrings("tables.json", options.truth_table_json_path.?);
    try std.testing.expectEqualStrings("reading.txt", options.truth_reading_order_path.?);
    try std.testing.expectEqualStrings("formula.txt", options.truth_formula_path.?);
    try std.testing.expectEqual(eval.CorpusCategory.scientific_math, options.category);
    try std.testing.expectEqual(zpdf.FullTextMode.fast, options.mode);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), options.reading_order_score.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), options.table_f1.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), options.teds.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), options.grits.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), options.formula_bleu.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), options.formula_cdm.?, 0.0001);
    try std.testing.expectEqual(ExtractionMode.adaptive, options.extraction_mode);
    try std.testing.expectEqualStrings("fake-tesseract", options.ocr_config.executable);
    try std.testing.expectEqualStrings("fake-rasterizer", options.ocr_config.rasterizer_executable);
    try std.testing.expectEqualStrings("eng+equ", options.ocr_config.lang);
    try std.testing.expectEqual(@as(u32, 200), options.ocr_config.dpi);
    try std.testing.expectEqual(@as(u32, 1), options.ocr_pages.?);
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

test "eval runner adaptive mode emits OCR text metrics and counters" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateImageOnlyPdf(allocator);
    defer allocator.free(pdf_data);

    var pdf_buf: [96]u8 = undefined;
    const pdf_path = try std.fmt.bufPrint(&pdf_buf, "pdf-parser-eval-ocr-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(pdf_path);
    defer runtime.deleteFileCwd(pdf_path);
    const pdf_file = try runtime.createFileCwd(pdf_path);
    try runtime.writeAllFile(pdf_file, pdf_data);
    runtime.closeFile(pdf_file);

    var truth_buf: [96]u8 = undefined;
    const truth_path = try std.fmt.bufPrint(&truth_buf, "pdf-parser-eval-ocr-truth-{x}.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(truth_path);
    defer runtime.deleteFileCwd(truth_path);
    const truth_file = try runtime.createFileCwd(truth_path);
    try runtime.writeAllFile(truth_file, "Scanned typewritten text\n");
    runtime.closeFile(truth_file);

    const fake_rasterizer =
        \\#!/bin/sh
        \\last=""
        \\for arg do last="$arg"; done
        \\printf '\211PNG\r\n\032\n\000\000\000\rIHDR\000\000\003\350\000\000\007\320' > "$last.png"
        \\
    ;
    var raster_buf: [96]u8 = undefined;
    const raster_path = try std.fmt.bufPrint(&raster_buf, "pdf-parser-eval-fake-raster-{x}.sh", .{std.testing.random_seed});
    runtime.deleteFileCwd(raster_path);
    defer runtime.deleteFileCwd(raster_path);
    const raster_file = try runtime.createFileCwd(raster_path);
    try runtime.writeAllFile(raster_file, fake_rasterizer);
    runtime.closeFile(raster_file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", raster_path }));
    var raster_exec_buf: [112]u8 = undefined;
    const raster_exec = try std.fmt.bufPrint(&raster_exec_buf, "./{s}", .{raster_path});

    const fake_tesseract =
        "#!/bin/sh\n" ++
        "printf '%s\\n' 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext'\n" ++
        "printf '%s\\n' '1\t1\t0\t0\t0\t0\t0\t0\t1000\t2000\t-1\t'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t1\t100\t200\t160\t40\t91\tScanned'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t2\t300\t200\t260\t40\t92\ttypewritten'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t3\t600\t200\t120\t40\t93\ttext'\n";
    var tess_buf: [96]u8 = undefined;
    const tess_path = try std.fmt.bufPrint(&tess_buf, "pdf-parser-eval-fake-tesseract-{x}.sh", .{std.testing.random_seed});
    runtime.deleteFileCwd(tess_path);
    defer runtime.deleteFileCwd(tess_path);
    const tess_file = try runtime.createFileCwd(tess_path);
    try runtime.writeAllFile(tess_file, fake_tesseract);
    runtime.closeFile(tess_file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", tess_path }));
    var tess_exec_buf: [112]u8 = undefined;
    const tess_exec = try std.fmt.bufPrint(&tess_exec_buf, "./{s}", .{tess_path});

    const jsonl = try evaluateOneToJsonl(allocator, .{
        .pdf_path = pdf_path,
        .truth_text_path = truth_path,
        .doc_id = "image-only-adaptive",
        .category = .scanned_typewritten,
        .extraction_mode = .adaptive,
        .ocr_config = .{
            .executable = tess_exec,
            .rasterizer_executable = raster_exec,
            .dpi = 300,
        },
    });
    defer allocator.free(jsonl);

    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"ocr_pages\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"native_text_ratio\":0.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"token_f1\":1.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"cer\":0.000000") != null);
}

test "eval runner parses manifest rows" {
    const entry = (try parseManifestLine(
        "scientific_math\tmath-notation\tcorpus/scientific_math/math-notation.pdf\ttruth/math-notation.txt\r",
    )).?;
    try std.testing.expectEqual(eval.CorpusCategory.scientific_math, entry.category);
    try std.testing.expectEqualStrings("math-notation", entry.doc_id);
    try std.testing.expectEqualStrings("corpus/scientific_math/math-notation.pdf", entry.pdf_path);
    try std.testing.expectEqualStrings("truth/math-notation.txt", entry.truth_text_path);
    try std.testing.expect(entry.truth_table_json_path == null);
    try std.testing.expect(entry.truth_reading_order_path == null);
    try std.testing.expect(entry.truth_formula_path == null);
    const table_entry = (try parseManifestLine(
        "financial_tables\taligned\tcorpus/aligned.pdf\ttruth/aligned.txt\ttruth/tables/aligned.json\ttruth/order/aligned.txt\ttruth/formulas/aligned.txt",
    )).?;
    try std.testing.expectEqualStrings("truth/tables/aligned.json", table_entry.truth_table_json_path.?);
    try std.testing.expectEqualStrings("truth/order/aligned.txt", table_entry.truth_reading_order_path.?);
    try std.testing.expectEqualStrings("truth/formulas/aligned.txt", table_entry.truth_formula_path.?);
    const formula_entry = (try parseManifestLine(
        "scientific_math\tmath\tcorpus/math.pdf\ttruth/math.txt\t\t\ttruth/formulas/math.txt",
    )).?;
    try std.testing.expect(formula_entry.truth_table_json_path == null);
    try std.testing.expect(formula_entry.truth_reading_order_path == null);
    try std.testing.expectEqualStrings("truth/formulas/math.txt", formula_entry.truth_formula_path.?);
    try std.testing.expect((try parseManifestLine("# comment")) == null);
}
