//! Cheap page and region complexity scoring for adaptive routing.
//!
//! This module is deliberately native-only: it consumes spans, font metadata,
//! and image boxes that the parser already extracted, then decides whether a
//! page/region should stay on the native path or be escalated to OCR, layout,
//! table, or formula specialists.

const std = @import("std");
const layout = @import("layout.zig");

pub const TextSpan = layout.TextSpan;
pub const BBox = layout.BBox;

pub const ImageBox = struct {
    bbox: BBox,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
};

pub const PageInput = struct {
    page_index: u32 = 0,
    bbox: BBox,
    spans: []const TextSpan = &.{},
    images: []const ImageBox = &.{},
    has_structure_tree: bool = false,
};

pub const SignalScores = struct {
    sparse_text: f32 = 0,
    image_dominance: f32 = 0,
    bad_unicode: f32 = 0,
    missing_tounicode: f32 = 0,
    hidden_ocr: f32 = 0,
    low_reading_order_confidence: f32 = 0,
    table_alignment: f32 = 0,
    formula_density: f32 = 0,

    pub fn max(self: SignalScores) f32 {
        var value = self.sparse_text;
        value = @max(value, self.image_dominance);
        value = @max(value, self.bad_unicode);
        value = @max(value, self.missing_tounicode);
        value = @max(value, self.hidden_ocr);
        value = @max(value, self.low_reading_order_confidence);
        value = @max(value, self.table_alignment);
        value = @max(value, self.formula_density);
        return value;
    }
};

pub const RouteDecision = struct {
    native_fast_path: bool = true,
    needs_ocr: bool = false,
    needs_layout_model: bool = false,
    needs_table_model: bool = false,
    needs_formula_model: bool = false,
    max_signal: f32 = 0,
};

pub const RegionScore = struct {
    page_index: u32,
    bbox: BBox,
    span_count: usize,
    image_count: usize,
    char_count: usize,
    signals: SignalScores,
    route: RouteDecision,
};

pub const PageScore = struct {
    page_index: u32,
    page_bbox: BBox,
    score: RegionScore,
};

pub fn scorePage(input: PageInput) PageScore {
    return .{
        .page_index = input.page_index,
        .page_bbox = input.bbox,
        .score = scoreRegion(input, input.bbox),
    };
}

pub fn scoreRegion(input: PageInput, region: BBox) RegionScore {
    var stats = RegionStats.init(input, region);
    stats.collect();

    const signals = SignalScores{
        .sparse_text = scoreSparseText(&stats),
        .image_dominance = scoreImageDominance(&stats),
        .bad_unicode = scoreBadUnicode(&stats),
        .missing_tounicode = scoreMissingToUnicode(&stats),
        .hidden_ocr = scoreHiddenOcr(&stats),
        .low_reading_order_confidence = scoreReadingOrder(input.has_structure_tree, &stats),
        .table_alignment = scoreTableAlignment(&stats),
        .formula_density = scoreFormulaDensity(&stats),
    };

    const route = decideRoute(signals, stats.span_count);
    return .{
        .page_index = input.page_index,
        .bbox = region,
        .span_count = stats.span_count,
        .image_count = stats.image_count,
        .char_count = stats.char_count,
        .signals = signals,
        .route = route,
    };
}

fn decideRoute(signals: SignalScores, span_count: usize) RouteDecision {
    var route = RouteDecision{ .max_signal = signals.max() };
    route.needs_ocr = span_count == 0 or
        signals.bad_unicode >= 0.35 or
        signals.hidden_ocr >= 0.45 or
        signals.image_dominance >= 0.65 or
        (signals.sparse_text >= 0.85 and signals.image_dominance >= 0.20);
    route.needs_table_model = signals.table_alignment >= 0.60;
    route.needs_formula_model = signals.formula_density >= 0.55;
    route.needs_layout_model = signals.low_reading_order_confidence >= 0.55 or
        signals.table_alignment >= 0.45 or
        signals.formula_density >= 0.45;
    route.native_fast_path = !route.needs_ocr and
        !route.needs_layout_model and
        !route.needs_table_model and
        !route.needs_formula_model and
        route.max_signal < 0.70;
    return route;
}

const RegionStats = struct {
    input: PageInput,
    region: BBox,
    region_area: f64,
    span_count: usize = 0,
    image_count: usize = 0,
    char_count: usize = 0,
    text_area: f64 = 0,
    image_area: f64 = 0,
    invalid_utf8_spans: usize = 0,
    replacement_chars: usize = 0,
    control_chars: usize = 0,
    known_tounicode_fonts: usize = 0,
    missing_tounicode_fonts: usize = 0,
    unknown_tounicode_fonts: usize = 0,
    hidden_ocr_spans: usize = 0,
    y_inversions: usize = 0,
    x_regressions: usize = 0,
    repeated_x_spans: usize = 0,
    numeric_chars: usize = 0,
    math_chars: usize = 0,
    superscript_like_spans: usize = 0,

    fn init(input: PageInput, region: BBox) RegionStats {
        return .{
            .input = input,
            .region = region,
            .region_area = @max(1.0, area(region)),
        };
    }

    fn collect(self: *RegionStats) void {
        self.collectSpans();
        self.collectImages();
    }

    fn collectSpans(self: *RegionStats) void {
        var prev_seen = false;
        var prev_y: f64 = 0;
        var prev_x: f64 = 0;
        var prev_font_size: f64 = 0;

        for (self.input.spans) |text_span| {
            if (!intersects(self.region, text_span.bbox)) continue;

            self.span_count += 1;
            self.char_count += text_span.text.len;
            self.text_area += clippedArea(self.region, text_span.bbox);
            self.repeated_x_spans += repeatedXContribution(self.input.spans, self.region, text_span);

            if (!std.unicode.utf8ValidateSlice(text_span.text)) self.invalid_utf8_spans += 1;
            self.replacement_chars += countNeedle(text_span.text, "\xEF\xBF\xBD");

            for (text_span.text) |byte| {
                if (byte >= '0' and byte <= '9') self.numeric_chars += 1;
                if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') self.control_chars += 1;
                if (isAsciiMathByte(byte)) self.math_chars += 1;
            }
            self.math_chars += countUnicodeMathSequences(text_span.text);

            if (text_span.font.has_to_unicode) |has_to_unicode| {
                if (has_to_unicode) {
                    self.known_tounicode_fonts += 1;
                } else {
                    self.missing_tounicode_fonts += 1;
                }
            } else {
                self.unknown_tounicode_fonts += 1;
            }

            if (text_span.font.name) |name| {
                if (looksLikeHiddenOcrFont(name)) self.hidden_ocr_spans += 1;
            }

            if (prev_seen) {
                const line_threshold = @max(3.0, @max(prev_font_size, text_span.font_size) * 0.75);
                if (text_span.y0 > prev_y + line_threshold) self.y_inversions += 1;
                if (@abs(text_span.y0 - prev_y) <= line_threshold and text_span.x0 + 2.0 < prev_x) self.x_regressions += 1;
                if (@abs(text_span.y0 - prev_y) <= line_threshold and text_span.font_size < prev_font_size * 0.82 and text_span.y0 > prev_y + prev_font_size * 0.15) {
                    self.superscript_like_spans += 1;
                }
            }

            prev_seen = true;
            prev_y = text_span.y0;
            prev_x = text_span.x0;
            prev_font_size = text_span.font_size;
        }
    }

    fn collectImages(self: *RegionStats) void {
        for (self.input.images) |image| {
            const clipped = clippedArea(self.region, image.bbox);
            if (clipped <= 0) continue;
            self.image_count += 1;
            self.image_area += clipped;
        }
    }
};

fn scoreSparseText(stats: *const RegionStats) f32 {
    if (stats.span_count == 0 or stats.char_count == 0) return 1.0;

    const char_density = @as(f64, @floatFromInt(stats.char_count)) / stats.region_area;
    const coverage = stats.text_area / stats.region_area;
    const density_score = 1.0 - clamp01(char_density / 0.0012);
    const coverage_score = 1.0 - clamp01(coverage / 0.08);
    const short_score = if (stats.char_count < 80)
        1.0 - (@as(f64, @floatFromInt(stats.char_count)) / 80.0)
    else
        0.0;
    return f32Clamp(@max(short_score, (density_score + coverage_score) / 2.0));
}

fn scoreImageDominance(stats: *const RegionStats) f32 {
    return f32Clamp(stats.image_area / stats.region_area);
}

fn scoreBadUnicode(stats: *const RegionStats) f32 {
    if (stats.span_count == 0 or stats.char_count == 0) return 0;
    const invalid_ratio = @as(f64, @floatFromInt(stats.invalid_utf8_spans)) / @as(f64, @floatFromInt(stats.span_count));
    const replacement_ratio = @as(f64, @floatFromInt(stats.replacement_chars * 3)) / @as(f64, @floatFromInt(stats.char_count));
    const control_ratio = @as(f64, @floatFromInt(stats.control_chars)) / @as(f64, @floatFromInt(stats.char_count));
    return f32Clamp(@max(invalid_ratio, @max(replacement_ratio * 3.0, control_ratio * 5.0)));
}

fn scoreMissingToUnicode(stats: *const RegionStats) f32 {
    const known_total = stats.known_tounicode_fonts + stats.missing_tounicode_fonts;
    if (known_total == 0) {
        if (stats.unknown_tounicode_fonts > 0) return 0.35;
        return 0;
    }
    const missing_ratio = @as(f64, @floatFromInt(stats.missing_tounicode_fonts)) / @as(f64, @floatFromInt(known_total));
    const unknown_penalty: f64 = if (stats.unknown_tounicode_fonts > 0) 0.15 else 0.0;
    return f32Clamp(missing_ratio + unknown_penalty);
}

fn scoreHiddenOcr(stats: *const RegionStats) f32 {
    if (stats.span_count == 0) return 0;
    return f32Clamp(@as(f64, @floatFromInt(stats.hidden_ocr_spans)) / @as(f64, @floatFromInt(stats.span_count)));
}

fn scoreReadingOrder(has_structure_tree: bool, stats: *const RegionStats) f32 {
    if (has_structure_tree or stats.span_count < 3) return 0;
    const transition_count = @as(f64, @floatFromInt(stats.span_count - 1));
    const inversion_ratio = @as(f64, @floatFromInt(stats.y_inversions + stats.x_regressions)) / transition_count;
    const overlap_pressure = clamp01(stats.text_area / stats.region_area / 0.45);
    return f32Clamp(@max(inversion_ratio * 2.0, overlap_pressure * 0.4));
}

fn scoreTableAlignment(stats: *const RegionStats) f32 {
    if (stats.span_count < 6) return 0;
    const repeated_ratio = @as(f64, @floatFromInt(stats.repeated_x_spans)) / @as(f64, @floatFromInt(stats.span_count));
    const numeric_ratio = if (stats.char_count > 0)
        @as(f64, @floatFromInt(stats.numeric_chars)) / @as(f64, @floatFromInt(stats.char_count))
    else
        0.0;
    const alignment_score = clamp01((repeated_ratio - 0.25) / 0.55);
    const numeric_score = clamp01((numeric_ratio - 0.20) / 0.45);
    return f32Clamp(@max(alignment_score, (alignment_score * 0.7) + (numeric_score * 0.3)));
}

fn scoreFormulaDensity(stats: *const RegionStats) f32 {
    if (stats.char_count == 0) return 0;
    const symbol_ratio = @as(f64, @floatFromInt(stats.math_chars)) / @as(f64, @floatFromInt(stats.char_count));
    const superscript_ratio = if (stats.span_count > 0)
        @as(f64, @floatFromInt(stats.superscript_like_spans)) / @as(f64, @floatFromInt(stats.span_count))
    else
        0.0;
    return f32Clamp(@max(clamp01((symbol_ratio - 0.08) / 0.30), superscript_ratio * 2.0));
}

fn repeatedXContribution(spans: []const TextSpan, region: BBox, text_span: TextSpan) usize {
    var aligned: usize = 0;
    const bucket = xBucket(text_span.x0);
    for (spans) |other| {
        if (!intersects(region, other.bbox)) continue;
        if (xBucket(other.x0) == bucket) aligned += 1;
    }
    return if (aligned >= 3) 1 else 0;
}

fn xBucket(x: f64) i64 {
    return @intFromFloat(@round(x / 8.0));
}

fn isAsciiMathByte(byte: u8) bool {
    return switch (byte) {
        '+', '-', '*', '/', '=', '<', '>', '^', '_', '|', '~', '(', ')', '[', ']' => true,
        else => false,
    };
}

fn countUnicodeMathSequences(text: []const u8) usize {
    const needles = [_][]const u8{
        "\xCE\xA3", // Sigma
        "\xCF\x83", // sigma
        "\xCE\xA0", // Pi
        "\xCF\x80", // pi
        "\xE2\x88\x91", // sum
        "\xE2\x88\xAB", // integral
        "\xE2\x88\x9A", // square root
        "\xE2\x89\xA4", // <=
        "\xE2\x89\xA5", // >=
        "\xE2\x89\x88", // approx
        "\xE2\x88\x9E", // infinity
    };

    var total: usize = 0;
    for (needles) |needle| total += countNeedle(text, needle);
    return total;
}

fn looksLikeHiddenOcrFont(name: []const u8) bool {
    const needles = [_][]const u8{
        "OCR",
        "GlyphLess",
        "Hidden",
        "Tesseract",
        "Invisible",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(name, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |needle_byte, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle_byte)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or needle.len > haystack.len) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[index..][0..needle.len], needle)) {
            count += 1;
            index += needle.len;
        } else {
            index += 1;
        }
    }
    return count;
}

fn intersects(a: BBox, b: BBox) bool {
    return intersection(a, b) != null;
}

fn clippedArea(a: BBox, b: BBox) f64 {
    if (intersection(a, b)) |box| return area(box);
    return 0;
}

fn intersection(a: BBox, b: BBox) ?BBox {
    const x0 = @max(a.x0, b.x0);
    const y0 = @max(a.y0, b.y0);
    const x1 = @min(a.x1, b.x1);
    const y1 = @min(a.y1, b.y1);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn area(box: BBox) f64 {
    return @max(0.0, box.x1 - box.x0) * @max(0.0, box.y1 - box.y0);
}

fn clamp01(value: f64) f64 {
    return @max(0.0, @min(1.0, value));
}

fn f32Clamp(value: f64) f32 {
    return @floatCast(clamp01(value));
}

fn span(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) TextSpan {
    return TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Helvetica", .size = 12, .has_to_unicode = true },
    });
}

test "clean born-digital page stays on native fast path" {
    const spans = [_]TextSpan{
        span("Introduction to parsing", 72, 700, 230, 714),
        span("This page has enough valid native text to avoid OCR routing.", 72, 680, 460, 694),
        span("The spans are in normal top-to-bottom reading order.", 72, 660, 420, 674),
        span("A final line keeps density above the sparse threshold.", 72, 640, 410, 654),
    };

    const page = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
    });

    try std.testing.expect(page.score.route.native_fast_path);
    try std.testing.expect(!page.score.route.needs_ocr);
    try std.testing.expect(page.score.signals.bad_unicode < 0.1);
}

test "image-dominant sparse region routes to OCR" {
    const spans = [_]TextSpan{
        span("1", 20, 20, 26, 32),
    };
    const images = [_]ImageBox{
        .{ .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 590, .y1 = 760 }, .pixel_width = 1600, .pixel_height = 2200 },
    };

    const page = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
        .images = &images,
    });

    try std.testing.expect(page.score.signals.sparse_text >= 0.85);
    try std.testing.expect(page.score.signals.image_dominance >= 0.65);
    try std.testing.expect(page.score.route.needs_ocr);
}

test "bad unicode and hidden OCR layer are OCR signals" {
    const spans = [_]TextSpan{
        TextSpan.init(.{
            .bbox = .{ .x0 = 72, .y0 = 700, .x1 = 200, .y1 = 714 },
            .text = "bad \xEF\xBF\xBD\xEF\xBF\xBD text",
            .font = .{ .name = "GlyphLessFont", .size = 12, .has_to_unicode = false },
        }),
    };

    const page = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
    });

    try std.testing.expect(page.score.signals.bad_unicode >= 0.35);
    try std.testing.expect(page.score.signals.hidden_ocr >= 0.9);
    try std.testing.expect(page.score.signals.missing_tounicode >= 0.9);
    try std.testing.expect(page.score.route.needs_ocr);
}

test "table-like alignment routes to table model without OCR" {
    const spans = [_]TextSpan{
        span("2019", 80, 700, 112, 714),
        span("100", 200, 700, 230, 714),
        span("2020", 80, 680, 112, 694),
        span("125", 200, 680, 230, 694),
        span("2021", 80, 660, 112, 674),
        span("140", 200, 660, 230, 674),
        span("2022", 80, 640, 112, 654),
        span("155", 200, 640, 230, 654),
    };

    const page = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
    });

    try std.testing.expect(page.score.signals.table_alignment >= 0.60);
    try std.testing.expect(page.score.route.needs_table_model);
    try std.testing.expect(!page.score.route.needs_ocr);
}

test "formula-like symbols route to formula model and region scoring isolates it" {
    const spans = [_]TextSpan{
        span("normal prose text for the paragraph", 72, 700, 280, 714),
        span("E = mc^2 + sqrt(x) / y", 310, 700, 470, 714),
        span("more prose continues below", 72, 680, 240, 694),
    };
    const input = PageInput{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
    };

    const formula_region = scoreRegion(input, .{ .x0 = 300, .y0 = 690, .x1 = 500, .y1 = 720 });
    const prose_region = scoreRegion(input, .{ .x0 = 50, .y0 = 670, .x1 = 290, .y1 = 720 });

    try std.testing.expect(formula_region.signals.formula_density >= 0.55);
    try std.testing.expect(formula_region.route.needs_formula_model);
    try std.testing.expect(prose_region.signals.formula_density < 0.55);
}

test "stream-order inversions reduce reading order confidence unless tagged" {
    const spans = [_]TextSpan{
        span("bottom first", 72, 500, 150, 514),
        span("top second", 72, 700, 150, 714),
        span("middle third", 72, 620, 160, 634),
    };

    const untagged = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
    });
    const tagged = scorePage(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .spans = &spans,
        .has_structure_tree = true,
    });

    try std.testing.expect(untagged.score.signals.low_reading_order_confidence >= 0.55);
    try std.testing.expect(untagged.score.route.needs_layout_model);
    try std.testing.expect(tagged.score.signals.low_reading_order_confidence == 0);
}
