//! Optional libtesseract C API backend.
//!
//! The default build does not import or link Tesseract. `build.zig` injects
//! `ocr_options.enable_tesseract_c`; only when that option is true do we import
//! Tesseract's C API and Leptonica.

const std = @import("std");
const layout = @import("../layout.zig");
const types = @import("types.zig");
const options = @import("ocr_options");

const enabled = if (options.enable_tesseract_c) struct {
    const c = @cImport({
        @cInclude("tesseract/capi.h");
        @cInclude("leptonica/allheaders.h");
    });
} else struct {};

pub const required_c_api = [_][]const u8{
    "TessVersion",
    "TessBaseAPICreate",
    "TessBaseAPIDelete",
    "TessBaseAPIInit3",
    "TessBaseAPISetPageSegMode",
    "TessBaseAPISetImage",
    "TessBaseAPISetSourceResolution",
    "TessBaseAPISetRectangle",
    "TessBaseAPIRecognize",
    "TessBaseAPIGetIterator",
    "TessPageIteratorBoundingBox",
    "TessResultIteratorGetUTF8Text",
    "TessResultIteratorConfidence",
    "TessResultIteratorWordFontAttributes",
    "TessResultIteratorNext",
    "TessDeleteText",
    "TessBaseAPIClear",
    "TessBaseAPIEnd",
};

pub fn recognizeRegion(
    allocator: std.mem.Allocator,
    input: types.OcrInput,
    config: types.OcrConfig,
) ![]layout.TextSpan {
    if (!options.enable_tesseract_c) {
        return error.TesseractCBackendDisabled;
    }
    return recognizeRegionEnabled(allocator, input, config);
}

pub fn version() ?[]const u8 {
    if (!options.enable_tesseract_c) return null;
    return std.mem.span(enabled.c.TessVersion());
}

test "C backend records the narrow intended API surface" {
    try std.testing.expectEqualStrings("TessVersion", required_c_api[0]);
    try std.testing.expectEqualStrings("TessBaseAPIEnd", required_c_api[required_c_api.len - 1]);
}

test "C backend is gated by build option" {
    if (options.enable_tesseract_c) {
        const version_text = version() orelse return error.TestUnexpectedResult;
        try std.testing.expect(version_text.len > 0);
    } else {
        const result = recognizeRegion(std.testing.allocator, .{
            .page_index = 0,
            .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
            .image_path = "unused.png",
            .pixel_width = 100,
            .pixel_height = 100,
        }, .{ .backend = .tesseract_c });
        try std.testing.expectError(error.TesseractCBackendDisabled, result);
    }
}

fn recognizeRegionEnabled(
    allocator: std.mem.Allocator,
    input: types.OcrInput,
    config: types.OcrConfig,
) ![]layout.TextSpan {
    if (!options.enable_tesseract_c) unreachable;
    const c = enabled.c;

    if (input.pixel_width == 0 or input.pixel_height == 0) return error.EmptyImage;

    const image_path_z = try allocator.dupeZ(u8, input.image_path);
    defer allocator.free(image_path_z);
    const lang_z = try allocator.dupeZ(u8, config.lang);
    defer allocator.free(lang_z);

    const api = c.TessBaseAPICreate() orelse return error.TesseractUnavailable;
    defer c.TessBaseAPIDelete(api);
    defer c.TessBaseAPIEnd(api);

    if (c.TessBaseAPIInit3(api, null, lang_z.ptr) != 0) return error.TesseractUnavailable;
    defer c.TessBaseAPIClear(api);

    c.TessBaseAPISetPageSegMode(api, @intCast(config.psm.tesseractNumber()));

    var pix = c.pixRead(image_path_z.ptr);
    if (pix == null) return error.ImageReadFailed;
    defer c.pixDestroy(&pix);

    c.TessBaseAPISetImage2(api, pix.?);
    c.TessBaseAPISetSourceResolution(api, @intCast(config.dpi));
    c.TessBaseAPISetRectangle(
        api,
        0,
        0,
        @intCast(input.pixel_width),
        @intCast(input.pixel_height),
    );

    if (c.TessBaseAPIRecognize(api, null) != 0) return error.TesseractFailed;

    const iterator = c.TessBaseAPIGetIterator(api) orelse {
        return allocator.alloc(layout.TextSpan, 0);
    };
    defer c.TessResultIteratorDelete(iterator);

    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }

    var block_id: u32 = 0;
    var line_id: u32 = 0;
    var have_position = false;
    while (true) {
        const page_iterator = c.TessResultIteratorGetPageIterator(iterator);
        if (page_iterator != null) {
            if (c.TessPageIteratorIsAtBeginningOf(page_iterator, c.RIL_BLOCK) != 0) {
                if (have_position) block_id += 1;
            }
            if (c.TessPageIteratorIsAtBeginningOf(page_iterator, c.RIL_TEXTLINE) != 0) {
                if (have_position) line_id += 1;
            }
        }
        have_position = true;

        try appendWordSpan(allocator, &spans, input, iterator, block_id, line_id);

        if (c.TessResultIteratorNext(iterator, c.RIL_WORD) == 0) break;
    }

    return spans.toOwnedSlice(allocator);
}

fn appendWordSpan(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    input: types.OcrInput,
    iterator: anytype,
    block_id: u32,
    line_id: u32,
) !void {
    const c = enabled.c;

    const text_ptr = c.TessResultIteratorGetUTF8Text(iterator, c.RIL_WORD) orelse return;
    defer c.TessDeleteText(text_ptr);

    const raw_text = std.mem.span(text_ptr);
    if (raw_text.len == 0) return;

    const page_iterator = c.TessResultIteratorGetPageIterator(iterator) orelse return;
    var left: c_int = 0;
    var top: c_int = 0;
    var right: c_int = 0;
    var bottom: c_int = 0;
    if (c.TessPageIteratorBoundingBox(page_iterator, c.RIL_WORD, &left, &top, &right, &bottom) == 0) return;
    if (right <= left or bottom <= top or left < 0 or top < 0) return;

    var is_bold: c_int = 0;
    var is_italic: c_int = 0;
    var is_underlined: c_int = 0;
    var is_monospace: c_int = 0;
    var is_serif: c_int = 0;
    var is_smallcaps: c_int = 0;
    var point_size: c_int = 0;
    var font_id: c_int = 0;
    _ = c.TessResultIteratorWordFontAttributes(
        iterator,
        &is_bold,
        &is_italic,
        &is_underlined,
        &is_monospace,
        &is_serif,
        &is_smallcaps,
        &point_size,
        &font_id,
    );

    const text = try allocator.dupe(u8, raw_text);
    errdefer allocator.free(text);

    const confidence = c.TessResultIteratorConfidence(iterator, c.RIL_WORD);
    try spans.append(allocator, layout.TextSpan.init(.{
        .page_index = input.page_index,
        .bbox = mapPixelBBox(
            input,
            @intCast(left),
            @intCast(top),
            @intCast(right - left),
            @intCast(bottom - top),
        ),
        .text = text,
        .source = .fresh_ocr,
        .confidence = @max(0.0, @min(1.0, confidence / 100.0)),
        .font = .{
            .size = if (point_size > 0) @floatFromInt(point_size) else 0,
            .encoding = "utf-8",
            .has_to_unicode = true,
        },
        .block_id = block_id,
        .line_id = line_id,
    }));
}

fn mapPixelBBox(input: types.OcrInput, left: u32, top: u32, width: u32, height: u32) layout.BBox {
    const pdf_width = input.pdf_bbox.x1 - input.pdf_bbox.x0;
    const pdf_height = input.pdf_bbox.y1 - input.pdf_bbox.y0;
    const x_scale = pdf_width / @as(f64, @floatFromInt(input.pixel_width));
    const y_scale = pdf_height / @as(f64, @floatFromInt(input.pixel_height));

    const x0 = input.pdf_bbox.x0 + @as(f64, @floatFromInt(left)) * x_scale;
    const x1 = x0 + @as(f64, @floatFromInt(width)) * x_scale;
    const y1 = input.pdf_bbox.y1 - @as(f64, @floatFromInt(top)) * y_scale;
    const y0 = y1 - @as(f64, @floatFromInt(height)) * y_scale;

    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x1,
        .y1 = y1,
    };
}
