//! Native glyph-first text layout reconstruction.
//!
//! PDF content streams preserve drawing instructions, not words or lines. This
//! module keeps glyph geometry long enough to infer explicit boundaries with
//! confidence and provenance before flattening the page to readable text.

const std = @import("std");
const interpreter = @import("interpreter.zig");
const layout = @import("layout.zig");

pub const GlyphSpan = interpreter.GlyphSpan;
pub const BBox = layout.BBox;

pub const BoundaryKind = enum(u8) {
    join,
    space,
    line_break,
    block_break,
    region_break,
};

pub const BoundaryProvenance = enum(u8) {
    content_start,
    explicit_whitespace,
    tj_adjustment,
    geometric_gap,
    baseline_shift,
    paragraph_gap,
    detected_gutter,
};

pub const Boundary = struct {
    before_glyph_index: u32,
    previous_glyph_index: ?u32 = null,
    kind: BoundaryKind,
    confidence: f32,
    provenance: BoundaryProvenance,
    inline_gap: f64 = 0,
    baseline_offset: f64 = 0,
};

pub const Line = struct {
    line_index: u32,
    ordered_start: u32,
    glyph_count: u32,
    bbox: BBox,
    baseline: f64,
    font_size: f64,
    region_index: u32 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
};

pub const QualityMetrics = struct {
    word_boundary_precision: ?f64 = null,
    word_boundary_recall: ?f64 = null,
    line_break_f1: ?f64 = null,
    token_f1: ?f64 = null,
    word_error_rate: ?f64 = null,
    max_token_bytes: usize = 0,
    max_line_bytes: usize = 0,
    extreme_token_length_rate: f64 = 0,
    extreme_line_length_rate: f64 = 0,
    raw_non_whitespace_recall: f64 = 1,
    word_boundary_count: usize = 0,
    line_break_count: usize = 0,
    quality_pass: bool = true,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    ordered_glyph_indices: []u32,
    boundaries: []Boundary,
    lines: []Line,
    text: []u8,
    quality: QualityMetrics,
    gutter: ?BBox = null,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.ordered_glyph_indices);
        self.allocator.free(self.boundaries);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
    }
};

const PendingLine = struct {
    start: usize,
    count: usize,
    baseline_sum: f64,
    baseline_count: usize,
    max_font_size: f64,
    bbox: BBox,
    region_index: u32,

    fn baseline(self: PendingLine) f64 {
        return self.baseline_sum / @as(f64, @floatFromInt(self.baseline_count));
    }
};

const BoundarySignature = struct {
    word: std.ArrayList(u32) = .empty,
    line: std.ArrayList(u32) = .empty,
    non_whitespace: std.ArrayList(u8) = .empty,

    fn deinit(self: *BoundarySignature, allocator: std.mem.Allocator) void {
        self.word.deinit(allocator);
        self.line.deinit(allocator);
        self.non_whitespace.deinit(allocator);
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    page_bbox: BBox,
    raw_recall_text: []const u8,
) !Result {
    if (glyphs.len == 0) {
        return .{
            .allocator = allocator,
            .ordered_glyph_indices = try allocator.alloc(u32, 0),
            .boundaries = try allocator.alloc(Boundary, 0),
            .lines = try allocator.alloc(Line, 0),
            .text = try allocator.alloc(u8, 0),
            .quality = qualityForText(raw_recall_text, ""),
        };
    }

    const sorted_indices = try allocator.alloc(u32, glyphs.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*index, glyph_index| index.* = @intCast(glyph_index);
    std.mem.sort(u32, sorted_indices, glyphs, compareGlyphTopDown);

    var line_glyphs: std.ArrayList(u32) = .empty;
    defer line_glyphs.deinit(allocator);
    var pending_lines: std.ArrayList(PendingLine) = .empty;
    defer pending_lines.deinit(allocator);
    const gutter = detectCentralGutter(allocator, glyphs, page_bbox) catch null;

    for (sorted_indices) |glyph_index| {
        const glyph = glyphs[glyph_index];
        if (glyph.text.len == 0) continue;
        const glyph_baseline = baselineCoordinate(glyph);
        var target_line: ?usize = null;
        var line_index = pending_lines.items.len;
        while (line_index > 0) {
            line_index -= 1;
            const candidate = pending_lines.items[line_index];
            const tolerance = @max(1.5, @max(candidate.max_font_size, glyph.font_size) * 0.55);
            const delta = @abs(glyph_baseline - candidate.baseline());
            if (delta <= tolerance and
                sameOrientation(glyphs[candidateGlyphIndex(line_glyphs.items, candidate)], glyph) and
                regionsCompatible(candidate.region_index, regionForGlyph(glyph.bbox, gutter)))
            {
                target_line = line_index;
                break;
            }
            if (candidate.baseline() - glyph_baseline > @max(12.0, tolerance * 2.0)) break;
        }

        if (target_line) |existing_index| {
            // Line glyphs are gathered in top-down order. Appending to an older
            // line would make its range discontinuous, so move that line's
            // existing range to the tail before extending it.
            if (existing_index + 1 != pending_lines.items.len) {
                try moveLineToTail(allocator, &line_glyphs, &pending_lines, existing_index);
                target_line = pending_lines.items.len - 1;
            }
            const line = &pending_lines.items[target_line.?];
            try line_glyphs.append(allocator, glyph_index);
            line.count += 1;
            line.baseline_sum += glyph_baseline;
            line.baseline_count += 1;
            line.max_font_size = @max(line.max_font_size, glyph.font_size);
            line.bbox = unionBox(line.bbox, glyph.bbox);
        } else {
            const start = line_glyphs.items.len;
            try line_glyphs.append(allocator, glyph_index);
            try pending_lines.append(allocator, .{
                .start = start,
                .count = 1,
                .baseline_sum = glyph_baseline,
                .baseline_count = 1,
                .max_font_size = glyph.font_size,
                .bbox = glyph.bbox,
                .region_index = regionForGlyph(glyph.bbox, gutter),
            });
        }
    }

    for (pending_lines.items) |line| {
        const slice = line_glyphs.items[line.start .. line.start + line.count];
        std.mem.sort(u32, slice, glyphs, compareGlyphInline);
    }

    const line_order = try orderLinesByRegions(allocator, pending_lines.items, gutter);
    defer allocator.free(line_order);

    var ordered: std.ArrayList(u32) = .empty;
    errdefer ordered.deinit(allocator);
    try ordered.ensureTotalCapacity(allocator, line_glyphs.items.len);
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    for (line_order) |source_line_index| {
        const source = pending_lines.items[source_line_index];
        const ordered_start = ordered.items.len;
        try ordered.appendSlice(allocator, line_glyphs.items[source.start .. source.start + source.count]);
        try lines.append(allocator, .{
            .line_index = @intCast(lines.items.len),
            .ordered_start = @intCast(ordered_start),
            .glyph_count = @intCast(source.count),
            .bbox = source.bbox,
            .baseline = source.baseline(),
            .font_size = source.max_font_size,
            .region_index = source.region_index,
        });
    }

    const owned_ordered = try ordered.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ordered);
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const boundaries = try classifyBoundaries(allocator, glyphs, owned_ordered, owned_lines);
    errdefer allocator.free(boundaries);
    const text = try renderReadable(allocator, glyphs, owned_ordered, boundaries, owned_lines);
    errdefer allocator.free(text);

    var quality = qualityForText(raw_recall_text, text);
    quality.word_boundary_count = countBoundaryKind(boundaries, .space);
    quality.line_break_count = countLineBoundaries(boundaries);
    quality.quality_pass = passesQualityGate(quality, glyphs.len);

    return .{
        .allocator = allocator,
        .ordered_glyph_indices = owned_ordered,
        .boundaries = boundaries,
        .lines = owned_lines,
        .text = text,
        .quality = quality,
        .gutter = gutter,
    };
}

pub fn compareAgainstReference(
    allocator: std.mem.Allocator,
    raw_recall_text: []const u8,
    readable_text: []const u8,
    reference_text: []const u8,
) !QualityMetrics {
    var metrics = qualityForText(raw_recall_text, readable_text);
    var expected = try boundarySignature(allocator, reference_text);
    defer expected.deinit(allocator);
    var actual = try boundarySignature(allocator, readable_text);
    defer actual.deinit(allocator);
    metrics.word_boundary_count = actual.word.items.len;
    metrics.line_break_count = actual.line.items.len;

    if (std.mem.eql(u8, expected.non_whitespace.items, actual.non_whitespace.items)) {
        const word = precisionRecall(expected.word.items, actual.word.items);
        metrics.word_boundary_precision = word.precision;
        metrics.word_boundary_recall = word.recall;
        const line = precisionRecall(expected.line.items, actual.line.items);
        metrics.line_break_f1 = f1(line.precision, line.recall);
    }

    const token_metrics = try compareTokens(allocator, reference_text, readable_text);
    metrics.token_f1 = token_metrics.f1;
    metrics.word_error_rate = token_metrics.wer;
    metrics.quality_pass = passesQualityGate(metrics, actual.non_whitespace.items.len);
    return metrics;
}

pub fn buildLineSpans(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    result: *const Result,
    page_index: u32,
) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }

    for (result.lines) |line| {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        const start: usize = @intCast(line.ordered_start);
        const count: usize = @intCast(line.glyph_count);
        for (result.ordered_glyph_indices[start .. start + count], 0..) |glyph_index, local_index| {
            const boundary = result.boundaries[start + local_index];
            const glyph = glyphs[glyph_index];
            if (local_index > 0 and boundary.kind == .space and !endsInWhitespace(text.items)) {
                try text.append(allocator, ' ');
            }
            try appendNormalizedGlyph(allocator, &text, glyph.text);
        }
        trimTrailingWhitespace(&text);
        if (text.items.len == 0) {
            text.deinit(allocator);
            continue;
        }
        const owned_text = try text.toOwnedSlice(allocator);
        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = page_index,
            .bbox = line.bbox,
            .text = owned_text,
            .source = .native_pdf,
            .confidence = lineConfidence(result, line),
            .font = .{ .size = line.font_size },
            .line_id = line.line_index,
        }));
    }
    return spans.toOwnedSlice(allocator);
}

fn candidateGlyphIndex(line_glyphs: []const u32, line: PendingLine) u32 {
    return line_glyphs[line.start];
}

fn moveLineToTail(
    allocator: std.mem.Allocator,
    line_glyphs: *std.ArrayList(u32),
    lines: *std.ArrayList(PendingLine),
    line_index: usize,
) !void {
    const source = lines.items[line_index];
    const copy = try allocator.dupe(u32, line_glyphs.items[source.start .. source.start + source.count]);
    defer allocator.free(copy);
    try line_glyphs.appendSlice(allocator, copy);
    var moved = source;
    moved.start = line_glyphs.items.len - source.count;
    _ = lines.orderedRemove(line_index);
    try lines.append(allocator, moved);
}

fn compareGlyphTopDown(glyphs: []const GlyphSpan, a_index: u32, b_index: u32) bool {
    const a = glyphs[a_index];
    const b = glyphs[b_index];
    const ay = baselineCoordinate(a);
    const by = baselineCoordinate(b);
    if (ay != by) return ay > by;
    return inlineCoordinate(a) < inlineCoordinate(b);
}

fn compareGlyphInline(glyphs: []const GlyphSpan, a_index: u32, b_index: u32) bool {
    const a = glyphs[a_index];
    const b = glyphs[b_index];
    const a_coord = inlineCoordinate(a);
    const b_coord = inlineCoordinate(b);
    if (a_coord != b_coord) return a_coord < b_coord;
    return a_index < b_index;
}

fn inlineCoordinate(glyph: GlyphSpan) f64 {
    if (glyph.writing_mode == 1) return -glyph.text_matrix[5];
    const a = glyph.text_matrix[0];
    const b = glyph.text_matrix[1];
    const magnitude = @max(0.0001, @sqrt(a * a + b * b));
    return (glyph.text_matrix[4] * a + glyph.text_matrix[5] * b) / magnitude;
}

fn baselineCoordinate(glyph: GlyphSpan) f64 {
    if (glyph.writing_mode == 1) return glyph.text_matrix[4];
    const a = glyph.text_matrix[0];
    const b = glyph.text_matrix[1];
    const magnitude = @max(0.0001, @sqrt(a * a + b * b));
    return (-glyph.text_matrix[4] * b + glyph.text_matrix[5] * a) / magnitude;
}

fn sameOrientation(a: GlyphSpan, b: GlyphSpan) bool {
    if (a.writing_mode != b.writing_mode) return false;
    const aa = a.text_matrix[0];
    const ab = a.text_matrix[1];
    const ba = b.text_matrix[0];
    const bb = b.text_matrix[1];
    const a_len = @sqrt(aa * aa + ab * ab);
    const b_len = @sqrt(ba * ba + bb * bb);
    if (a_len <= 0.0001 or b_len <= 0.0001) return true;
    return @abs((aa * ba + ab * bb) / (a_len * b_len)) >= 0.94;
}

fn detectCentralGutter(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    page_bbox: BBox,
) !?BBox {
    _ = allocator;
    const page_width = page_bbox.x1 - page_bbox.x0;
    if (page_width <= 0 or glyphs.len < 24) return null;
    const bin_count = 96;
    var occupancy: [bin_count]u32 = @splat(0);
    var left_count: usize = 0;
    var right_count: usize = 0;

    for (glyphs) |glyph| {
        if (isWhitespace(glyph.text)) continue;
        const x0 = @max(page_bbox.x0, @min(page_bbox.x1, glyph.bbox.x0));
        const x1 = @max(page_bbox.x0, @min(page_bbox.x1, glyph.bbox.x1));
        const first: usize = @intFromFloat(@floor((x0 - page_bbox.x0) / page_width * bin_count));
        const last_raw: usize = @intFromFloat(@floor((x1 - page_bbox.x0) / page_width * bin_count));
        const last = @min(bin_count - 1, last_raw);
        var bin = @min(bin_count - 1, first);
        while (bin <= last) : (bin += 1) occupancy[bin] += 1;
    }

    const allowed: u32 = @intCast(@max(1, glyphs.len / 800));
    const search_start = bin_count * 3 / 10;
    const search_end = bin_count * 7 / 10;
    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: ?usize = null;
    var bin: usize = search_start;
    while (bin < search_end) : (bin += 1) {
        if (occupancy[bin] <= allowed) {
            if (run_start == null) run_start = bin;
        } else if (run_start) |start| {
            if (bin - start > best_len) {
                best_start = start;
                best_len = bin - start;
            }
            run_start = null;
        }
    }
    if (run_start) |start| {
        if (search_end - start > best_len) {
            best_start = start;
            best_len = search_end - start;
        }
    }

    const gutter_width = @as(f64, @floatFromInt(best_len)) / bin_count * page_width;
    if (gutter_width < @max(12.0, page_width * 0.025)) return null;
    const gutter_x0 = page_bbox.x0 + @as(f64, @floatFromInt(best_start)) / bin_count * page_width;
    const gutter_x1 = gutter_x0 + gutter_width;
    for (glyphs) |glyph| {
        if (isWhitespace(glyph.text)) continue;
        const center = (glyph.bbox.x0 + glyph.bbox.x1) / 2.0;
        if (center < gutter_x0) left_count += 1;
        if (center > gutter_x1) right_count += 1;
    }
    if (left_count < 10 or right_count < 10) return null;
    if (baselineBandCount(glyphs, gutter_x0, true) < 2 or baselineBandCount(glyphs, gutter_x1, false) < 2) return null;
    return .{ .x0 = gutter_x0, .y0 = page_bbox.y0, .x1 = gutter_x1, .y1 = page_bbox.y1 };
}

fn baselineBandCount(glyphs: []const GlyphSpan, split_x: f64, left_side: bool) usize {
    var bands: [64]f64 = undefined;
    var count: usize = 0;
    for (glyphs) |glyph| {
        if (isWhitespace(glyph.text)) continue;
        const center = (glyph.bbox.x0 + glyph.bbox.x1) / 2.0;
        if ((left_side and center >= split_x) or (!left_side and center <= split_x)) continue;
        const baseline = baselineCoordinate(glyph);
        var found = false;
        for (bands[0..count]) |existing| {
            if (@abs(existing - baseline) <= @max(1.5, glyph.font_size * 0.55)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (count == bands.len) return count;
            bands[count] = baseline;
            count += 1;
        }
    }
    return count;
}

fn orderLinesByRegions(
    allocator: std.mem.Allocator,
    lines: []const PendingLine,
    gutter: ?BBox,
) ![]u32 {
    const order = try allocator.alloc(u32, lines.len);
    if (gutter == null) {
        for (order, 0..) |*entry, index| entry.* = @intCast(index);
        return order;
    }

    var output: std.ArrayList(u32) = .empty;
    defer output.deinit(allocator);
    var section_start: usize = 0;
    for (lines, 0..) |line, line_index| {
        if (line.region_index != 2) continue;
        try appendColumnSection(allocator, &output, lines, section_start, line_index);
        try output.append(allocator, @intCast(line_index));
        section_start = line_index + 1;
    }
    try appendColumnSection(allocator, &output, lines, section_start, lines.len);
    @memcpy(order, output.items);
    return order;
}

fn appendColumnSection(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    lines: []const PendingLine,
    start: usize,
    end: usize,
) !void {
    for (start..end) |index| {
        if (lines[index].region_index == 0) try output.append(allocator, @intCast(index));
    }
    for (start..end) |index| {
        if (lines[index].region_index == 1) try output.append(allocator, @intCast(index));
    }
}

fn regionForLine(bbox: BBox, gutter: ?BBox) u32 {
    const split = gutter orelse return 0;
    if (bbox.x1 <= split.x0) return 0;
    if (bbox.x0 >= split.x1) return 1;
    return 2;
}

fn regionForGlyph(bbox: BBox, gutter: ?BBox) u32 {
    const split = gutter orelse return 0;
    const center = (bbox.x0 + bbox.x1) / 2.0;
    if (center < split.x0) return 0;
    if (center > split.x1) return 1;
    return 2;
}

fn regionsCompatible(a: u32, b: u32) bool {
    return a == b or a == 2 or b == 2;
}

fn classifyBoundaries(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    ordered: []const u32,
    lines: []const Line,
) ![]Boundary {
    const boundaries = try allocator.alloc(Boundary, ordered.len);
    if (ordered.len == 0) return boundaries;
    var line_index: usize = 0;
    var next_line_start: usize = if (lines.len > 1) @intCast(lines[1].ordered_start) else ordered.len;

    for (ordered, 0..) |glyph_index, ordered_index| {
        if (ordered_index == 0) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .kind = .region_break,
                .confidence = 1,
                .provenance = .content_start,
            };
            continue;
        }
        if (ordered_index == next_line_start) {
            const previous_line = lines[line_index];
            line_index += 1;
            const current_line = lines[line_index];
            next_line_start = if (line_index + 1 < lines.len) @intCast(lines[line_index + 1].ordered_start) else ordered.len;
            const baseline_gap = @abs(previous_line.baseline - current_line.baseline);
            const paragraph_threshold = @max(previous_line.font_size, current_line.font_size) * 2.0;
            const region_changed = previous_line.region_index != current_line.region_index;
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = ordered[ordered_index - 1],
                .kind = if (region_changed) .region_break else if (baseline_gap > paragraph_threshold) .block_break else .line_break,
                .confidence = if (region_changed) 0.88 else if (baseline_gap > paragraph_threshold) 0.86 else 0.93,
                .provenance = if (region_changed) .detected_gutter else if (baseline_gap > paragraph_threshold) .paragraph_gap else .baseline_shift,
                .baseline_offset = baseline_gap,
            };
            continue;
        }

        const previous_index = ordered[ordered_index - 1];
        const previous = glyphs[previous_index];
        const current = glyphs[glyph_index];
        if (isWhitespace(current.text)) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = previous_index,
                .kind = .space,
                .confidence = if (current.generated) 0.96 else 0.995,
                .provenance = if (current.generated) .tj_adjustment else .explicit_whitespace,
            };
            continue;
        }
        if (isWhitespace(previous.text)) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = previous_index,
                .kind = .join,
                .confidence = 0.995,
                .provenance = if (previous.generated) .tj_adjustment else .explicit_whitespace,
            };
            continue;
        }

        const gap = inlineGap(previous, current);
        const em = @max(1.0, @max(previous.font_size, current.font_size));
        const space_threshold = em * 0.105;
        const is_space = gap > space_threshold;
        const ratio = gap / em;
        boundaries[ordered_index] = .{
            .before_glyph_index = glyph_index,
            .previous_glyph_index = previous_index,
            .kind = if (is_space) .space else .join,
            .confidence = if (is_space) @floatCast(@min(0.96, 0.68 + ratio)) else @floatCast(@min(0.98, 0.82 + @max(0.0, (space_threshold - gap) / em))),
            .provenance = .geometric_gap,
            .inline_gap = gap,
            .baseline_offset = @abs(baselineCoordinate(previous) - baselineCoordinate(current)),
        };
    }
    return boundaries;
}

fn inlineGap(previous: GlyphSpan, current: GlyphSpan) f64 {
    if (previous.writing_mode == 1) return previous.bbox.y0 - current.bbox.y1;
    const a = previous.text_matrix[0];
    const b = previous.text_matrix[1];
    if (@abs(b) > @abs(a) * 0.5) {
        return inlineCoordinate(current) - inlineCoordinate(previous) - previous.advance;
    }
    return current.bbox.x0 - previous.bbox.x1;
}

fn renderReadable(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    ordered: []const u32,
    boundaries: []const Boundary,
    lines: []Line,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var mutable_lines = @constCast(lines);
    var line_index: usize = 0;

    for (ordered, 0..) |glyph_index, ordered_index| {
        const boundary = boundaries[ordered_index];
        if (ordered_index > 0) switch (boundary.kind) {
            .join => {},
            .space => if (!endsInWhitespace(output.items)) try output.append(allocator, ' '),
            .line_break => try appendBreak(allocator, &output, 1),
            .block_break, .region_break => try appendBreak(allocator, &output, 2),
        };
        while (line_index + 1 < mutable_lines.len and ordered_index == mutable_lines[line_index + 1].ordered_start) {
            mutable_lines[line_index].text_len = @intCast(output.items.len - mutable_lines[line_index].text_start);
            line_index += 1;
            mutable_lines[line_index].text_start = @intCast(output.items.len);
        }
        try appendNormalizedGlyph(allocator, &output, glyphs[glyph_index].text);
    }
    trimTrailingWhitespace(&output);
    if (mutable_lines.len > 0) {
        mutable_lines[line_index].text_len = @intCast(output.items.len - mutable_lines[line_index].text_start);
    }
    return output.toOwnedSlice(allocator);
}

fn appendNormalizedGlyph(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    if (isWhitespace(text)) {
        if (output.items.len > 0 and !endsInWhitespace(output.items)) try output.append(allocator, ' ');
        return;
    }
    try output.appendSlice(allocator, text);
}

fn appendBreak(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    trimTrailingSpaces(output);
    var existing: usize = 0;
    var index = output.items.len;
    while (index > 0 and output.items[index - 1] == '\n') : (index -= 1) existing += 1;
    var needed = count -| existing;
    while (needed > 0) : (needed -= 1) try output.append(allocator, '\n');
}

fn isWhitespace(text: []const u8) bool {
    if (text.len == 0) return false;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return false;
        if (index + sequence_len > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return false;
        if (!isWhitespaceCodepoint(codepoint)) return false;
        index += sequence_len;
    }
    return true;
}

fn isWhitespaceCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn qualityForText(raw: []const u8, readable: []const u8) QualityMetrics {
    var metrics = QualityMetrics{};
    metrics.raw_non_whitespace_recall = byteMultisetRecall(raw, readable);
    var token_len: usize = 0;
    var line_len: usize = 0;
    var token_count: usize = 0;
    var line_count: usize = 0;
    var extreme_tokens: usize = 0;
    var extreme_lines: usize = 0;
    for (readable) |byte| {
        if (byte == '\n' or byte == '\r') {
            metrics.max_line_bytes = @max(metrics.max_line_bytes, line_len);
            metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
            if (line_len > 0) {
                line_count += 1;
                if (line_len > 1000) extreme_lines += 1;
            }
            if (token_len > 0) {
                token_count += 1;
                if (token_len > 80) extreme_tokens += 1;
            }
            line_len = 0;
            token_len = 0;
        } else {
            line_len += 1;
            if (std.ascii.isWhitespace(byte)) {
                metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
                if (token_len > 0) {
                    token_count += 1;
                    if (token_len > 80) extreme_tokens += 1;
                }
                token_len = 0;
            } else {
                token_len += 1;
            }
        }
    }
    metrics.max_line_bytes = @max(metrics.max_line_bytes, line_len);
    metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
    if (line_len > 0) {
        line_count += 1;
        if (line_len > 1000) extreme_lines += 1;
    }
    if (token_len > 0) {
        token_count += 1;
        if (token_len > 80) extreme_tokens += 1;
    }
    metrics.extreme_token_length_rate = fraction(extreme_tokens, token_count);
    metrics.extreme_line_length_rate = fraction(extreme_lines, line_count);
    return metrics;
}

fn passesQualityGate(metrics: QualityMetrics, glyph_count: usize) bool {
    if (metrics.raw_non_whitespace_recall < 0.995) return false;
    if (metrics.max_token_bytes > 160 or metrics.max_line_bytes > 4096) return false;
    if (metrics.extreme_token_length_rate > 0.02 or metrics.extreme_line_length_rate > 0.05) return false;
    if (glyph_count >= 200 and metrics.word_boundary_count == 0) return false;
    if (metrics.word_boundary_precision) |value| if (value < 0.80) return false;
    if (metrics.word_boundary_recall) |value| if (value < 0.80) return false;
    if (metrics.line_break_f1) |value| if (value < 0.70) return false;
    if (metrics.token_f1) |value| if (value < 0.85) return false;
    if (metrics.word_error_rate) |value| if (value > 0.25) return false;
    return true;
}

fn fraction(numerator: usize, denominator: usize) f64 {
    if (denominator == 0) return 0;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn byteMultisetRecall(expected: []const u8, actual: []const u8) f64 {
    var expected_counts: [256]usize = @splat(0);
    var actual_counts: [256]usize = @splat(0);
    var expected_total: usize = 0;
    for (expected) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        expected_counts[byte] += 1;
        expected_total += 1;
    }
    if (expected_total == 0) return 1;
    for (actual) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        actual_counts[byte] += 1;
    }
    var matched: usize = 0;
    for (expected_counts, actual_counts) |expected_count, actual_count| matched += @min(expected_count, actual_count);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected_total));
}

fn boundarySignature(allocator: std.mem.Allocator, text: []const u8) !BoundarySignature {
    var signature = BoundarySignature{};
    errdefer signature.deinit(allocator);
    var non_whitespace_count: u32 = 0;
    var pending_word = false;
    var pending_line = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_word = true;
            if (byte == '\n' or byte == '\r' or byte == '\x0c') pending_line = true;
            continue;
        }
        if (non_whitespace_count > 0) {
            if (pending_word) try appendUniqueBoundary(allocator, &signature.word, non_whitespace_count);
            if (pending_line) try appendUniqueBoundary(allocator, &signature.line, non_whitespace_count);
        }
        try signature.non_whitespace.append(allocator, byte);
        non_whitespace_count += 1;
        pending_word = false;
        pending_line = false;
    }
    return signature;
}

fn appendUniqueBoundary(allocator: std.mem.Allocator, list: *std.ArrayList(u32), boundary: u32) !void {
    if (list.items.len == 0 or list.items[list.items.len - 1] != boundary) try list.append(allocator, boundary);
}

const PrecisionRecall = struct { precision: f64, recall: f64 };

fn precisionRecall(expected: []const u32, actual: []const u32) PrecisionRecall {
    var expected_index: usize = 0;
    var actual_index: usize = 0;
    var matched: usize = 0;
    while (expected_index < expected.len and actual_index < actual.len) {
        if (expected[expected_index] == actual[actual_index]) {
            matched += 1;
            expected_index += 1;
            actual_index += 1;
        } else if (expected[expected_index] < actual[actual_index]) {
            expected_index += 1;
        } else {
            actual_index += 1;
        }
    }
    return .{
        .precision = if (actual.len == 0) if (expected.len == 0) 1 else 0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(actual.len)),
        .recall = if (expected.len == 0) if (actual.len == 0) 1 else 0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected.len)),
    };
}

fn f1(precision: f64, recall: f64) f64 {
    if (precision + recall == 0) return 0;
    return 2.0 * precision * recall / (precision + recall);
}

const TokenMetrics = struct { f1: f64, wer: f64 };

fn compareTokens(allocator: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8) !TokenMetrics {
    const expected = try tokenize(allocator, expected_text);
    defer allocator.free(expected);
    const actual = try tokenize(allocator, actual_text);
    defer allocator.free(actual);

    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    for (expected) |token| {
        const entry = try counts.getOrPut(token);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    var matched: usize = 0;
    for (actual) |token| {
        if (counts.getPtr(token)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                matched += 1;
            }
        }
    }
    const precision: f64 = if (actual.len == 0) if (expected.len == 0) 1.0 else 0.0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(actual.len));
    const recall: f64 = if (expected.len == 0) if (actual.len == 0) 1.0 else 0.0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected.len));
    const edits = try tokenEditDistance(allocator, expected, actual);
    return .{
        .f1 = f1(precision, recall),
        .wer = if (expected.len == 0) if (actual.len == 0) @as(f64, 0) else @as(f64, 1) else @as(f64, @floatFromInt(edits)) / @as(f64, @floatFromInt(expected.len)),
    };
}

fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
    while (iterator.next()) |token| try tokens.append(allocator, token);
    return tokens.toOwnedSlice(allocator);
}

fn tokenEditDistance(allocator: std.mem.Allocator, expected: []const []const u8, actual: []const []const u8) !usize {
    var previous = try allocator.alloc(usize, actual.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, actual.len + 1);
    defer allocator.free(current);
    for (previous, 0..) |*value, index| value.* = index;
    for (expected, 0..) |expected_token, expected_index| {
        current[0] = expected_index + 1;
        for (actual, 0..) |actual_token, actual_index| {
            const substitution = previous[actual_index] + @intFromBool(!std.mem.eql(u8, expected_token, actual_token));
            current[actual_index + 1] = @min(substitution, @min(current[actual_index] + 1, previous[actual_index + 1] + 1));
        }
        const swap = previous;
        previous = current;
        current = swap;
    }
    return previous[actual.len];
}

fn countBoundaryKind(boundaries: []const Boundary, kind: BoundaryKind) usize {
    var count: usize = 0;
    for (boundaries) |boundary| count += @intFromBool(boundary.kind == kind);
    return count;
}

fn countLineBoundaries(boundaries: []const Boundary) usize {
    var count: usize = 0;
    for (boundaries) |boundary| switch (boundary.kind) {
        .line_break, .block_break, .region_break => count += 1,
        else => {},
    };
    return count -| 1;
}

fn lineConfidence(result: *const Result, line: Line) f32 {
    const start: usize = @intCast(line.ordered_start);
    const end = start + @as(usize, @intCast(line.glyph_count));
    if (end <= start) return 0;
    var sum: f32 = 0;
    for (result.boundaries[start..end]) |boundary| sum += boundary.confidence;
    return sum / @as(f32, @floatFromInt(end - start));
}

fn endsInWhitespace(text: []const u8) bool {
    if (text.len == 0) return false;
    return std.ascii.isWhitespace(text[text.len - 1]);
}

fn trimTrailingSpaces(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0 and (output.items[output.items.len - 1] == ' ' or output.items[output.items.len - 1] == '\t')) _ = output.pop();
}

fn trimTrailingWhitespace(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) _ = output.pop();
}

fn unionBox(a: BBox, b: BBox) BBox {
    return .{
        .x0 = @min(a.x0, b.x0),
        .y0 = @min(a.y0, b.y0),
        .x1 = @max(a.x1, b.x1),
        .y1 = @max(a.y1, b.y1),
    };
}

fn testGlyph(text: []const u8, x: f64, y: f64, advance: f64) GlyphSpan {
    return .{
        .bbox = .{ .x0 = x, .y0 = y - 2, .x1 = x + advance, .y1 = y + 9 },
        .text_matrix = .{ 1, 0, 0, 1, x, y },
        .font_size = 12,
        .text = text,
        .advance = advance,
    };
}

test "glyph geometry reconstructs missing spaces and line breaks" {
    const glyphs = [_]GlyphSpan{
        testGlyph("Hello", 72, 700, 26),
        testGlyph("world", 102, 700, 27),
        testGlyph("Second", 72, 682, 36),
        testGlyph("line", 112, 682, 18),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "Helloworld\nSecondline");
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello world\nSecond line", result.text);
    try std.testing.expect(result.quality.quality_pass);
    try std.testing.expectEqual(BoundaryKind.space, result.boundaries[1].kind);
    try std.testing.expectEqual(BoundaryKind.line_break, result.boundaries[2].kind);
}

test "explicit and generated whitespace retain provenance" {
    var generated = testGlyph(" ", 98, 700, 4);
    generated.generated = true;
    const glyphs = [_]GlyphSpan{
        testGlyph("Hello", 72, 700, 26),
        generated,
        testGlyph("world", 102, 700, 27),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "Hello world");
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello world", result.text);
    try std.testing.expectEqual(BoundaryProvenance.tj_adjustment, result.boundaries[1].provenance);
}

test "quality comparison reports boundary line token and recall metrics" {
    const metrics = try compareAgainstReference(std.testing.allocator, "AlphaBetaGammaDelta", "Alpha Beta\nGamma Delta", "Alpha Beta\nGamma Delta");
    try std.testing.expectEqual(@as(?f64, 1), metrics.word_boundary_precision);
    try std.testing.expectEqual(@as(?f64, 1), metrics.word_boundary_recall);
    try std.testing.expectEqual(@as(?f64, 1), metrics.line_break_f1);
    try std.testing.expectEqual(@as(?f64, 1), metrics.token_f1);
    try std.testing.expectEqual(@as(?f64, 0), metrics.word_error_rate);
    try std.testing.expectApproxEqAbs(@as(f64, 1), metrics.raw_non_whitespace_recall, 0.0001);
}

test "quality gate reports extreme token and line rates" {
    const long_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const metrics = qualityForText(long_token, long_token);
    try std.testing.expect(metrics.max_token_bytes > 160);
    try std.testing.expectEqual(@as(f64, 1), metrics.extreme_token_length_rate);
    try std.testing.expect(!passesQualityGate(metrics, long_token.len));
}
