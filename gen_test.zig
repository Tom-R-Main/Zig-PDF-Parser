const std = @import("std");
const runtime = @import("src/runtime.zig");
const testpdf = @import("src/testpdf.zig");

pub fn main() !void {
    var gpa = runtime.debugAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello from zpdf!");
    defer allocator.free(pdf_data);

    const file = try runtime.createFileCwd("test.pdf");
    defer runtime.closeFile(file);
    try runtime.writeAllFile(file, pdf_data);

    std.debug.print("Generated test.pdf ({} bytes)\n", .{pdf_data.len});
}
