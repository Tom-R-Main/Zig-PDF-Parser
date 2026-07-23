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

pub const ExtractionMode = enum {
    native,
    adaptive,
};

pub const Options = struct {
    pdf_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    truth_text_path: ?[]const u8 = null,
    truth_table_json_path: ?[]const u8 = null,
    truth_reading_order_path: ?[]const u8 = null,
    truth_formula_path: ?[]const u8 = null,
    truth_formula_json_path: ?[]const u8 = null,
    truth_form_json_path: ?[]const u8 = null,
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
    expected_ocr_pages: ?u32 = null,
    expected_table_regions: ?u32 = null,
    expected_formula_regions: ?u32 = null,
    metadata_path: ?[]const u8 = null,
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

pub const ManifestEntry = struct {
    category: eval.CorpusCategory,
    doc_id: []const u8,
    pdf_path: []const u8,
    truth_text_path: []const u8,
    truth_table_json_path: ?[]const u8 = null,
    truth_reading_order_path: ?[]const u8 = null,
    truth_formula_path: ?[]const u8 = null,
    truth_formula_json_path: ?[]const u8 = null,
    truth_form_json_path: ?[]const u8 = null,
};

pub const ExpectedRouteCounts = struct {
    doc_id: []const u8,
    ocr_pages: ?u32 = null,
    table_regions: ?u32 = null,
    formula_regions: ?u32 = null,
};

pub fn runManifest(
    allocator: std.mem.Allocator,
    base_options: Options,
    manifest_path: []const u8,
) ![]u8 {
    const manifest = try runtime.readFileAllocAlignedCwd(allocator, manifest_path, .fromByteUnits(1));
    defer allocator.free(manifest);

    var metadata_bytes: ?[]align(1) u8 = null;
    defer if (metadata_bytes) |bytes| allocator.free(bytes);
    const metadata_path = base_options.metadata_path orelse try inferMetadataPath(allocator, manifest_path);
    defer if (base_options.metadata_path == null) allocator.free(metadata_path);
    metadata_bytes = runtime.readFileAllocAlignedCwd(allocator, metadata_path, .fromByteUnits(1)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const expected_counts = if (metadata_bytes) |bytes|
        try parseMetadataRouteCounts(allocator, bytes)
    else
        try allocator.alloc(ExpectedRouteCounts, 0);
    defer allocator.free(expected_counts);

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
        options.truth_formula_json_path = entry.truth_formula_json_path;
        options.truth_form_json_path = entry.truth_form_json_path;
        options.doc_id = entry.doc_id;
        options.category = entry.category;
        options.output_path = null;
        options.manifest_path = null;
        options.metadata_path = null;
        if (findExpectedRouteCounts(expected_counts, entry.doc_id)) |expected| {
            options.expected_ocr_pages = expected.ocr_pages;
            options.expected_table_regions = expected.table_regions;
            options.expected_formula_regions = expected.formula_regions;
        }

        const jsonl = try evaluateOneToJsonl(allocator, options);
        defer allocator.free(jsonl);
        try out.appendSlice(allocator, jsonl);
    }

    return out.toOwnedSlice(allocator);
}

pub fn inferMetadataPath(allocator: std.mem.Allocator, manifest_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(manifest_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/metadata.jsonl", .{dir});
}

pub fn parseMetadataRouteCounts(allocator: std.mem.Allocator, metadata: []const u8) ![]ExpectedRouteCounts {
    var counts: std.ArrayList(ExpectedRouteCounts) = .empty;
    errdefer counts.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, metadata, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        const doc_id = extractJsonStringValue(line, "\"doc_id\"") orelse return error.MalformedMetadata;
        try counts.append(allocator, .{
            .doc_id = doc_id,
            .ocr_pages = try extractJsonIntegerValue(line, "\"expected_ocr_pages\""),
            .table_regions = try extractJsonIntegerValue(line, "\"expected_table_regions\""),
            .formula_regions = try extractJsonIntegerValue(line, "\"expected_formula_regions\""),
        });
    }

    return counts.toOwnedSlice(allocator);
}

pub fn findExpectedRouteCounts(counts: []const ExpectedRouteCounts, doc_id: []const u8) ?ExpectedRouteCounts {
    for (counts) |entry| {
        if (std.mem.eql(u8, entry.doc_id, doc_id)) return entry;
    }
    return null;
}

pub fn parseManifestLine(raw_line: []const u8) !?ManifestEntry {
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
    const truth_formula_json_path = optionalManifestField(fields.next());
    const truth_form_json_path = optionalManifestField(fields.next());
    if (fields.next() != null) return error.MalformedManifest;

    return .{
        .category = eval.CorpusCategory.parse(category_text) orelse return error.UnknownCategory,
        .doc_id = doc_id,
        .pdf_path = pdf_path,
        .truth_text_path = truth_text_path,
        .truth_table_json_path = truth_table_json_path,
        .truth_reading_order_path = truth_reading_order_path,
        .truth_formula_path = truth_formula_path,
        .truth_formula_json_path = truth_formula_json_path,
        .truth_form_json_path = truth_form_json_path,
    };
}

fn optionalManifestField(field: ?[]const u8) ?[]const u8 {
    const value = field orelse return null;
    return if (value.len == 0) null else value;
}

fn docIdForMetrics(options: Options, pdf_path: []const u8) []const u8 {
    return options.doc_id orelse std.fs.path.basename(pdf_path);
}

pub fn evaluateOneToJsonl(allocator: std.mem.Allocator, options: Options) ![]u8 {
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
    var truth_formula_json: ?[]align(1) u8 = null;
    defer if (truth_formula_json) |json| allocator.free(json);
    if (options.truth_formula_json_path) |path| {
        truth_formula_json = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    }
    var truth_form_json: ?[]align(1) u8 = null;
    defer if (truth_form_json) |json| allocator.free(json);
    if (options.truth_form_json_path) |path| {
        truth_form_json = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
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
    var table_span_accuracy: ?f64 = null;
    var table_role_accuracy: ?f64 = null;
    var table_rowspan_accuracy: ?f64 = null;
    var table_colspan_accuracy: ?f64 = null;
    var table_page_accuracy: ?f64 = null;
    var table_continuation_accuracy: ?f64 = null;
    var table_source_span_coverage: ?f64 = null;
    var table_bbox_iou: ?f64 = null;
    var table_numeric_accuracy: ?f64 = null;
    var table_header_accuracy: ?f64 = null;
    var table_footnote_accuracy: ?f64 = null;
    if (truth_table_json) |truth_json| {
        const predicted_table_json = if (extraction.adaptive) |*adaptive_result|
            try renderAdaptiveTablesJson(allocator, adaptive_result.tables)
        else
            try renderDocumentTablesJson(allocator, doc);
        defer allocator.free(predicted_table_json);
        table_cell_accuracy = try evaluateTableCellAccuracy(allocator, predicted_table_json, truth_json);
        table_span_accuracy = try evaluateTableSpanAccuracy(allocator, predicted_table_json, truth_json);
        table_role_accuracy = try evaluateTableRoleAccuracy(allocator, predicted_table_json, truth_json);
        table_rowspan_accuracy = try evaluateTableIntegerFieldAccuracy(allocator, predicted_table_json, truth_json, "\"rowspan\"");
        table_colspan_accuracy = try evaluateTableIntegerFieldAccuracy(allocator, predicted_table_json, truth_json, "\"colspan\"");
        table_page_accuracy = try evaluateTableIntegerFieldAccuracy(allocator, predicted_table_json, truth_json, "\"page\"");
        table_continuation_accuracy = try evaluateTableContinuationAccuracy(allocator, predicted_table_json, truth_json);
        table_bbox_iou = try evaluateTableBBoxIou(allocator, predicted_table_json, truth_json);
        table_numeric_accuracy = try evaluateTableNumericAccuracy(allocator, predicted_table_json, truth_json);
        table_header_accuracy = try evaluateTableRoleTextAccuracy(allocator, predicted_table_json, truth_json, &.{"header"});
        table_footnote_accuracy = try evaluateTableRoleTextAccuracy(allocator, predicted_table_json, truth_json, &.{ "note", "footer" });
        if (extraction.adaptive) |*adaptive_result| {
            const artifact_json = try zpdf.schema.renderArtifactJson(allocator, adaptive_result, .{ .document_id = docIdForMetrics(options, pdf_path) });
            defer allocator.free(artifact_json);
            table_source_span_coverage = evaluateTableSourceSpanCoverage(artifact_json);
        }
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
    if (truth_formula_json) |truth_json| {
        const predicted_formula_json = try renderDocumentFormulaJson(allocator, doc);
        defer allocator.free(predicted_formula_json);
        formula_metrics.structure_accuracy = try evaluateFormulaStructureAccuracy(
            allocator,
            predicted_formula_json,
            truth_json,
        );
    }
    var form_metrics: eval.FormMetrics = .{};
    if (truth_form_json) |truth_json| {
        const predicted_form_json = try renderDocumentFormsJson(allocator, doc);
        defer allocator.free(predicted_form_json);
        form_metrics.field_accuracy = try evaluateFormFieldAccuracy(
            allocator,
            predicted_form_json,
            truth_json,
        );
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
    const counters = eval.ExtractionCounters{
        .native_pages = options.native_pages orelse extraction.counters.native_pages,
        .ocr_pages = options.ocr_pages orelse extraction.counters.ocr_pages,
        .table_regions = options.table_regions orelse extraction.counters.table_regions,
        .formula_regions = options.formula_regions orelse extraction.counters.formula_regions,
    };
    try validateExpectedRouteCounts(options, counters, doc_id);

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
            .span_accuracy = table_span_accuracy,
            .role_accuracy = table_role_accuracy,
            .rowspan_accuracy = table_rowspan_accuracy,
            .colspan_accuracy = table_colspan_accuracy,
            .page_accuracy = table_page_accuracy,
            .continuation_accuracy = table_continuation_accuracy,
            .source_span_coverage = table_source_span_coverage,
            .bbox_iou = table_bbox_iou,
            .numeric_accuracy = table_numeric_accuracy,
            .header_accuracy = table_header_accuracy,
            .footnote_accuracy = table_footnote_accuracy,
        },
        .formula = formula_metrics,
        .form = form_metrics,
        .latency = latency,
        .counters = counters,
    };

    return eval.resultToJsonl(allocator, result);
}

fn validateExpectedRouteCounts(options: Options, counters: eval.ExtractionCounters, doc_id: []const u8) !void {
    _ = doc_id;
    if (options.expected_ocr_pages) |expected| {
        if (counters.ocr_pages != expected) {
            return error.RouteCountMismatch;
        }
    }
    if (options.expected_table_regions) |expected| {
        if (counters.table_regions != expected) {
            return error.RouteCountMismatch;
        }
    }
    if (options.expected_formula_regions) |expected| {
        if (counters.formula_regions != expected) {
            return error.RouteCountMismatch;
        }
    }
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
            const text = try result.render(allocator, .text);
            errdefer allocator.free(text);
            return .{
                .text = text,
                .counters = try adaptiveCounters(allocator, &result, page_count),
                .adaptive = result,
            };
        },
    }
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

fn renderAdaptiveTablesJson(allocator: std.mem.Allocator, tables: []const layout.TableGrid) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('[');
    for (tables, 0..) |table, table_index| {
        if (table_index > 0) try writer.writeByte(',');
        const logical_index = table.logical_table_index orelse @as(u32, @intCast(table_index));
        try writer.print(
            "{{\"table_id\":\"table-{d}\",\"logical_table_id\":\"logical-table-{d}\",\"table_index\":{},\"table_part_index\":{},\"continued_from_table_id\":",
            .{ table_index, logical_index, table_index, table.table_part_index },
        );
        try writeOptionalTableId(writer, table.continued_from_table_index);
        try writer.writeAll(",\"continued_to_table_id\":");
        try writeOptionalTableId(writer, table.continued_to_table_index);
        try writer.print(
            ",\"page_index\":{},\"block_index\":{},\"block_count\":{},\"column_count\":{},\"confidence\":{d:.3},\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[],\"rows\":[",
            .{ table.page_index, table.block_index, table.block_count, table.column_count, table.confidence, table.bounds.x0, table.bounds.y0, table.bounds.x1, table.bounds.y1 },
        );
        for (table.rows, 0..) |row, row_index| {
            if (row_index > 0) try writer.writeByte(',');
            try writer.writeByte('[');
            var wrote_cell = false;
            for (row.cells) |cell| {
                if (cell.text.len == 0) continue;
                if (wrote_cell) try writer.writeByte(',');
                wrote_cell = true;
                try writer.print(
                    "{{\"cell_id\":\"table-{d}-cell-{d}-{d}\",\"page\":{},\"page_index\":{},\"row\":{},\"column\":{},\"rowspan\":{},\"colspan\":{},\"role\":\"{s}\",\"text\":\"",
                    .{ table_index, cell.row_index, cell.column_index, cell.bounds.page_index, cell.bounds.page_index, cell.row_index, cell.column_index, cell.rowspan, cell.colspan, tableCellRoleName(cell.role) },
                );
                try writeJsonEscaped(writer, cell.text);
                try writer.writeAll("\",\"raw_text\":\"");
                try writeJsonEscaped(writer, cell.text);
                try writer.writeAll("\",\"normalized_text\":\"");
                try writeNormalizedJsonEscaped(writer, cell.text);
                try writer.writeAll("\",\"numeric\":");
                try writeNumericHint(writer, cell.text);
                try writer.print(
                    ",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[]}}",
                    .{ cell.bounds.x0, cell.bounds.y0, cell.bounds.x1, cell.bounds.y1 },
                );
            }
            try writer.writeByte(']');
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');

    return out.toOwnedSlice(allocator);
}

fn tableCellRoleName(role: layout.TableCellRole) []const u8 {
    return switch (role) {
        .data => "data",
        .header => "header",
        .row_header => "row_header",
        .note => "note",
        .footer => "footer",
    };
}

fn writeOptionalTableId(writer: anytype, table_index: ?u32) !void {
    if (table_index) |index| {
        try writer.print("\"table-{d}\"", .{index});
    } else {
        try writer.writeAll("null");
    }
}

fn renderDocumentFormsJson(allocator: std.mem.Allocator, doc: *zpdf.Document) ![]u8 {
    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('[');
    var first = true;
    for (fields) |field| {
        const value = field.value orelse continue;
        if (field.name.len == 0 or value.len == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"name\":\"");
        try writeJsonEscaped(writer, field.name);
        try writer.writeAll("\",\"type\":\"");
        try writer.writeAll(formFieldTypeName(field.field_type));
        try writer.writeAll("\",\"value\":\"");
        try writeJsonEscaped(writer, value);
        try writer.writeAll("\"}");
    }
    try writer.writeByte(']');

    return out.toOwnedSlice(allocator);
}

fn formFieldTypeName(field_type: zpdf.Document.FieldType) []const u8 {
    return switch (field_type) {
        .text => "text",
        .button => "button",
        .choice => "choice",
        .signature => "signature",
        .unknown => "unknown",
    };
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

fn renderDocumentFormulaJson(allocator: std.mem.Allocator, doc: *zpdf.Document) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('[');
    var first = true;
    for (0..doc.pages.items.len) |page_index| {
        const page = doc.pages.items[page_index];
        const page_width = page.media_box[2] - page.media_box[0];
        const spans = try doc.extractTextWithBounds(page_index, allocator);
        defer zpdf.Document.freeTextSpans(allocator, spans);

        var page_layout = try layout.analyzeLayout(allocator, spans, page_width);
        defer page_layout.deinit();

        for (page_layout.blocks, 0..) |block, block_index| {
            if (block.kind != .formula_candidate) continue;
            if (!first) try writer.writeByte(',');
            first = false;

            const text = try blockTextToOwnedSlice(allocator, block);
            defer allocator.free(text);

            try writer.print("{{\"page\":{},\"block_index\":{},\"text\":\"", .{
                page_index,
                block_index,
            });
            try writeJsonEscaped(writer, text);
            try writer.print("\",\"bbox\":[{d:.3},{d:.3},{d:.3},{d:.3}],\"source\":\"native_pdf\",\"confidence\":{d:.3}}}", .{
                block.bounds.x0,
                block.bounds.y0,
                block.bounds.x1,
                block.bounds.y1,
                block.confidence,
            });
        }
    }
    try writer.writeByte(']');

    return out.toOwnedSlice(allocator);
}

fn blockTextToOwnedSlice(allocator: std.mem.Allocator, block: layout.LayoutBlock) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);
    try writeBlockText(writer, block);
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

fn evaluateTableSpanAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"rowspan\"") == null and
        std.mem.indexOf(u8, truth_json, "\"colspan\"") == null)
    {
        return null;
    }

    const predicted = try extractTableSpanValues(allocator, predicted_json);
    defer allocator.free(predicted);
    const truth = try extractTableSpanValues(allocator, truth_json);
    defer allocator.free(truth);

    if (truth.len == 0) return if (predicted.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (predicted[index] == truth[index]) matched += 1;
    }

    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn evaluateTableRoleAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"role\"") == null) return null;

    const predicted = try extractJsonStringValues(allocator, predicted_json, "\"role\"");
    defer freeStringList(allocator, predicted);
    const truth = try extractJsonStringValues(allocator, truth_json, "\"role\"");
    defer freeStringList(allocator, truth);

    if (truth.len == 0) return if (predicted.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (std.mem.eql(u8, predicted[index], truth[index])) matched += 1;
    }

    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn evaluateTableIntegerFieldAccuracy(
    allocator: std.mem.Allocator,
    predicted_json: []const u8,
    truth_json: []const u8,
    needle: []const u8,
) !?f64 {
    if (std.mem.indexOf(u8, truth_json, needle) == null) return null;

    var predicted_values: std.ArrayList(u32) = .empty;
    defer predicted_values.deinit(allocator);
    try appendJsonIntegerValues(allocator, &predicted_values, predicted_json, needle);

    var truth_values: std.ArrayList(u32) = .empty;
    defer truth_values.deinit(allocator);
    try appendJsonIntegerValues(allocator, &truth_values, truth_json, needle);

    if (truth_values.items.len == 0) return if (predicted_values.items.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    var matched: usize = 0;
    const compare_count = @min(predicted_values.items.len, truth_values.items.len);
    for (0..compare_count) |index| {
        if (predicted_values.items[index] == truth_values.items[index]) matched += 1;
    }

    const denominator = @max(predicted_values.items.len, truth_values.items.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn evaluateTableContinuationAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"continued_from_table_id\"") == null and
        std.mem.indexOf(u8, truth_json, "\"logical_table_id\"") == null)
    {
        return null;
    }

    const predicted = try extractContinuationValues(allocator, predicted_json);
    defer freeStringList(allocator, predicted);
    const truth = try extractContinuationValues(allocator, truth_json);
    defer freeStringList(allocator, truth);

    if (truth.len == 0) return if (predicted.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (std.mem.eql(u8, predicted[index], truth[index])) matched += 1;
    }
    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

const TableBBox = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

fn evaluateTableBBoxIou(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"bbox\"") == null) return null;
    const predicted = try extractBBoxes(allocator, predicted_json);
    defer allocator.free(predicted);
    const truth = try extractBBoxes(allocator, truth_json);
    defer allocator.free(truth);
    if (truth.len == 0) return if (predicted.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    const count = @min(predicted.len, truth.len);
    if (count == 0) return 0.0;
    var total: f64 = 0;
    for (0..count) |index| total += bboxIou(predicted[index], truth[index]);
    return total / @as(f64, @floatFromInt(@max(predicted.len, truth.len)));
}

fn evaluateTableNumericAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"numeric\"") == null) return null;
    const predicted = try extractNumericValues(allocator, predicted_json);
    defer allocator.free(predicted);
    const truth = try extractNumericValues(allocator, truth_json);
    defer allocator.free(truth);
    if (truth.len == 0) return if (predicted.len == 0) @as(f64, 1.0) else @as(f64, 0.0);

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (@abs(predicted[index] - truth[index]) <= 0.0001) matched += 1;
    }
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(@max(predicted.len, truth.len)));
}

fn evaluateTableRoleTextAccuracy(
    allocator: std.mem.Allocator,
    predicted_json: []const u8,
    truth_json: []const u8,
    roles: []const []const u8,
) !?f64 {
    if (std.mem.indexOf(u8, truth_json, "\"role\"") == null) return null;

    const predicted_texts = try extractTableCellTexts(allocator, predicted_json);
    defer freeStringList(allocator, predicted_texts);
    const predicted_roles = try extractJsonStringValues(allocator, predicted_json, "\"role\"");
    defer freeStringList(allocator, predicted_roles);
    const truth_texts = try extractTableCellTexts(allocator, truth_json);
    defer freeStringList(allocator, truth_texts);
    const truth_roles = try extractJsonStringValues(allocator, truth_json, "\"role\"");
    defer freeStringList(allocator, truth_roles);

    const truth_count = @min(truth_texts.len, truth_roles.len);
    var total: usize = 0;
    var matched: usize = 0;
    for (0..truth_count) |index| {
        if (!roleInSet(truth_roles[index], roles)) continue;
        total += 1;
        if (index >= predicted_texts.len or index >= predicted_roles.len) continue;
        if (!roleInSet(predicted_roles[index], roles)) continue;
        if (std.mem.eql(u8, predicted_texts[index], truth_texts[index])) matched += 1;
    }
    if (total == 0) return null;
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
}

fn roleInSet(role: []const u8, roles: []const []const u8) bool {
    for (roles) |candidate| {
        if (std.mem.eql(u8, role, candidate)) return true;
    }
    return false;
}

fn extractContinuationValues(allocator: std.mem.Allocator, json: []const u8) ![][]u8 {
    const logical = try extractJsonStringValues(allocator, json, "\"logical_table_id\"");
    errdefer freeStringList(allocator, logical);
    const continued = try extractJsonStringValues(allocator, json, "\"continued_from_table_id\"");
    errdefer freeStringList(allocator, continued);

    var values: std.ArrayList([]u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    for (logical) |value| try values.append(allocator, value);
    for (continued) |value| try values.append(allocator, value);
    allocator.free(logical);
    allocator.free(continued);
    return values.toOwnedSlice(allocator);
}

fn extractBBoxes(allocator: std.mem.Allocator, json: []const u8) ![]TableBBox {
    var boxes: std.ArrayList(TableBBox) = .empty;
    errdefer boxes.deinit(allocator);
    var pos: usize = 0;
    var object_depth: usize = 0;
    while (pos < json.len) {
        switch (json[pos]) {
            '{' => {
                object_depth += 1;
                pos += 1;
                continue;
            },
            '}' => {
                object_depth -|= 1;
                pos += 1;
                continue;
            },
            '"' => {},
            else => {
                pos += 1;
                continue;
            },
        }

        const key_start = pos;
        pos += 1;
        var escaped = false;
        while (pos < json.len) : (pos += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (json[pos] == '\\') {
                escaped = true;
                continue;
            }
            if (json[pos] == '"') break;
        }
        if (pos >= json.len) break;
        pos += 1;

        if (object_depth != 1 or !std.mem.eql(u8, json[key_start..pos], "\"bbox\"")) continue;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') continue;
        pos += 1;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos < json.len and json[pos] == '[') {
            if (parseBBoxArray(json, pos)) |parsed| {
                try boxes.append(allocator, parsed.box);
                pos = parsed.end;
                continue;
            }
        } else if (pos < json.len and json[pos] == '{') {
            if (parseBBoxObject(json, pos)) |parsed| {
                try boxes.append(allocator, parsed.box);
                pos = parsed.end;
                continue;
            }
        }
    }
    return boxes.toOwnedSlice(allocator);
}

const ParsedBBox = struct {
    box: TableBBox,
    end: usize,
};

fn parseBBoxArray(json: []const u8, start: usize) ?ParsedBBox {
    var pos = start + 1;
    var values: [4]f64 = undefined;
    for (0..4) |index| {
        skipJsonSpace(json, &pos);
        values[index] = parseJsonFloatAt(json, &pos) orelse return null;
        skipJsonSpace(json, &pos);
        if (index < 3) {
            if (pos >= json.len or json[pos] != ',') return null;
            pos += 1;
        }
    }
    skipJsonSpace(json, &pos);
    if (pos >= json.len or json[pos] != ']') return null;
    return .{ .box = .{ .x0 = values[0], .y0 = values[1], .x1 = values[2], .y1 = values[3] }, .end = pos + 1 };
}

fn parseBBoxObject(json: []const u8, start: usize) ?ParsedBBox {
    const end = std.mem.indexOfScalarPos(u8, json, start, '}') orelse return null;
    const object = json[start .. end + 1];
    return .{
        .box = .{
            .x0 = extractJsonFloatValue(object, "\"x0\"") orelse return null,
            .y0 = extractJsonFloatValue(object, "\"y0\"") orelse return null,
            .x1 = extractJsonFloatValue(object, "\"x1\"") orelse return null,
            .y1 = extractJsonFloatValue(object, "\"y1\"") orelse return null,
        },
        .end = end + 1,
    };
}

fn bboxIou(a: TableBBox, b: TableBBox) f64 {
    const ix0 = @max(a.x0, b.x0);
    const iy0 = @max(a.y0, b.y0);
    const ix1 = @min(a.x1, b.x1);
    const iy1 = @min(a.y1, b.y1);
    const intersection = @max(0.0, ix1 - ix0) * @max(0.0, iy1 - iy0);
    const union_area = bboxArea(a) + bboxArea(b) - intersection;
    if (union_area <= 0) return 0;
    return intersection / union_area;
}

fn bboxArea(box: TableBBox) f64 {
    return @max(0.0, box.x1 - box.x0) * @max(0.0, box.y1 - box.y0);
}

fn extractNumericValues(allocator: std.mem.Allocator, json: []const u8) ![]f64 {
    var values: std.ArrayList(f64) = .empty;
    errdefer values.deinit(allocator);
    var cursor: usize = 0;
    while (std.mem.indexOf(u8, json[cursor..], "\"numeric\"")) |relative_index| {
        const numeric_start = cursor + relative_index;
        const object_start = std.mem.indexOfScalarPos(u8, json, numeric_start, '{') orelse break;
        const object_end = std.mem.indexOfScalarPos(u8, json, object_start, '}') orelse break;
        const object = json[object_start .. object_end + 1];
        if (jsonBoolValue(object, "\"is_numeric\"") == true) {
            if (extractJsonFloatValue(object, "\"value\"")) |value| {
                try values.append(allocator, value);
            }
        }
        cursor = object_end + 1;
    }
    return values.toOwnedSlice(allocator);
}

fn evaluateTableSourceSpanCoverage(json: []const u8) ?f64 {
    if (std.mem.indexOf(u8, json, "\"source_span_ids\"") == null) return null;
    var cursor: usize = 0;
    var total: usize = 0;
    var non_empty: usize = 0;
    const needle = "\"source_span_ids\"";
    while (std.mem.indexOf(u8, json[cursor..], needle)) |relative_index| {
        var pos = cursor + relative_index + needle.len;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') {
            cursor = pos;
            continue;
        }
        pos += 1;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != '[') {
            cursor = pos;
            continue;
        }
        total += 1;
        pos += 1;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos < json.len and json[pos] != ']') non_empty += 1;
        cursor = pos;
    }
    if (total == 0) return null;
    return @as(f64, @floatFromInt(non_empty)) / @as(f64, @floatFromInt(total));
}

const FormSignature = struct {
    name: []u8,
    field_type: []u8,
    value: []u8,
};

fn evaluateFormFieldAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !f64 {
    const predicted = try extractFormSignatures(allocator, predicted_json);
    defer freeFormSignatures(allocator, predicted);
    const truth = try extractFormSignatures(allocator, truth_json);
    defer freeFormSignatures(allocator, truth);

    if (truth.len == 0) return if (predicted.len == 0) 1.0 else 0.0;

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (formSignaturesEqual(predicted[index], truth[index])) matched += 1;
    }

    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn extractFormSignatures(allocator: std.mem.Allocator, json: []const u8) ![]FormSignature {
    const names = try extractJsonStringValues(allocator, json, "\"name\"");
    errdefer freeStringList(allocator, names);
    const types = try extractJsonStringValues(allocator, json, "\"type\"");
    errdefer freeStringList(allocator, types);
    const values = try extractJsonStringValues(allocator, json, "\"value\"");
    errdefer freeStringList(allocator, values);

    const count = @min(names.len, @min(types.len, values.len));
    var signatures = try allocator.alloc(FormSignature, count);
    errdefer allocator.free(signatures);
    for (0..count) |index| {
        signatures[index] = .{
            .name = names[index],
            .field_type = types[index],
            .value = values[index],
        };
    }

    allocator.free(names);
    allocator.free(types);
    allocator.free(values);
    return signatures;
}

fn freeFormSignatures(allocator: std.mem.Allocator, signatures: []const FormSignature) void {
    for (signatures) |signature| {
        allocator.free(signature.name);
        allocator.free(signature.field_type);
        allocator.free(signature.value);
    }
    allocator.free(signatures);
}

fn formSignaturesEqual(a: FormSignature, b: FormSignature) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.field_type, b.field_type) and
        std.mem.eql(u8, a.value, b.value);
}

const FormulaSignature = struct {
    page: ?u32 = null,
    text: []u8,
};

fn evaluateFormulaStructureAccuracy(allocator: std.mem.Allocator, predicted_json: []const u8, truth_json: []const u8) !f64 {
    const predicted = try extractFormulaSignatures(allocator, predicted_json);
    defer freeFormulaSignatures(allocator, predicted);
    const truth = try extractFormulaSignatures(allocator, truth_json);
    defer freeFormulaSignatures(allocator, truth);

    if (truth.len == 0) return if (predicted.len == 0) 1.0 else 0.0;

    var matched: usize = 0;
    const compare_count = @min(predicted.len, truth.len);
    for (0..compare_count) |index| {
        if (formulaSignaturesEqual(predicted[index], truth[index])) matched += 1;
    }

    const denominator = @max(predicted.len, truth.len);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(denominator));
}

fn extractFormulaSignatures(allocator: std.mem.Allocator, json: []const u8) ![]FormulaSignature {
    const texts = try extractTableCellTexts(allocator, json);
    errdefer freeStringList(allocator, texts);

    var pages: std.ArrayList(u32) = .empty;
    defer pages.deinit(allocator);
    try appendJsonIntegerValues(allocator, &pages, json, "\"page\"");

    var signatures = try allocator.alloc(FormulaSignature, texts.len);
    errdefer allocator.free(signatures);
    for (texts, 0..) |text, index| {
        signatures[index] = .{
            .page = if (index < pages.items.len) pages.items[index] else null,
            .text = text,
        };
    }
    allocator.free(texts);

    return signatures;
}

fn freeFormulaSignatures(allocator: std.mem.Allocator, signatures: []const FormulaSignature) void {
    for (signatures) |signature| allocator.free(signature.text);
    allocator.free(signatures);
}

fn formulaSignaturesEqual(a: FormulaSignature, b: FormulaSignature) bool {
    if (!std.mem.eql(u8, a.text, b.text)) return false;
    if (b.page) |truth_page| {
        return a.page != null and a.page.? == truth_page;
    }
    return true;
}

fn extractTableSpanValues(allocator: std.mem.Allocator, json: []const u8) ![]u32 {
    var values: std.ArrayList(u32) = .empty;
    errdefer values.deinit(allocator);
    try appendJsonIntegerValues(allocator, &values, json, "\"rowspan\"");
    try appendJsonIntegerValues(allocator, &values, json, "\"colspan\"");
    return values.toOwnedSlice(allocator);
}

fn appendJsonIntegerValues(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(u32),
    json: []const u8,
    needle: []const u8,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOf(u8, json[cursor..], needle)) |relative_index| {
        var pos = cursor + relative_index + needle.len;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        if (pos >= json.len or json[pos] != ':') {
            cursor = pos;
            continue;
        }
        pos += 1;
        while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
        const start = pos;
        while (pos < json.len and std.ascii.isDigit(json[pos])) : (pos += 1) {}
        if (pos > start) {
            try values.append(allocator, try std.fmt.parseInt(u32, json[start..pos], 10));
        }
        cursor = pos;
    }
}

fn extractJsonIntegerValue(json: []const u8, needle: []const u8) !?u32 {
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = found + needle.len;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != ':') return error.MalformedMetadata;
    pos += 1;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    const start = pos;
    while (pos < json.len and std.ascii.isDigit(json[pos])) : (pos += 1) {}
    if (pos == start) return error.MalformedMetadata;
    return try std.fmt.parseInt(u32, json[start..pos], 10);
}

fn extractJsonStringValue(json: []const u8, needle: []const u8) ?[]const u8 {
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = found + needle.len;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != ':') return null;
    pos += 1;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '\\') {
            if (pos + 1 >= json.len) return null;
            pos += 1;
            continue;
        }
        if (json[pos] == '"') return json[start..pos];
    }
    return null;
}

fn extractTableCellTexts(allocator: std.mem.Allocator, json: []const u8) ![][]u8 {
    return extractJsonStringValues(allocator, json, "\"text\"");
}

fn extractJsonStringValues(allocator: std.mem.Allocator, json: []const u8, needle: []const u8) ![][]u8 {
    var cells: std.ArrayList([]u8) = .empty;
    errdefer {
        for (cells.items) |cell| allocator.free(cell);
        cells.deinit(allocator);
    }

    var cursor: usize = 0;
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

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
}

fn writeNormalizedJsonEscaped(writer: anytype, text: []const u8) !void {
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try writer.writeByte(' ');
                previous_space = true;
            }
        } else {
            try writeJsonEscapedByte(writer, byte);
            previous_space = false;
        }
    }
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\x08' => try writer.writeAll("\\b"),
        '\x0c' => try writer.writeAll("\\f"),
        else => {
            if (byte < 0x20) {
                try writer.print("\\u00{X:0>2}", .{byte});
            } else {
                try writer.writeByte(byte);
            }
        },
    }
}

fn writeNumericHint(writer: anytype, text: []const u8) !void {
    if (parseNumericCell(text)) |numeric| {
        try writer.print(
            "{{\"is_numeric\":true,\"value\":{d:.6},\"negative\":{},\"format\":\"{s}\"}}",
            .{ numeric.value, numeric.negative, numeric.format },
        );
    } else {
        try writer.writeAll("{\"is_numeric\":false,\"value\":null,\"negative\":false,\"format\":null}");
    }
}

const NumericCell = struct {
    value: f64,
    negative: bool,
    format: []const u8,
};

fn parseNumericCell(text: []const u8) ?NumericCell {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 96) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "N/M") or
        std.ascii.eqlIgnoreCase(trimmed, "NM") or
        std.mem.eql(u8, trimmed, "--") or
        std.mem.eql(u8, trimmed, "-") or
        std.mem.eql(u8, trimmed, "\xE2\x80\x94"))
    {
        return null;
    }

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var saw_digit = false;
    var negative = false;
    var paren_negative = false;
    var minus_negative = false;
    var percent = false;

    for (trimmed, 0..) |byte, index| {
        switch (byte) {
            '0'...'9' => {
                saw_digit = true;
                buf[len] = byte;
                len += 1;
            },
            '.' => {
                buf[len] = byte;
                len += 1;
            },
            ',', ' ', '\t', '$' => {},
            '%' => percent = true,
            '(' => {
                if (index != 0) return null;
                negative = true;
                paren_negative = true;
            },
            ')' => {
                var tail_index = index + 1;
                while (tail_index < trimmed.len and std.ascii.isWhitespace(trimmed[tail_index])) : (tail_index += 1) {}
                if (!paren_negative or tail_index != trimmed.len) return null;
            },
            '-' => {
                if (len != 0) return null;
                negative = true;
                minus_negative = true;
            },
            '+' => {
                if (len != 0) return null;
            },
            else => return null,
        }
        if (len >= buf.len) return null;
    }
    if (!saw_digit or len == 0) return null;
    const parsed = std.fmt.parseFloat(f64, buf[0..len]) catch return null;
    const value = if (percent) parsed / 100.0 else parsed;
    return .{
        .value = if (negative) -value else value,
        .negative = negative,
        .format = if (percent) "percent" else if (paren_negative) "parentheses" else if (minus_negative) "minus" else "plain",
    };
}

fn skipJsonSpace(json: []const u8, pos: *usize) void {
    while (pos.* < json.len and std.ascii.isWhitespace(json[pos.*])) : (pos.* += 1) {}
}

fn parseJsonFloatAt(json: []const u8, pos: *usize) ?f64 {
    const start = pos.*;
    if (pos.* < json.len and (json[pos.*] == '-' or json[pos.*] == '+')) pos.* += 1;
    var saw_digit = false;
    while (pos.* < json.len and std.ascii.isDigit(json[pos.*])) : (pos.* += 1) saw_digit = true;
    if (pos.* < json.len and json[pos.*] == '.') {
        pos.* += 1;
        while (pos.* < json.len and std.ascii.isDigit(json[pos.*])) : (pos.* += 1) saw_digit = true;
    }
    if (!saw_digit) {
        pos.* = start;
        return null;
    }
    if (pos.* < json.len and (json[pos.*] == 'e' or json[pos.*] == 'E')) {
        const exponent_start = pos.*;
        pos.* += 1;
        if (pos.* < json.len and (json[pos.*] == '-' or json[pos.*] == '+')) pos.* += 1;
        const digits_start = pos.*;
        while (pos.* < json.len and std.ascii.isDigit(json[pos.*])) : (pos.* += 1) {}
        if (pos.* == digits_start) pos.* = exponent_start;
    }
    return std.fmt.parseFloat(f64, json[start..pos.*]) catch null;
}

fn extractJsonFloatValue(json: []const u8, needle: []const u8) ?f64 {
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = found + needle.len;
    skipJsonSpace(json, &pos);
    if (pos >= json.len or json[pos] != ':') return null;
    pos += 1;
    skipJsonSpace(json, &pos);
    return parseJsonFloatAt(json, &pos);
}

fn jsonBoolValue(json: []const u8, needle: []const u8) ?bool {
    const found = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = found + needle.len;
    skipJsonSpace(json, &pos);
    if (pos >= json.len or json[pos] != ':') return null;
    pos += 1;
    skipJsonSpace(json, &pos);
    if (std.mem.startsWith(u8, json[pos..], "true")) return true;
    if (std.mem.startsWith(u8, json[pos..], "false")) return false;
    return null;
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
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.metadata_path = args[index];
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
        } else if (std.mem.eql(u8, arg, "--truth-formula-json")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_formula_json_path = args[index];
        } else if (std.mem.eql(u8, arg, "--truth-form-json")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.truth_form_json_path = args[index];
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
        } else if (std.mem.eql(u8, arg, "--ocr-color")) {
            options.ocr_config.rasterize_grayscale = false;
        } else if (std.mem.eql(u8, arg, "--ocr-grayscale")) {
            options.ocr_config.rasterize_grayscale = true;
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
        \\  --metadata FILE         JSONL manifest sidecar with expected route counts
        \\  --truth-text FILE       Plain-text ground truth for CER/WER/token metrics
        \\  --truth-table-json FILE Table JSON ground truth for cell text accuracy
        \\  --truth-reading-order FILE Reading-order text truth for local-alignment score
        \\  --truth-formula FILE    Formula text truth for formula BLEU/edit-distance
        \\  --truth-formula-json FILE Structured formula JSON truth for page/text accuracy
        \\  --truth-form-json FILE Structured value-bearing AcroForm field truth
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
        \\  --ocr-dpi N             Rasterization DPI for adaptive OCR (default: 200)
        \\  --ocr-color             Rasterize OCR pages as RGB instead of default grayscale
        \\  --ocr-grayscale         Rasterize OCR pages as grayscale (default)
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
        \\  scanned_typewritten, scanned_financial_forms, patents, financial_tables, legal_contracts,
        \\  manuals, forms, weird_fonts, visual_truth, financial_table_stress,
        \\  adversarial_corrupt
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
        "--truth-formula-json",
        "formula.json",
        "--truth-form-json",
        "forms.json",
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
        "--ocr-color",
        "--ocr-pages",
        "1",
    });
    try std.testing.expectEqualStrings("sample.pdf", options.pdf_path.?);
    try std.testing.expectEqualStrings("truth.txt", options.truth_text_path.?);
    try std.testing.expectEqualStrings("tables.json", options.truth_table_json_path.?);
    try std.testing.expectEqualStrings("reading.txt", options.truth_reading_order_path.?);
    try std.testing.expectEqualStrings("formula.txt", options.truth_formula_path.?);
    try std.testing.expectEqualStrings("formula.json", options.truth_formula_json_path.?);
    try std.testing.expectEqualStrings("forms.json", options.truth_form_json_path.?);
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
    try std.testing.expect(!options.ocr_config.rasterize_grayscale);
    try std.testing.expectEqual(@as(u32, 1), options.ocr_pages.?);
}

test "eval runner parses manifest option" {
    const options = try parseArgs(&.{
        "--manifest",
        "benchmark/eval/corpus/manifest.tsv",
        "--metadata",
        "benchmark/eval/corpus/metadata.jsonl",
        "--parser",
        "candidate",
    });
    try std.testing.expectEqualStrings("benchmark/eval/corpus/manifest.tsv", options.manifest_path.?);
    try std.testing.expectEqualStrings("benchmark/eval/corpus/metadata.jsonl", options.metadata_path.?);
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
    const test_nonce = runtime.nanoTimestamp();

    var pdf_buf: [96]u8 = undefined;
    const pdf_path = try std.fmt.bufPrint(&pdf_buf, "pdf-parser-eval-ocr-{x}-{d}.pdf", .{ std.testing.random_seed, test_nonce });
    runtime.deleteFileCwd(pdf_path);
    defer runtime.deleteFileCwd(pdf_path);
    const pdf_file = try runtime.createFileCwd(pdf_path);
    try runtime.writeAllFile(pdf_file, pdf_data);
    runtime.closeFile(pdf_file);

    var truth_buf: [96]u8 = undefined;
    const truth_path = try std.fmt.bufPrint(&truth_buf, "pdf-parser-eval-ocr-truth-{x}-{d}.txt", .{ std.testing.random_seed, test_nonce });
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
    const raster_path = try std.fmt.bufPrint(&raster_buf, "pdf-parser-eval-fake-raster-{x}-{d}.sh", .{ std.testing.random_seed, test_nonce });
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
    const tess_path = try std.fmt.bufPrint(&tess_buf, "pdf-parser-eval-fake-tesseract-{x}-{d}.sh", .{ std.testing.random_seed, test_nonce });
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
    try std.testing.expect(entry.truth_formula_json_path == null);
    try std.testing.expect(entry.truth_form_json_path == null);
    const table_entry = (try parseManifestLine(
        "financial_tables\taligned\tcorpus/aligned.pdf\ttruth/aligned.txt\ttruth/tables/aligned.json\ttruth/order/aligned.txt\ttruth/formulas/aligned.txt\ttruth/formulas_json/aligned.json\ttruth/forms/aligned.json",
    )).?;
    try std.testing.expectEqualStrings("truth/tables/aligned.json", table_entry.truth_table_json_path.?);
    try std.testing.expectEqualStrings("truth/order/aligned.txt", table_entry.truth_reading_order_path.?);
    try std.testing.expectEqualStrings("truth/formulas/aligned.txt", table_entry.truth_formula_path.?);
    try std.testing.expectEqualStrings("truth/formulas_json/aligned.json", table_entry.truth_formula_json_path.?);
    try std.testing.expectEqualStrings("truth/forms/aligned.json", table_entry.truth_form_json_path.?);
    const formula_entry = (try parseManifestLine(
        "scientific_math\tmath\tcorpus/math.pdf\ttruth/math.txt\t\t\ttruth/formulas/math.txt\ttruth/formulas_json/math.json",
    )).?;
    try std.testing.expect(formula_entry.truth_table_json_path == null);
    try std.testing.expect(formula_entry.truth_reading_order_path == null);
    try std.testing.expectEqualStrings("truth/formulas/math.txt", formula_entry.truth_formula_path.?);
    try std.testing.expectEqualStrings("truth/formulas_json/math.json", formula_entry.truth_formula_json_path.?);
    try std.testing.expect((try parseManifestLine("# comment")) == null);
}

test "form field accuracy compares name type and value sequence" {
    const predicted =
        \\[
        \\  {"name":"consent.agree","type":"button","value":"Yes"},
        \\  {"name":"profile.phone","type":"text","value":"555-9999"}
        \\]
    ;
    const truth =
        \\[
        \\  {"name":"consent.agree","type":"button","value":"Yes"},
        \\  {"name":"profile.phone","type":"text","value":"555-0100"}
        \\]
    ;
    const accuracy = try evaluateFormFieldAccuracy(std.testing.allocator, predicted, truth);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), accuracy, 0.0001);
}

test "table role accuracy compares role sequence when truth has roles" {
    const predicted =
        \\[
        \\  {"text":"Account","role":"header"},
        \\  {"text":"Cash","role":"row_header"},
        \\  {"text":"1,000","role":"data"}
        \\]
    ;
    const truth =
        \\[
        \\  {"text":"Account","role":"header"},
        \\  {"text":"Cash","role":"row_header"},
        \\  {"text":"1,000","role":"note"}
        \\]
    ;
    const accuracy = try evaluateTableRoleAccuracy(std.testing.allocator, predicted, truth);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), accuracy.?, 0.0001);
    try std.testing.expect((try evaluateTableRoleAccuracy(std.testing.allocator, predicted, "[{\"text\":\"Account\"}]")) == null);
}

test "table bbox metric compares array and object boxes" {
    const predicted =
        \\[
        \\  {"bbox":[0,0,10,10],"rows":[[{"bbox":[50,50,60,60]}]]},
        \\  {"bbox":{"x0":10,"y0":0,"x1":20,"y1":10},"rows":[[{"bbox":[70,70,80,80]}]]}
        \\]
    ;
    const truth =
        \\[
        \\  {"bbox":[0,0,10,10],"rows":[[{"bbox":[0,0,1,1]}]]},
        \\  {"bbox":{"x0":15,"y0":0,"x1":25,"y1":10},"rows":[[{"bbox":[2,2,3,3]}]]}
        \\]
    ;

    const score = try evaluateTableBBoxIou(std.testing.allocator, predicted, truth);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), score.?, 0.0001);
    try std.testing.expect((try evaluateTableBBoxIou(std.testing.allocator, predicted, "[{\"text\":\"Account\"}]")) == null);
}

test "table numeric accuracy compares accounting numeric hints" {
    const predicted =
        \\[
        \\  {"numeric":{"is_numeric":true,"value":1200.0}},
        \\  {"numeric":{"is_numeric":true,"value":-950.0}},
        \\  {"numeric":{"is_numeric":false,"value":null}}
        \\]
    ;
    const truth =
        \\[
        \\  {"numeric":{"is_numeric":true,"value":1200.0}},
        \\  {"numeric":{"is_numeric":true,"value":-950.0}},
        \\  {"numeric":{"is_numeric":true,"value":0.0}}
        \\]
    ;

    const score = try evaluateTableNumericAccuracy(std.testing.allocator, predicted, truth);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), score.?, 0.0001);
    try std.testing.expect(parseNumericCell("$1,200.50").?.value == 1200.5);
    try std.testing.expect(parseNumericCell("(950)").?.value == -950.0);
    try std.testing.expect(parseNumericCell("-12%").?.value == -0.12);
    try std.testing.expect(parseNumericCell("--") == null);
    try std.testing.expect(parseNumericCell("N/M") == null);
}

test "table header and footnote accuracy use role-filtered text" {
    const predicted =
        \\[
        \\  {"text":"Account","role":"header"},
        \\  {"text":"Amount","role":"header"},
        \\  {"text":"Cash","role":"row_header"},
        \\  {"text":"* excludes transfers","role":"note"}
        \\]
    ;
    const truth =
        \\[
        \\  {"text":"Account","role":"header"},
        \\  {"text":"Amount","role":"header"},
        \\  {"text":"Cash","role":"row_header"},
        \\  {"text":"* excludes fees","role":"note"}
        \\]
    ;

    const header = try evaluateTableRoleTextAccuracy(std.testing.allocator, predicted, truth, &.{"header"});
    const footnote = try evaluateTableRoleTextAccuracy(std.testing.allocator, predicted, truth, &.{ "note", "footer" });

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), header.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), footnote.?, 0.0001);
}

test "formula structure accuracy compares page and text sequence" {
    const predicted =
        \\[
        \\  {"page":0,"text":"E=mc^2++++////^^^^____","bbox":[1,2,3,4]},
        \\  {"page":0,"text":"alpha+beta/gamma====","bbox":[1,5,3,7]}
        \\]
    ;
    const truth =
        \\[
        \\  {"page":0,"text":"E=mc^2++++////^^^^____"},
        \\  {"page":1,"text":"alpha+beta/gamma===="}
        \\]
    ;
    const accuracy = try evaluateFormulaStructureAccuracy(std.testing.allocator, predicted, truth);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), accuracy, 0.0001);
}

test "eval runner parses metadata route expectations" {
    const metadata =
        \\{"category":"financial_tables","doc_id":"rowspan-financials","expected_ocr_pages":0,"expected_table_regions":3,"expected_formula_regions":0}
        \\{"category":"scientific_math","doc_id":"math-notation","expected_ocr_pages":0,"expected_table_regions":0,"expected_formula_regions":3}
        \\
    ;
    const counts = try parseMetadataRouteCounts(std.testing.allocator, metadata);
    defer std.testing.allocator.free(counts);

    try std.testing.expectEqual(@as(usize, 2), counts.len);
    try std.testing.expectEqualStrings("rowspan-financials", counts[0].doc_id);
    try std.testing.expectEqual(@as(u32, 3), counts[0].table_regions.?);
    try std.testing.expectEqual(@as(u32, 3), counts[1].formula_regions.?);
    try std.testing.expect(findExpectedRouteCounts(counts, "missing") == null);
}

test "eval runner validates expected route counters" {
    try validateExpectedRouteCounts(.{
        .expected_ocr_pages = 1,
        .expected_table_regions = 2,
        .expected_formula_regions = 0,
    }, .{
        .ocr_pages = 1,
        .table_regions = 2,
        .formula_regions = 0,
    }, "doc");

    try std.testing.expectError(error.RouteCountMismatch, validateExpectedRouteCounts(.{
        .expected_table_regions = 1,
    }, .{
        .table_regions = 2,
    }, "doc"));
}
