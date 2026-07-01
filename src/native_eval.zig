//! Native extraction correctness fixtures.
//!
//! This is intentionally small and synthetic: it protects kernel behavior that
//! is easy to regress while the real evaluation corpus is still being built.

const std = @import("std");
const runtime = @import("runtime.zig");
const pdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

const Fixture = struct {
    name: []const u8,
    generate: *const fn (std.mem.Allocator) anyerror![]u8,
    required: []const []const u8,
    forbidden: []const []const u8 = &.{},
};

fn extractFixture(allocator: std.mem.Allocator, fixture: Fixture) ![]u8 {
    const pdf_data = try fixture.generate(allocator);
    defer allocator.free(pdf_data);

    const doc = try pdf.Document.openFromMemory(allocator, pdf_data, pdf.ErrorConfig.strict());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try doc.extractAllText(runtime.arrayListWriter(&output, allocator));
    return output.toOwnedSlice(allocator);
}

fn expectFixture(allocator: std.mem.Allocator, fixture: Fixture) !void {
    const output = try extractFixture(allocator, fixture);
    defer allocator.free(output);

    for (fixture.required) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
    }

    for (fixture.forbidden) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, output, needle) == null);
    }
}

fn generateBadStartxrefPdf(allocator: std.mem.Allocator) ![]u8 {
    const data = try testpdf.generateMinimalPdf(allocator, "Recovered XRef");
    const marker = "startxref\n";
    if (std.mem.indexOf(u8, data, marker)) |marker_pos| {
        var pos = marker_pos + marker.len;
        while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') : (pos += 1) {
            data[pos] = '0';
        }
    }
    return data;
}

test "native eval fixtures extract expected text" {
    const fixtures = [_]Fixture{
        .{
            .name = "winansi-minimal",
            .generate = struct {
                fn generate(allocator: std.mem.Allocator) ![]u8 {
                    return testpdf.generateMinimalPdf(allocator, "Native Eval");
                }
            }.generate,
            .required = &.{"Native Eval"},
        },
        .{
            .name = "bad-startxref-recovery",
            .generate = generateBadStartxrefPdf,
            .required = &.{"Recovered XRef"},
        },
        .{
            .name = "tj-spacing",
            .generate = testpdf.generateTJPdf,
            .required = &.{ "Hello", "World" },
        },
        .{
            .name = "cid-tounicode",
            .generate = testpdf.generateCIDFontPdf,
            .required = &.{ "Hello", "中" },
        },
        .{
            .name = "simple-tounicode",
            .generate = testpdf.generateSimpleToUnicodePdf,
            .required = &.{"Ω"},
            .forbidden = &.{"A"},
        },
        .{
            .name = "incremental-latest-xref",
            .generate = testpdf.generateIncrementalPdf,
            .required = &.{"Updated Text"},
            .forbidden = &.{"Original Text"},
        },
        .{
            .name = "text-state-operators",
            .generate = testpdf.generateTextStatePdf,
            .required = &.{ "Line1\nLine2", "Line3\nLine4" },
            .forbidden = &.{"Outside"},
        },
    };

    for (fixtures) |fixture| {
        errdefer std.debug.print("native eval fixture failed: {s}\n", .{fixture.name});
        try expectFixture(std.testing.allocator, fixture);
    }
}

test "native eval bounds carry provenance and line movement" {
    const allocator = std.testing.allocator;
    const pdf_data = try testpdf.generateTextStatePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try pdf.Document.openFromMemory(allocator, pdf_data, pdf.ErrorConfig.strict());
    defer doc.close();

    const spans = try doc.extractTextWithBounds(0, allocator);
    defer pdf.Document.freeTextSpans(allocator, spans);

    try std.testing.expect(spans.len >= 4);
    try std.testing.expectEqual(pdf.layout.SourceKind.native_pdf, spans[0].source);
    try std.testing.expectEqual(@as(u32, 0), spans[0].page_index);

    var saw_later_line = false;
    for (spans) |span| {
        if (span.line_id != null and span.line_id.? > spans[0].line_id.?) {
            saw_later_line = true;
            break;
        }
    }
    try std.testing.expect(saw_later_line);
}
