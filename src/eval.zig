//! First-class evaluation schemas and metrics for parser quality.
//!
//! The harness is deliberately parser-agnostic: callers provide extracted text,
//! optional task scores, timings, and provenance counts, and this module emits a
//! stable per-document result suitable for JSONL dashboards and regression runs.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");

pub const CorpusCategory = enum {
    clean_born_digital,
    academic_two_column,
    scientific_math,
    scanned_typewritten,
    patents,
    financial_tables,
    legal_contracts,
    manuals,
    forms,
    weird_fonts,
    adversarial_corrupt,

    pub fn parse(text: []const u8) ?CorpusCategory {
        return std.meta.stringToEnum(CorpusCategory, text);
    }
};

pub const corpus_categories = [_]CorpusCategory{
    .clean_born_digital,
    .academic_two_column,
    .scientific_math,
    .scanned_typewritten,
    .patents,
    .financial_tables,
    .legal_contracts,
    .manuals,
    .forms,
    .weird_fonts,
    .adversarial_corrupt,
};

pub const TextMetrics = struct {
    cer: ?f64 = null,
    wer: ?f64 = null,
    token_precision: ?f64 = null,
    token_recall: ?f64 = null,
    token_f1: ?f64 = null,
    normalized_edit_distance: ?f64 = null,
    bleu4: ?f64 = null,
    local_alignment: ?f64 = null,
};

pub const DetectionMetrics = struct {
    precision: ?f64 = null,
    recall: ?f64 = null,
    f1: ?f64 = null,
};

pub const TableMetrics = struct {
    detection: DetectionMetrics = .{},
    teds: ?f64 = null,
    grits: ?f64 = null,
    cell_accuracy: ?f64 = null,
    span_accuracy: ?f64 = null,
    role_accuracy: ?f64 = null,
    rowspan_accuracy: ?f64 = null,
    colspan_accuracy: ?f64 = null,
    page_accuracy: ?f64 = null,
    continuation_accuracy: ?f64 = null,
    source_span_coverage: ?f64 = null,
};

pub const FormulaMetrics = struct {
    bleu: ?f64 = null,
    edit_distance: ?f64 = null,
    cdm: ?f64 = null,
    structure_accuracy: ?f64 = null,
};

pub const FormMetrics = struct {
    field_accuracy: ?f64 = null,
};

pub const LatencyMetrics = struct {
    total_ms: ?f64 = null,
    median_ms_per_page: ?f64 = null,
    p95_ms_per_page: ?f64 = null,
    peak_rss_mb: ?f64 = null,
};

pub const ExtractionCounters = struct {
    native_pages: u32 = 0,
    ocr_pages: u32 = 0,
    table_regions: u32 = 0,
    formula_regions: u32 = 0,

    pub fn nativeTextRatio(self: ExtractionCounters, pages: u32) ?f64 {
        if (pages == 0) return null;
        return @as(f64, @floatFromInt(self.native_pages)) / @as(f64, @floatFromInt(pages));
    }
};

pub const DocumentResult = struct {
    doc_id: []const u8,
    parser: []const u8 = "pdf-parser",
    category: CorpusCategory,
    pages: u32 = 0,
    text: TextMetrics = .{},
    reading_order_score: ?f64 = null,
    table: TableMetrics = .{},
    formula: FormulaMetrics = .{},
    form: FormMetrics = .{},
    latency: LatencyMetrics = .{},
    counters: ExtractionCounters = .{},
};

pub const TextEvaluation = struct {
    prediction: []const u8,
    ground_truth: []const u8,
};

pub const DetectionCounts = struct {
    true_positive: u32 = 0,
    false_positive: u32 = 0,
    false_negative: u32 = 0,
};

pub fn evaluateText(allocator: std.mem.Allocator, input: TextEvaluation) !TextMetrics {
    const predicted = try normalizeWhitespace(allocator, input.prediction);
    defer allocator.free(predicted);
    const expected = try normalizeWhitespace(allocator, input.ground_truth);
    defer allocator.free(expected);

    const predicted_tokens = try tokenize(allocator, predicted);
    defer allocator.free(predicted_tokens);
    const expected_tokens = try tokenize(allocator, expected);
    defer allocator.free(expected_tokens);

    const char_edits = try editDistanceBytes(allocator, predicted, expected);
    const word_edits = try editDistanceTokens(allocator, predicted_tokens, expected_tokens);
    const token_counts = try tokenF1(allocator, predicted_tokens, expected_tokens);

    return .{
        .cer = normalizedBy(char_edits, expected.len),
        .wer = normalizedBy(word_edits, expected_tokens.len),
        .token_precision = token_counts.precision,
        .token_recall = token_counts.recall,
        .token_f1 = token_counts.f1,
        .normalized_edit_distance = normalizedBy(
            char_edits,
            @max(predicted.len, expected.len),
        ),
        .bleu4 = bleu4(predicted_tokens, expected_tokens),
        .local_alignment = try lcsAlignment(allocator, predicted_tokens, expected_tokens),
    };
}

pub fn scoreDetection(counts: DetectionCounts) DetectionMetrics {
    const tp: f64 = @floatFromInt(counts.true_positive);
    const fp: f64 = @floatFromInt(counts.false_positive);
    const fn_count: f64 = @floatFromInt(counts.false_negative);
    const precision = if (tp + fp == 0) null else tp / (tp + fp);
    const recall = if (tp + fn_count == 0) null else tp / (tp + fn_count);
    return .{
        .precision = precision,
        .recall = recall,
        .f1 = fScore(precision, recall),
    };
}

pub fn readingOrderScore(
    allocator: std.mem.Allocator,
    predicted_order: []const u32,
    expected_order: []const u32,
) !?f64 {
    if (expected_order.len == 0) return if (predicted_order.len == 0) 1.0 else null;
    const lcs = try lcsU32(allocator, predicted_order, expected_order);
    return @as(f64, @floatFromInt(lcs)) / @as(f64, @floatFromInt(expected_order.len));
}

pub fn latencyFromSamples(
    allocator: std.mem.Allocator,
    page_count: u32,
    samples_ns: []const i128,
    peak_rss_mb: ?f64,
) !LatencyMetrics {
    if (samples_ns.len == 0) return .{ .peak_rss_mb = peak_rss_mb };

    const samples = try allocator.dupe(i128, samples_ns);
    defer allocator.free(samples);
    std.mem.sort(i128, samples, {}, comptime std.sort.asc(i128));

    var total_ns: i128 = 0;
    for (samples) |sample| total_ns += sample;

    const median = samples[samples.len / 2];
    const p95_index = @min(samples.len - 1, (samples.len * 95 + 99) / 100 - 1);
    const pages = @max(page_count, 1);
    const pages_f: f64 = @floatFromInt(pages);

    return .{
        .total_ms = nsToMs(total_ns),
        .median_ms_per_page = nsToMs(median) / pages_f,
        .p95_ms_per_page = nsToMs(samples[p95_index]) / pages_f,
        .peak_rss_mb = peak_rss_mb,
    };
}

pub fn currentPeakRssMb() ?f64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const usage = std.posix.getrusage(std.posix.rusage.SELF);
            break :blk @as(f64, @floatFromInt(usage.maxrss)) / 1024.0;
        },
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        => blk: {
            const usage = std.posix.getrusage(std.posix.rusage.SELF);
            break :blk @as(f64, @floatFromInt(usage.maxrss)) / (1024.0 * 1024.0);
        },
        else => null,
    };
}

pub fn writeJsonlResult(writer: anytype, result: DocumentResult) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"doc_id\":\"");
    try writeJsonEscaped(writer, result.doc_id);
    try writer.writeAll("\",\"parser\":\"");
    try writeJsonEscaped(writer, result.parser);
    try writer.print("\",\"category\":\"{s}\",\"pages\":{}", .{ @tagName(result.category), result.pages });
    try writer.writeAll(",\"native_text_ratio\":");
    try writeOptionalFloat(writer, result.counters.nativeTextRatio(result.pages));
    try writer.print(",\"ocr_pages\":{}", .{result.counters.ocr_pages});
    try writer.print(",\"table_regions\":{}", .{result.counters.table_regions});
    try writer.print(",\"formula_regions\":{}", .{result.counters.formula_regions});

    try writer.writeAll(",\"metrics\":{");
    try writer.writeAll("\"token_precision\":");
    try writeOptionalFloat(writer, result.text.token_precision);
    try writer.writeAll(",\"token_recall\":");
    try writeOptionalFloat(writer, result.text.token_recall);
    try writer.writeAll(",\"token_f1\":");
    try writeOptionalFloat(writer, result.text.token_f1);
    try writer.writeAll(",\"cer\":");
    try writeOptionalFloat(writer, result.text.cer);
    try writer.writeAll(",\"wer\":");
    try writeOptionalFloat(writer, result.text.wer);
    try writer.writeAll(",\"normalized_edit_distance\":");
    try writeOptionalFloat(writer, result.text.normalized_edit_distance);
    try writer.writeAll(",\"bleu4\":");
    try writeOptionalFloat(writer, result.text.bleu4);
    try writer.writeAll(",\"local_alignment\":");
    try writeOptionalFloat(writer, result.text.local_alignment);
    try writer.writeAll(",\"reading_order_score\":");
    try writeOptionalFloat(writer, result.reading_order_score);
    try writer.writeAll(",\"table_f1\":");
    try writeOptionalFloat(writer, result.table.detection.f1);
    try writer.writeAll(",\"teds\":");
    try writeOptionalFloat(writer, result.table.teds);
    try writer.writeAll(",\"grits\":");
    try writeOptionalFloat(writer, result.table.grits);
    try writer.writeAll(",\"table_cell_accuracy\":");
    try writeOptionalFloat(writer, result.table.cell_accuracy);
    try writer.writeAll(",\"table_span_accuracy\":");
    try writeOptionalFloat(writer, result.table.span_accuracy);
    try writer.writeAll(",\"table_role_accuracy\":");
    try writeOptionalFloat(writer, result.table.role_accuracy);
    try writer.writeAll(",\"table_rowspan_accuracy\":");
    try writeOptionalFloat(writer, result.table.rowspan_accuracy);
    try writer.writeAll(",\"table_colspan_accuracy\":");
    try writeOptionalFloat(writer, result.table.colspan_accuracy);
    try writer.writeAll(",\"table_page_accuracy\":");
    try writeOptionalFloat(writer, result.table.page_accuracy);
    try writer.writeAll(",\"table_continuation_accuracy\":");
    try writeOptionalFloat(writer, result.table.continuation_accuracy);
    try writer.writeAll(",\"table_source_span_coverage\":");
    try writeOptionalFloat(writer, result.table.source_span_coverage);
    try writer.writeAll(",\"formula_bleu\":");
    try writeOptionalFloat(writer, result.formula.bleu);
    try writer.writeAll(",\"formula_edit_distance\":");
    try writeOptionalFloat(writer, result.formula.edit_distance);
    try writer.writeAll(",\"formula_cdm\":");
    try writeOptionalFloat(writer, result.formula.cdm);
    try writer.writeAll(",\"formula_structure_accuracy\":");
    try writeOptionalFloat(writer, result.formula.structure_accuracy);
    try writer.writeAll(",\"form_field_accuracy\":");
    try writeOptionalFloat(writer, result.form.field_accuracy);
    try writer.writeAll(",\"median_ms_per_page\":");
    try writeOptionalFloat(writer, result.latency.median_ms_per_page);
    try writer.writeAll(",\"p95_ms_per_page\":");
    try writeOptionalFloat(writer, result.latency.p95_ms_per_page);
    try writer.writeAll(",\"peak_rss_mb\":");
    try writeOptionalFloat(writer, result.latency.peak_rss_mb);
    try writer.writeAll("}}\n");
}

pub fn resultToJsonl(allocator: std.mem.Allocator, result: DocumentResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);
    try writeJsonlResult(writer, result);
    return out.toOwnedSlice(allocator);
}

fn normalizeWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try out.append(allocator, ' ');
                previous_space = true;
            }
        } else {
            try out.append(allocator, byte);
            previous_space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }
    return out.toOwnedSlice(allocator);
}

fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |token| try tokens.append(allocator, token);
    return tokens.toOwnedSlice(allocator);
}

fn normalizedBy(edits: usize, denominator: usize) ?f64 {
    if (denominator == 0) return if (edits == 0) 0.0 else null;
    return @as(f64, @floatFromInt(edits)) / @as(f64, @floatFromInt(denominator));
}

fn editDistanceBytes(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    var prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    var curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);

    for (prev, 0..) |*value, i| value.* = i;
    for (a, 0..) |a_byte, ai| {
        curr[0] = ai + 1;
        for (b, 0..) |b_byte, bi| {
            const substitution = prev[bi] + @intFromBool(a_byte != b_byte);
            curr[bi + 1] = @min(@min(prev[bi + 1] + 1, curr[bi] + 1), substitution);
        }
        std.mem.swap([]usize, &prev, &curr);
    }
    return prev[b.len];
}

fn editDistanceTokens(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) !usize {
    var prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    var curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);

    for (prev, 0..) |*value, i| value.* = i;
    for (a, 0..) |a_token, ai| {
        curr[0] = ai + 1;
        for (b, 0..) |b_token, bi| {
            const substitution = prev[bi] + @intFromBool(!std.mem.eql(u8, a_token, b_token));
            curr[bi + 1] = @min(@min(prev[bi + 1] + 1, curr[bi] + 1), substitution);
        }
        std.mem.swap([]usize, &prev, &curr);
    }
    return prev[b.len];
}

fn tokenF1(
    allocator: std.mem.Allocator,
    predicted: []const []const u8,
    expected: []const []const u8,
) !DetectionMetrics {
    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();

    for (expected) |token| {
        const entry = try counts.getOrPut(token);
        if (entry.found_existing) {
            entry.value_ptr.* += 1;
        } else {
            entry.value_ptr.* = 1;
        }
    }

    var true_positive: u32 = 0;
    var false_positive: u32 = 0;
    for (predicted) |token| {
        if (counts.getPtr(token)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                true_positive += 1;
            } else {
                false_positive += 1;
            }
        } else {
            false_positive += 1;
        }
    }

    var false_negative: u32 = 0;
    var it = counts.iterator();
    while (it.next()) |entry| false_negative += @intCast(entry.value_ptr.*);

    return scoreDetection(.{
        .true_positive = true_positive,
        .false_positive = false_positive,
        .false_negative = false_negative,
    });
}

fn fScore(precision: ?f64, recall: ?f64) ?f64 {
    const p = precision orelse return null;
    const r = recall orelse return null;
    if (p + r == 0) return 0.0;
    return 2.0 * p * r / (p + r);
}

fn bleu4(predicted: []const []const u8, expected: []const []const u8) ?f64 {
    if (predicted.len == 0 or expected.len == 0) return null;
    const max_order = @min(@as(usize, 4), @min(predicted.len, expected.len));
    var product: f64 = 1.0;
    for (1..max_order + 1) |n| {
        const precision = ngramPrecision(predicted, expected, n);
        if (precision == 0) return 0.0;
        product *= precision;
    }
    const brevity_penalty = if (predicted.len >= expected.len)
        1.0
    else
        @exp(1.0 - @as(f64, @floatFromInt(expected.len)) / @as(f64, @floatFromInt(predicted.len)));
    return brevity_penalty * std.math.pow(f64, product, 1.0 / @as(f64, @floatFromInt(max_order)));
}

fn ngramPrecision(predicted: []const []const u8, expected: []const []const u8, n: usize) f64 {
    if (predicted.len < n) return 0.0;
    const total = predicted.len - n + 1;
    var matched: usize = 0;
    for (0..total) |pred_index| {
        if (containsNgram(expected, predicted[pred_index..][0..n])) matched += 1;
    }
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
}

fn containsNgram(haystack: []const []const u8, needle: []const []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |index| {
        var equal = true;
        for (needle, 0..) |token, offset| {
            if (!std.mem.eql(u8, token, haystack[index + offset])) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn lcsAlignment(
    allocator: std.mem.Allocator,
    predicted: []const []const u8,
    expected: []const []const u8,
) !?f64 {
    if (predicted.len == 0 and expected.len == 0) return 1.0;
    if (predicted.len == 0 or expected.len == 0) return 0.0;
    const lcs = try lcsTokens(allocator, predicted, expected);
    return (2.0 * @as(f64, @floatFromInt(lcs))) /
        @as(f64, @floatFromInt(predicted.len + expected.len));
}

fn lcsTokens(
    allocator: std.mem.Allocator,
    a: []const []const u8,
    b: []const []const u8,
) !usize {
    var prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    var curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);
    @memset(prev, 0);
    @memset(curr, 0);

    for (a) |a_item| {
        for (b, 0..) |b_item, bi| {
            curr[bi + 1] = if (std.mem.eql(u8, a_item, b_item))
                prev[bi] + 1
            else
                @max(prev[bi + 1], curr[bi]);
        }
        std.mem.swap([]usize, &prev, &curr);
        @memset(curr, 0);
    }
    return prev[b.len];
}

fn lcsU32(allocator: std.mem.Allocator, a: []const u32, b: []const u32) !usize {
    var prev = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(prev);
    var curr = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(curr);
    @memset(prev, 0);
    @memset(curr, 0);

    for (a) |a_item| {
        for (b, 0..) |b_item, bi| {
            curr[bi + 1] = if (a_item == b_item)
                prev[bi] + 1
            else
                @max(prev[bi + 1], curr[bi]);
        }
        std.mem.swap([]usize, &prev, &curr);
        @memset(curr, 0);
    }
    return prev[b.len];
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn writeOptionalFloat(writer: anytype, value: ?f64) !void {
    if (value) |v| {
        try writer.print("{d:.6}", .{v});
    } else {
        try writer.writeAll("null");
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

test "corpus categories include requested benchmark classes" {
    try std.testing.expectEqual(@as(usize, 11), corpus_categories.len);
    try std.testing.expectEqual(CorpusCategory.scientific_math, CorpusCategory.parse("scientific_math").?);
    try std.testing.expectEqual(CorpusCategory.adversarial_corrupt, corpus_categories[10]);
}

test "text metrics track character word token and order quality" {
    const metrics = try evaluateText(std.testing.allocator, .{
        .prediction = "Hello brave world",
        .ground_truth = "Hello world",
    });
    try std.testing.expect(metrics.cer.? > 0);
    try std.testing.expect(metrics.wer.? > 0);
    try std.testing.expect(metrics.token_precision.? < 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), metrics.token_recall.?, 0.0001);
    try std.testing.expect(metrics.token_f1.? > 0.79);
    try std.testing.expect(metrics.local_alignment.? > 0.79);
}

test "bleu uses available ngram orders for short exact text" {
    const metrics = try evaluateText(std.testing.allocator, .{
        .prediction = "short exact",
        .ground_truth = "short exact",
    });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), metrics.bleu4.?, 0.0001);
}

test "reading order uses expected-order lcs ratio" {
    const score = try readingOrderScore(
        std.testing.allocator,
        &.{ 1, 3, 2, 4 },
        &.{ 1, 2, 3, 4 },
    );
    try std.testing.expect(score.? >= 0.75);
    try std.testing.expect(score.? < 1.0);
}

test "result jsonl exposes all north-star metrics" {
    const jsonl = try resultToJsonl(std.testing.allocator, .{
        .doc_id = "example.pdf",
        .category = .financial_tables,
        .pages = 2,
        .text = .{ .cer = 0.01, .wer = 0.02, .token_f1 = 0.98 },
        .reading_order_score = 0.88,
        .table = .{
            .detection = scoreDetection(.{ .true_positive = 3, .false_positive = 1 }),
            .role_accuracy = 0.66,
            .rowspan_accuracy = 0.77,
            .colspan_accuracy = 0.88,
            .source_span_coverage = 0.55,
        },
        .formula = .{ .bleu = 0.9, .cdm = 0.8, .structure_accuracy = 0.75 },
        .form = .{ .field_accuracy = 0.5 },
        .latency = .{ .median_ms_per_page = 3.4, .p95_ms_per_page = 8.9, .peak_rss_mb = 42 },
        .counters = .{ .native_pages = 2, .table_regions = 1, .formula_regions = 1 },
    });
    defer std.testing.allocator.free(jsonl);

    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"token_f1\":0.980000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"reading_order_score\":0.880000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"teds\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"table_role_accuracy\":0.660000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"table_rowspan_accuracy\":0.770000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"table_colspan_accuracy\":0.880000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"table_source_span_coverage\":0.550000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"formula_edit_distance\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"formula_structure_accuracy\":0.750000") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"form_field_accuracy\":0.500000") != null);
    try std.testing.expect(std.mem.endsWith(u8, jsonl, "\n"));
}
