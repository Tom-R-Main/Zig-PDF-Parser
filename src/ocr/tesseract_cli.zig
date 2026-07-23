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
    var outcome = try recognizeRegionDetailed(allocator, input, config);
    defer outcome.deinit(allocator);

    return switch (outcome.status) {
        .completed, .empty => {
            const spans = outcome.spans;
            outcome.spans = &.{};
            return spans;
        },
        .unavailable => error.TesseractUnavailable,
        .timeout => error.TesseractTimeout,
        .invalid_output => error.InvalidOcrOutput,
        .failed => error.TesseractFailed,
        .not_invoked => error.TesseractFailed,
    };
}

pub fn recognizeRegionDetailed(
    allocator: std.mem.Allocator,
    input: types.OcrInput,
    config: types.OcrConfig,
) !types.RecognitionOutcome {
    if (input.pixel_width == 0 or input.pixel_height == 0) {
        return .{
            .status = .invalid_output,
            .diagnostic_code = .invalid_tesseract_output,
        };
    }

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

    const started_ns = runtime.nanoTimestamp();
    const result = runtime.runCapture(allocator, &argv, .{
        .stdout_limit = config.stdout_limit,
        .stderr_limit = config.stderr_limit,
        .timeout_ms = config.timeout_ms,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .status = .unavailable,
            .duration_ms = elapsedMs(started_ns),
            .diagnostic_code = .tesseract_unavailable,
        },
        error.Timeout => return .{
            .status = .timeout,
            .duration_ms = elapsedMs(started_ns),
            .diagnostic_code = .tesseract_timeout,
        },
        error.StreamTooLong => return .{
            .status = .invalid_output,
            .duration_ms = elapsedMs(started_ns),
            .diagnostic_code = .tesseract_output_limit,
        },
        else => return err,
    };
    defer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            return .{
                .status = .failed,
                .exit_code = code,
                .stderr = result.stderr,
                .duration_ms = elapsedMs(started_ns),
                .diagnostic_code = .tesseract_failed,
            };
        },
        else => return .{
            .status = .failed,
            .stderr = result.stderr,
            .duration_ms = elapsedMs(started_ns),
            .diagnostic_code = .tesseract_failed,
        },
    }

    const spans = tsv.parse(allocator, result.stdout, .{
        .page_index = input.page_index,
        .pdf_bbox = input.pdf_bbox,
        .pixel_width = input.pixel_width,
        .pixel_height = input.pixel_height,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{
            .status = .invalid_output,
            .stderr = result.stderr,
            .duration_ms = elapsedMs(started_ns),
            .diagnostic_code = .invalid_tesseract_output,
        },
    };

    return .{
        .status = if (spans.len > 0) .completed else .empty,
        .spans = spans,
        .stderr = result.stderr,
        .duration_ms = elapsedMs(started_ns),
    };
}

fn elapsedMs(started_ns: i128) u64 {
    const elapsed_ns = runtime.nanoTimestamp() - started_ns;
    return if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1_000_000)) else 0;
}

test "page segmentation mode renders tesseract number" {
    try std.testing.expectEqual(@as(u8, 6), types.PageSegMode.single_block.tesseractNumber());
    try std.testing.expectEqual(@as(u8, 11), types.PageSegMode.sparse_text.tesseractNumber());
}

test "detailed CLI outcome preserves failure status exit code and bounded stderr" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "pdf-parser-tesseract-failure-{x}.sh", .{runtime.nanoTimestamp()});
    defer runtime.deleteFileCwd(path);
    try writeExecutableScript(path,
        \\#!/bin/sh
        \\printf 'bounded diagnostic\n' >&2
        \\exit 7
        \\
    );
    var exec_buf: [144]u8 = undefined;
    const executable = try std.fmt.bufPrint(&exec_buf, "./{s}", .{path});

    var outcome = try recognizeRegionDetailed(allocator, testInput(), .{
        .executable = executable,
        .stderr_limit = 64,
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(types.AttemptStatus.failed, outcome.status);
    try std.testing.expectEqual(@as(?u8, 7), outcome.exit_code);
    try std.testing.expectEqual(types.DiagnosticCode.tesseract_failed, outcome.diagnostic_code.?);
    try std.testing.expect(std.mem.indexOf(u8, outcome.stderr, "bounded diagnostic") != null);
    try std.testing.expect(outcome.stderr.len <= 64);
}

test "detailed CLI outcome distinguishes a successful empty OCR result" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "pdf-parser-tesseract-empty-{x}.sh", .{runtime.nanoTimestamp()});
    defer runtime.deleteFileCwd(path);
    try writeExecutableScript(path,
        \\#!/bin/sh
        \\printf 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n'
        \\
    );
    var exec_buf: [144]u8 = undefined;
    const executable = try std.fmt.bufPrint(&exec_buf, "./{s}", .{path});

    var outcome = try recognizeRegionDetailed(allocator, testInput(), .{ .executable = executable });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(types.AttemptStatus.empty, outcome.status);
    try std.testing.expectEqual(@as(usize, 0), outcome.spans.len);
    try std.testing.expect(outcome.diagnostic_code == null);
}

test "detailed CLI outcome distinguishes timeout" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "pdf-parser-tesseract-timeout-{x}.sh", .{runtime.nanoTimestamp()});
    defer runtime.deleteFileCwd(path);
    try writeExecutableScript(path,
        \\#!/bin/sh
        \\sleep 1
        \\
    );
    var exec_buf: [144]u8 = undefined;
    const executable = try std.fmt.bufPrint(&exec_buf, "./{s}", .{path});

    var outcome = try recognizeRegionDetailed(allocator, testInput(), .{
        .executable = executable,
        .timeout_ms = 10,
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(types.AttemptStatus.timeout, outcome.status);
    try std.testing.expectEqual(types.DiagnosticCode.tesseract_timeout, outcome.diagnostic_code.?);
}

fn testInput() types.OcrInput {
    return .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
        .image_path = "unused.png",
        .pixel_width = 100,
        .pixel_height = 100,
    };
}

fn writeExecutableScript(path: []const u8, contents: []const u8) !void {
    runtime.deleteFileCwd(path);
    const file = try runtime.createFileCwd(path);
    try runtime.writeAllFile(file, contents);
    runtime.closeFile(file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", path }));
}
