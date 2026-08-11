const std = @import("std");
const runtime = @import("src/runtime.zig");
const testpdf = @import("src/testpdf.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const output_path = if (args.len > 1) args[1] else "test.pdf";

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello from zpdf!");
    defer allocator.free(pdf_data);

    const file = try runtime.createFileCwd(output_path);
    defer runtime.closeFile(file);
    try runtime.writeAllFile(file, pdf_data);

    std.debug.print("Generated {s} ({} bytes)\n", .{ output_path, pdf_data.len });
}
