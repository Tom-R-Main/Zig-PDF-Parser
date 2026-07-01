//! OCR adapter boundary for the adaptive parser.
//!
//! OCR engines are span producers. They receive an already-rasterized page or
//! region image and return `layout.TextSpan` values with explicit provenance.

const std = @import("std");
const layout = @import("layout.zig");
const complexity = @import("complexity.zig");

pub const types = @import("ocr/types.zig");
pub const tesseract_cli = @import("ocr/tesseract_cli.zig");
pub const tesseract_c = @import("ocr/tesseract_c.zig");
pub const tesseract_tsv = @import("ocr/tesseract_tsv.zig");

pub const Backend = types.Backend;
pub const PageSegMode = types.PageSegMode;
pub const OcrConfig = types.OcrConfig;
pub const OcrInput = types.OcrInput;

pub const OcrError = error{
    EmptyImage,
    InvalidTsvHeader,
    InvalidTsvRow,
    InvalidConfidence,
    InvalidCoordinate,
    ImageReadFailed,
    TesseractUnavailable,
    TesseractFailed,
    TesseractCBackendDisabled,
};

pub fn recognizeRegion(
    allocator: std.mem.Allocator,
    input: OcrInput,
    config: OcrConfig,
) ![]layout.TextSpan {
    return switch (config.backend) {
        .tesseract_cli => tesseract_cli.recognizeRegion(allocator, input, config),
        .tesseract_c => tesseract_c.recognizeRegion(allocator, input, config),
    };
}

pub fn recognizeRegionIfNeeded(
    allocator: std.mem.Allocator,
    input: OcrInput,
    config: OcrConfig,
    score: complexity.RegionScore,
) ![]layout.TextSpan {
    if (!score.route.needs_ocr) return allocator.alloc(layout.TextSpan, 0);
    return recognizeRegion(allocator, input, config);
}

pub fn freeSpans(allocator: std.mem.Allocator, spans: []layout.TextSpan) void {
    if (spans.len == 0) return;
    for (spans) |span| allocator.free(@constCast(span.text));
    allocator.free(spans);
}

test {
    _ = tesseract_cli;
    _ = tesseract_c;
    _ = tesseract_tsv;
}

test "OCR router skips regions that do not need OCR" {
    const spans = try recognizeRegionIfNeeded(std.testing.allocator, .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
        .image_path = "unused.png",
        .pixel_width = 100,
        .pixel_height = 100,
    }, .{}, .{
        .page_index = 0,
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
        .span_count = 1,
        .image_count = 0,
        .char_count = 10,
        .signals = .{},
        .route = .{ .native_fast_path = true, .needs_ocr = false },
    });
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
