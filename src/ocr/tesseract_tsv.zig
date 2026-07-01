//! Tesseract TSV to span conversion.

const std = @import("std");
const layout = @import("../layout.zig");

pub const ParseInput = struct {
    page_index: u32,
    pdf_bbox: layout.BBox,
    pixel_width: u32,
    pixel_height: u32,
};

const expected_header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext";

pub fn parse(
    allocator: std.mem.Allocator,
    tsv: []const u8,
    input: ParseInput,
) ![]layout.TextSpan {
    if (input.pixel_width == 0 or input.pixel_height == 0) return error.EmptyImage;

    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }

    var seen_header = false;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (!seen_header) {
            if (!std.mem.eql(u8, line, expected_header)) return error.InvalidTsvHeader;
            seen_header = true;
            continue;
        }

        const row = try parseRow(line);
        if (row.level != 5 or row.confidence < 0 or row.text.len == 0) continue;

        const text = try allocator.dupe(u8, row.text);
        errdefer allocator.free(text);

        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = input.page_index,
            .bbox = mapPixelBBox(input, row.left, row.top, row.width, row.height),
            .text = text,
            .source = .fresh_ocr,
            .confidence = @max(0.0, @min(1.0, row.confidence / 100.0)),
            .font = .{
                .name = "tesseract",
                .encoding = "utf-8",
                .has_to_unicode = true,
            },
            .block_id = row.block_num,
            .line_id = row.line_num,
        }));
    }

    if (!seen_header) return error.InvalidTsvHeader;
    return spans.toOwnedSlice(allocator);
}

const Row = struct {
    level: u8,
    block_num: u32,
    line_num: u32,
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    confidence: f32,
    text: []const u8,
};

fn parseRow(line: []const u8) !Row {
    var fields: [12][]const u8 = undefined;
    var rest = line;
    for (0..11) |field_index| {
        const tab_index = std.mem.indexOfScalar(u8, rest, '\t') orelse return error.InvalidTsvRow;
        fields[field_index] = rest[0..tab_index];
        rest = rest[tab_index + 1 ..];
    }
    fields[11] = rest;

    return .{
        .level = try parseUnsigned(u8, fields[0]),
        .block_num = try parseUnsigned(u32, fields[2]),
        .line_num = try parseUnsigned(u32, fields[4]),
        .left = try parseUnsigned(u32, fields[6]),
        .top = try parseUnsigned(u32, fields[7]),
        .width = try parseUnsigned(u32, fields[8]),
        .height = try parseUnsigned(u32, fields[9]),
        .confidence = std.fmt.parseFloat(f32, fields[10]) catch return error.InvalidConfidence,
        .text = fields[11],
    };
}

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch return error.InvalidCoordinate;
}

fn mapPixelBBox(input: ParseInput, left: u32, top: u32, width: u32, height: u32) layout.BBox {
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

fn freeTestSpans(spans: []layout.TextSpan) void {
    for (spans) |span| std.testing.allocator.free(@constCast(span.text));
    std.testing.allocator.free(spans);
}

test "parse tesseract TSV words into fresh OCR spans" {
    const tsv =
        expected_header ++ "\n" ++
        "1\t1\t0\t0\t0\t0\t0\t0\t1000\t2000\t-1\t\n" ++
        "5\t1\t2\t1\t3\t1\t100\t200\t300\t40\t87.5\tHello\n" ++
        "5\t1\t2\t1\t3\t2\t450\t200\t200\t40\t93\tworld\n";

    const spans = try parse(std.testing.allocator, tsv, .{
        .page_index = 4,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 500, .y1 = 1000 },
        .pixel_width = 1000,
        .pixel_height = 2000,
    });
    defer freeTestSpans(spans);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(layout.SourceKind.fresh_ocr, spans[0].source);
    try std.testing.expectEqual(@as(u32, 4), spans[0].page_index);
    try std.testing.expectEqualStrings("Hello", spans[0].text);
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), spans[0].confidence, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), spans[0].bbox.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 880), spans[0].bbox.y0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 200), spans[0].bbox.x1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 900), spans[0].bbox.y1, 0.001);
}

test "parse rejects TSV without standard header" {
    try std.testing.expectError(error.InvalidTsvHeader, parse(std.testing.allocator, "not-a-header\n", .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .pixel_width = 10,
        .pixel_height = 10,
    }));
}

test "parse skips empty and rejected word rows" {
    const tsv =
        expected_header ++ "\n" ++
        "5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t-1\tnoise\n" ++
        "5\t1\t1\t1\t1\t2\t0\t0\t10\t10\t80\t\n";

    const spans = try parse(std.testing.allocator, tsv, .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .pixel_width = 10,
        .pixel_height = 10,
    });
    defer freeTestSpans(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
