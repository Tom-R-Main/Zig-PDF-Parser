//! Subprocess-backed Tesseract adapter.

const std = @import("std");
const layout = @import("../layout.zig");
const runtime = @import("../runtime.zig");
const tsv = @import("tesseract_tsv.zig");
const types = @import("types.zig");

pub fn recognizeRegion(
    allocator: std.mem.Allocator,
    input: types.OcrInput,
    config: types.OcrConfig,
) ![]layout.TextSpan {
    if (input.pixel_width == 0 or input.pixel_height == 0) return error.EmptyImage;

    const psm_arg = try std.fmt.allocPrint(allocator, "{d}", .{config.psm.tesseractNumber()});
    defer allocator.free(psm_arg);

    const dpi_arg = try std.fmt.allocPrint(allocator, "{d}", .{config.dpi});
    defer allocator.free(dpi_arg);

    const argv = [_][]const u8{
        config.executable,
        input.image_path,
        "stdout",
        "-l",
        config.lang,
        "--psm",
        psm_arg,
        "--dpi",
        dpi_arg,
        "tsv",
        "quiet",
    };

    const result = runtime.runCapture(allocator, &argv, .{
        .stdout_limit = config.stdout_limit,
        .stderr_limit = config.stderr_limit,
        .timeout_ms = config.timeout_ms,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.TesseractUnavailable,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.TesseractFailed,
        else => return error.TesseractFailed,
    }

    return tsv.parse(allocator, result.stdout, .{
        .page_index = input.page_index,
        .pdf_bbox = input.pdf_bbox,
        .pixel_width = input.pixel_width,
        .pixel_height = input.pixel_height,
    });
}

test "page segmentation mode renders tesseract number" {
    try std.testing.expectEqual(@as(u8, 6), types.PageSegMode.single_block.tesseractNumber());
    try std.testing.expectEqual(@as(u8, 11), types.PageSegMode.sparse_text.tesseractNumber());
}
