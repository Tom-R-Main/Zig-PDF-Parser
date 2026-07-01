//! Fast table/formula heuristics and optional local specialist adapters.
//!
//! Native heuristics are deliberately cheap and falsifiable: each score exposes
//! the evidence that made a region look table-like or formula-like. External
//! specialists are optional subprocess adapters for hard crops.

const std = @import("std");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");

pub const BBox = layout.BBox;
pub const TextSpan = layout.TextSpan;

pub const RulingOrientation = enum {
    horizontal,
    vertical,
};

pub const RulingLine = struct {
    bbox: BBox,
    orientation: RulingOrientation,
    stroke_width: f64 = 1,
};

pub const RegionInput = struct {
    page_index: u32 = 0,
    bbox: BBox,
    spans: []const TextSpan = &.{},
    ruling_lines: []const RulingLine = &.{},
};

pub const TableSignals = struct {
    repeated_x_positions: f32 = 0,
    ruling_lines: f32 = 0,
    whitespace_columns: f32 = 0,
    numeric_density: f32 = 0,

    pub fn confidence(self: TableSignals) f32 {
        const alignment = @max(self.repeated_x_positions, self.whitespace_columns);
        const grid = @max(alignment, self.ruling_lines);
        return clamp01f(grid * 0.72 + self.numeric_density * 0.28);
    }
};

pub const FormulaSignals = struct {
    symbol_density: f32 = 0,
    superscript_subscript_offsets: f32 = 0,
    compact_math_cluster: f32 = 0,

    pub fn confidence(self: FormulaSignals) f32 {
        return clamp01f(@max(self.symbol_density, self.superscript_subscript_offsets) * 0.78 + self.compact_math_cluster * 0.22);
    }
};

pub const TableScore = struct {
    page_index: u32,
    bbox: BBox,
    signals: TableSignals,
    confidence: f32,
    estimated_rows: u32 = 0,
    estimated_columns: u32 = 0,

    pub fn needsSpecialist(self: TableScore) bool {
        return self.confidence >= 0.68;
    }
};

pub const FormulaScore = struct {
    page_index: u32,
    bbox: BBox,
    signals: FormulaSignals,
    confidence: f32,

    pub fn needsSpecialist(self: FormulaScore) bool {
        return self.confidence >= 0.62;
    }
};

pub const AnalysisResult = struct {
    table: TableScore,
    formula: FormulaScore,
};

pub fn analyzeRegion(input: RegionInput) AnalysisResult {
    return .{
        .table = scoreTable(input),
        .formula = scoreFormula(input),
    };
}

pub fn scoreTable(input: RegionInput) TableScore {
    const spans = regionSpans(input);
    const repeated_x = scoreRepeatedXPositions(input.bbox, spans);
    const ruling = scoreRulingLines(input);
    const whitespace = scoreWhitespaceColumns(input.bbox, spans);
    const numeric = scoreNumericDensity(spans);
    const signals = TableSignals{
        .repeated_x_positions = repeated_x,
        .ruling_lines = ruling,
        .whitespace_columns = whitespace,
        .numeric_density = numeric,
    };

    return .{
        .page_index = input.page_index,
        .bbox = input.bbox,
        .signals = signals,
        .confidence = signals.confidence(),
        .estimated_rows = estimateRows(input.bbox, spans),
        .estimated_columns = estimateColumns(input.bbox, spans, input.ruling_lines),
    };
}

pub fn scoreFormula(input: RegionInput) FormulaScore {
    const spans = regionSpans(input);
    const signals = FormulaSignals{
        .symbol_density = scoreSymbolDensity(spans),
        .superscript_subscript_offsets = scoreScriptOffsets(spans),
        .compact_math_cluster = scoreCompactMathCluster(input.bbox, spans),
    };

    return .{
        .page_index = input.page_index,
        .bbox = input.bbox,
        .signals = signals,
        .confidence = signals.confidence(),
    };
}

pub const CropInput = struct {
    page_index: u32 = 0,
    pdf_bbox: BBox,
    image_path: []const u8,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
};

pub const TableSpecialistKind = enum {
    tatr,
    unitable,
};

pub const FormulaSpecialistKind = enum {
    pix2tex,
};

pub const SpecialistConfig = struct {
    executable: []const u8,
    extra_args: []const []const u8 = &.{},
    timeout_ms: u32 = 30_000,
    stdout_limit: usize = 16 * 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
};

pub const SpecialistOutput = struct {
    text: []u8,
    source: layout.SourceKind,

    pub fn deinit(self: SpecialistOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub fn runTableSpecialist(
    allocator: std.mem.Allocator,
    crop: CropInput,
    kind: TableSpecialistKind,
    config: SpecialistConfig,
) !SpecialistOutput {
    _ = kind;
    return runSpecialist(allocator, crop, config, .table_model);
}

pub fn runFormulaSpecialist(
    allocator: std.mem.Allocator,
    crop: CropInput,
    kind: FormulaSpecialistKind,
    config: SpecialistConfig,
) !SpecialistOutput {
    _ = kind;
    return runSpecialist(allocator, crop, config, .formula_model);
}

fn runSpecialist(
    allocator: std.mem.Allocator,
    crop: CropInput,
    config: SpecialistConfig,
    source: layout.SourceKind,
) !SpecialistOutput {
    if (crop.image_path.len == 0) return error.MissingCropImage;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, config.executable);
    try argv.appendSlice(allocator, config.extra_args);
    try argv.append(allocator, crop.image_path);

    const result = runtime.runCapture(allocator, argv.items, .{
        .stdout_limit = config.stdout_limit,
        .stderr_limit = config.stderr_limit,
        .timeout_ms = config.timeout_ms,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SpecialistUnavailable,
        else => return err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SpecialistFailed,
        else => return error.SpecialistFailed,
    }

    return .{
        .text = result.stdout,
        .source = source,
    };
}

fn regionSpans(input: RegionInput) []const TextSpan {
    return input.spans;
}

fn scoreRepeatedXPositions(region: BBox, spans: []const TextSpan) f32 {
    if (spans.len < 4) return 0;

    var repeated_count: usize = 0;
    for (spans, 0..) |span, span_index| {
        if (!intersects(region, span.bbox)) continue;
        var aligned: usize = 0;
        const bucket = xBucket(span.x0);
        for (spans, 0..) |other, other_index| {
            if (span_index == other_index) continue;
            if (!intersects(region, other.bbox)) continue;
            if (xBucket(other.x0) == bucket) aligned += 1;
        }
        if (aligned >= 2) repeated_count += 1;
    }

    return ratioScore(repeated_count, spans.len, 0.30, 0.72);
}

fn scoreRulingLines(input: RegionInput) f32 {
    if (input.ruling_lines.len == 0) return 0;

    var horizontal_count: usize = 0;
    var vertical_count: usize = 0;
    for (input.ruling_lines) |line| {
        if (!intersects(input.bbox, line.bbox)) continue;
        switch (line.orientation) {
            .horizontal => horizontal_count += 1,
            .vertical => vertical_count += 1,
        }
    }

    const grid_count = @min(horizontal_count, vertical_count);
    if (grid_count >= 2) return 1.0;
    if (horizontal_count >= 3 or vertical_count >= 3) return 0.72;
    if (horizontal_count + vertical_count >= 2) return 0.45;
    return 0;
}

fn scoreWhitespaceColumns(region: BBox, spans: []const TextSpan) f32 {
    if (spans.len < 6) return 0;

    const row_count = countRows(region, spans);
    if (row_count < 2) return 0;

    var repeated_gap_rows: usize = 0;
    for (spans) |left| {
        if (!intersects(region, left.bbox)) continue;
        var saw_gap = false;
        for (spans) |right| {
            if (!sameRow(left, right)) continue;
            const gap = right.x0 - left.x1;
            if (gap >= averageFontSize(spans) * 2.2) {
                saw_gap = true;
                break;
            }
        }
        if (saw_gap) repeated_gap_rows += 1;
    }

    return ratioScore(repeated_gap_rows, spans.len, 0.28, 0.66);
}

fn scoreNumericDensity(spans: []const TextSpan) f32 {
    var digit_count: usize = 0;
    var char_count: usize = 0;
    for (spans) |span| {
        for (span.text) |byte| {
            if (std.ascii.isWhitespace(byte)) continue;
            char_count += 1;
            if (std.ascii.isDigit(byte)) digit_count += 1;
        }
    }
    return ratioScore(digit_count, char_count, 0.18, 0.62);
}

fn scoreSymbolDensity(spans: []const TextSpan) f32 {
    var math_count: usize = 0;
    var char_count: usize = 0;
    for (spans) |span| {
        for (span.text) |byte| {
            if (std.ascii.isWhitespace(byte)) continue;
            char_count += 1;
            if (isAsciiMathByte(byte)) math_count += 1;
        }
        math_count += countUnicodeMathSequences(span.text) * 2;
    }
    return ratioScore(math_count, char_count, 0.10, 0.38);
}

fn scoreScriptOffsets(spans: []const TextSpan) f32 {
    if (spans.len < 2) return 0;
    const baseline = medianY(spans);
    const body_size = medianFontSize(spans);
    if (body_size <= 0) return 0;

    var script_count: usize = 0;
    for (spans) |span| {
        const small = span.font_size > 0 and span.font_size <= body_size * 0.86;
        const shifted = @abs(span.y0 - baseline) >= body_size * 0.20;
        if (small and shifted) script_count += 1;
    }
    return ratioScore(script_count, spans.len, 0.06, 0.26);
}

fn scoreCompactMathCluster(region: BBox, spans: []const TextSpan) f32 {
    if (spans.len == 0) return 0;
    const span_bounds = mergeSpanBounds(spans);
    const region_area = bboxArea(region);
    if (region_area <= 0) return 0;
    const fill_ratio = bboxArea(span_bounds) / region_area;
    const symbol_score = scoreSymbolDensity(spans);
    return clamp01f(@as(f32, @floatCast((1.0 - clamp01(fill_ratio)) * 0.4)) + symbol_score * 0.6);
}

fn estimateRows(region: BBox, spans: []const TextSpan) u32 {
    return @intCast(countRows(region, spans));
}

fn estimateColumns(region: BBox, spans: []const TextSpan, ruling_lines: []const RulingLine) u32 {
    var vertical_count: usize = 0;
    for (ruling_lines) |line| {
        if (line.orientation == .vertical and intersects(region, line.bbox)) vertical_count += 1;
    }
    if (vertical_count >= 2) return @intCast(vertical_count - 1);

    var buckets: [32]i64 = undefined;
    var bucket_count: usize = 0;
    for (spans) |span| {
        if (!intersects(region, span.bbox)) continue;
        const bucket = xBucket(span.x0);
        var found = false;
        for (buckets[0..bucket_count]) |existing| {
            if (existing == bucket) {
                found = true;
                break;
            }
        }
        if (!found and bucket_count < buckets.len) {
            buckets[bucket_count] = bucket;
            bucket_count += 1;
        }
    }
    return @intCast(bucket_count);
}

fn countRows(region: BBox, spans: []const TextSpan) usize {
    var buckets: [64]i64 = undefined;
    var bucket_count: usize = 0;
    for (spans) |span| {
        if (!intersects(region, span.bbox)) continue;
        const bucket = yBucket(span.y0);
        var found = false;
        for (buckets[0..bucket_count]) |existing| {
            if (existing == bucket) {
                found = true;
                break;
            }
        }
        if (!found and bucket_count < buckets.len) {
            buckets[bucket_count] = bucket;
            bucket_count += 1;
        }
    }
    return bucket_count;
}

fn averageFontSize(spans: []const TextSpan) f64 {
    if (spans.len == 0) return 12;
    var total: f64 = 0;
    var count: usize = 0;
    for (spans) |span| {
        if (span.font_size > 0) {
            total += span.font_size;
            count += 1;
        }
    }
    return if (count == 0) 12 else total / @as(f64, @floatFromInt(count));
}

fn medianY(spans: []const TextSpan) f64 {
    if (spans.len == 0) return 0;
    var values: [64]f64 = undefined;
    const count = @min(spans.len, values.len);
    for (spans[0..count], 0..) |span, i| values[i] = span.y0;
    std.mem.sort(f64, values[0..count], {}, comptime std.sort.asc(f64));
    return values[count / 2];
}

fn medianFontSize(spans: []const TextSpan) f64 {
    if (spans.len == 0) return 0;
    var values: [64]f64 = undefined;
    const count = @min(spans.len, values.len);
    for (spans[0..count], 0..) |span, i| values[i] = span.font_size;
    std.mem.sort(f64, values[0..count], {}, comptime std.sort.asc(f64));
    return values[count / 2];
}

fn mergeSpanBounds(spans: []const TextSpan) BBox {
    if (spans.len == 0) return .{};
    var bounds = spans[0].bbox;
    for (spans[1..]) |span| {
        bounds.x0 = @min(bounds.x0, span.x0);
        bounds.y0 = @min(bounds.y0, span.y0);
        bounds.x1 = @max(bounds.x1, span.x1);
        bounds.y1 = @max(bounds.y1, span.y1);
    }
    return bounds;
}

fn intersects(a: BBox, b: BBox) bool {
    return a.x0 < b.x1 and a.x1 > b.x0 and a.y0 < b.y1 and a.y1 > b.y0;
}

fn sameRow(a: TextSpan, b: TextSpan) bool {
    return @abs(a.y0 - b.y0) <= @max(4.0, @max(a.font_size, b.font_size) * 0.35);
}

fn xBucket(x: f64) i64 {
    return @intFromFloat(@round(x / 8.0));
}

fn yBucket(y: f64) i64 {
    return @intFromFloat(@round(y / 8.0));
}

fn bboxArea(bbox: BBox) f64 {
    return @max(0, bbox.x1 - bbox.x0) * @max(0, bbox.y1 - bbox.y0);
}

fn ratioScore(numerator: usize, denominator: usize, low: f64, high: f64) f32 {
    if (denominator == 0) return 0;
    const ratio = @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
    return @floatCast(clamp01((ratio - low) / (high - low)));
}

fn isAsciiMathByte(byte: u8) bool {
    return switch (byte) {
        '+', '-', '*', '/', '=', '<', '>', '^', '_', '|', '~', '(', ')', '[', ']' => true,
        else => false,
    };
}

fn countUnicodeMathSequences(text: []const u8) usize {
    const needles = [_][]const u8{ "∑", "∫", "√", "≤", "≥", "≈", "∞", "π", "α", "β", "γ", "Δ" };
    var total: usize = 0;
    for (needles) |needle| {
        var rest = text;
        while (std.mem.indexOf(u8, rest, needle)) |index| {
            total += 1;
            rest = rest[index + needle.len ..];
        }
    }
    return total;
}

fn clamp01(value: f64) f64 {
    return @max(0, @min(1, value));
}

fn clamp01f(value: f32) f32 {
    return @max(0, @min(1, value));
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
    });
}

fn testSpanSized(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64, size: f64) TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .size = size },
    });
}

test "table heuristics score repeated x positions and numeric density" {
    const spans = [_]TextSpan{
        testSpan("2019", 80, 700, 112, 714),
        testSpan("100", 200, 700, 230, 714),
        testSpan("2020", 80, 680, 112, 694),
        testSpan("125", 200, 680, 230, 694),
        testSpan("2021", 80, 660, 112, 674),
        testSpan("140", 200, 660, 230, 674),
        testSpan("2022", 80, 640, 112, 654),
        testSpan("155", 200, 640, 230, 654),
    };

    const score = scoreTable(.{
        .bbox = .{ .x0 = 60, .y0 = 620, .x1 = 260, .y1 = 720 },
        .spans = &spans,
    });

    try std.testing.expect(score.signals.repeated_x_positions >= 0.60);
    try std.testing.expect(score.signals.numeric_density >= 0.50);
    try std.testing.expect(score.needsSpecialist());
    try std.testing.expectEqual(@as(u32, 4), score.estimated_rows);
    try std.testing.expectEqual(@as(u32, 2), score.estimated_columns);
}

test "table heuristics score ruling lines and whitespace columns" {
    const spans = [_]TextSpan{
        testSpan("Region", 80, 700, 126, 714),
        testSpan("Revenue", 220, 700, 278, 714),
        testSpan("East", 80, 680, 112, 694),
        testSpan("$100", 220, 680, 258, 694),
        testSpan("West", 80, 660, 112, 674),
        testSpan("$125", 220, 660, 258, 674),
    };
    const lines = [_]RulingLine{
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 70, .y0 = 718, .x1 = 290, .y1 = 719 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 70, .y0 = 678, .x1 = 290, .y1 = 679 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 70, .y0 = 650, .x1 = 71, .y1 = 720 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 200, .y0 = 650, .x1 = 201, .y1 = 720 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 290, .y0 = 650, .x1 = 291, .y1 = 720 } },
    };

    const score = scoreTable(.{
        .bbox = .{ .x0 = 60, .y0 = 640, .x1 = 300, .y1 = 730 },
        .spans = &spans,
        .ruling_lines = &lines,
    });

    try std.testing.expect(score.signals.ruling_lines >= 0.95);
    try std.testing.expect(score.signals.whitespace_columns >= 0.55);
    try std.testing.expect(score.confidence >= 0.70);
    try std.testing.expectEqual(@as(u32, 2), score.estimated_columns);
}

test "formula heuristics score symbols and super/subscript offsets" {
    const spans = [_]TextSpan{
        testSpanSized("E", 120, 700, 130, 714, 12),
        testSpanSized("=", 136, 700, 144, 714, 12),
        testSpanSized("mc", 150, 700, 168, 714, 12),
        testSpanSized("2", 170, 709, 176, 718, 8),
        testSpanSized("+", 184, 700, 192, 714, 12),
        testSpanSized("∑", 200, 700, 210, 716, 12),
    };

    const score = scoreFormula(.{
        .bbox = .{ .x0 = 110, .y0 = 690, .x1 = 230, .y1 = 725 },
        .spans = &spans,
    });

    try std.testing.expect(score.signals.symbol_density >= 0.50);
    try std.testing.expect(score.signals.superscript_subscript_offsets >= 0.40);
    try std.testing.expect(score.needsSpecialist());
}

test "prose region stays below specialist thresholds" {
    const spans = [_]TextSpan{
        testSpan("This", 80, 700, 110, 714),
        testSpan("paragraph", 116, 700, 180, 714),
        testSpan("contains", 186, 700, 236, 714),
        testSpan("ordinary", 242, 700, 296, 714),
        testSpan("text", 302, 700, 330, 714),
    };
    const input = RegionInput{
        .bbox = .{ .x0 = 70, .y0 = 690, .x1 = 340, .y1 = 725 },
        .spans = &spans,
    };

    try std.testing.expect(!scoreTable(input).needsSpecialist());
    try std.testing.expect(!scoreFormula(input).needsSpecialist());
}

test "specialist output owns stdout and carries provenance" {
    const output = SpecialistOutput{
        .text = try std.testing.allocator.dupe(u8, "x = y"),
        .source = .formula_model,
    };
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(layout.SourceKind.formula_model, output.source);
    try std.testing.expectEqualStrings("x = y", output.text);
}

test "specialist adapters require a crop image path before spawning" {
    const crop = CropInput{
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .image_path = "",
    };
    const config = SpecialistConfig{ .executable = "unused-specialist" };

    try std.testing.expectError(error.MissingCropImage, runTableSpecialist(std.testing.allocator, crop, .tatr, config));
    try std.testing.expectError(error.MissingCropImage, runFormulaSpecialist(std.testing.allocator, crop, .pix2tex, config));
}
