//! pdf-parser CLI - Text extraction tool
//!
//! Usage: pdf-parser extract [options] input.pdf [pages]
//!        pdf-parser inspect complexity [options] input.pdf
//!        pdf-parser info input.pdf
//!        pdf-parser bench input.pdf
//!
//! Designed to be a drop-in comparison with `mutool draw -F txt`

const std = @import("std");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "extract")) {
        try runExtract(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "inspect")) {
        try runInspect(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "info")) {
        try runInfo(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "search")) {
        try runSearch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "bench")) {
        try runBench(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
    }
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var bw = runtime.stdoutWriter(&buf);
    const stdout = &bw.interface;
    defer stdout.flush() catch {};
    try stdout.writeAll(
        \\pdf-parser - Zero-copy PDF text extraction
        \\
        \\Usage: pdf-parser <command> [options] <input.pdf> [pages]
        \\
        \\Commands:
        \\  extract     Extract text from PDF (like mutool draw -F txt)
        \\  inspect     Inspect parser decisions and document signals
        \\  info        Show PDF structure information (metadata, outline, etc.)
        \\  search      Search for text across all pages
        \\  bench       Benchmark extraction performance
        \\  help        Show this help
        \\
        \\Extract options:
        \\  -o FILE         Output to file (default: stdout)
        \\  -p PAGES        Page range (e.g., "1-10" or "1,3,5")
        \\  -f, --format    Output format: text, markdown, json, jsonl, rag-jsonl, hocr, alto, or debug-svg
        \\  -m, --markdown  Shortcut for --format markdown
        \\  --adaptive      Use adaptive routing and reconciled outputs
        \\  --trace         Emit adaptive route trace JSON
        \\  --sequential    Disable parallel extraction
        \\  --reading-order Use visual reading order (experimental, slower)
        \\  --strict        Fail on any parse error
        \\  --permissive    Continue past all errors
        \\  --json          Shortcut for --format json
        \\
        \\Examples:
        \\  pdf-parser extract document.pdf              # All pages to stdout
        \\  pdf-parser extract -o out.txt document.pdf   # All pages to file
        \\  pdf-parser extract -p 1-10 document.pdf      # First 10 pages
        \\  pdf-parser extract --markdown doc.pdf        # Export as Markdown
        \\  pdf-parser extract -f md -o out.md doc.pdf   # Markdown to file
        \\  pdf-parser extract --adaptive -f rag-jsonl doc.pdf
        \\  pdf-parser extract --adaptive -f debug-svg doc.pdf
        \\  pdf-parser extract doc.pdf --adaptive --trace
        \\  pdf-parser inspect complexity doc.pdf --format json
        \\  pdf-parser extract --reading-order doc.pdf   # Visual reading order
        \\  pdf-parser search "revenue" document.pdf      # Search across all pages
        \\  pdf-parser bench document.pdf                # Benchmark vs mutool
        \\
    );
}

const ExtractionMode = enum {
    normal, // Default: use structure tree for reading order (falls back to stream order)
    visual, // Use visual layout analysis for reading order (experimental)
};

const OutputFormat = enum {
    text, // Plain text (default)
    json, // JSON with positions
    jsonl, // JSON Lines with reconciled spans
    rag_jsonl, // JSON Lines with RAG chunks
    markdown, // Markdown with headings, lists, etc.
    hocr, // hOCR-like HTML coordinates
    alto, // ALTO-like XML coordinates
    debug_svg, // SVG block overlay
};

fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var output_format: OutputFormat = .text;
    var sequential = false;
    var extraction_mode: ExtractionMode = .normal;
    var adaptive = false;
    var trace = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--strict")) {
            error_mode = zpdf.ErrorConfig.strict();
        } else if (std.mem.eql(u8, arg, "--permissive")) {
            error_mode = zpdf.ErrorConfig.permissive();
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "--markdown") or std.mem.eql(u8, arg, "-m")) {
            output_format = .markdown;
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) {
                output_format = parseOutputFormat(args[i]) orelse {
                    std.debug.print("Unknown format: {s}. Use text, markdown, json, jsonl, rag-jsonl, hocr, alto, or debug-svg.\n", .{args[i]});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--adaptive")) {
            adaptive = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            trace = true;
        } else if (std.mem.eql(u8, arg, "--sequential")) {
            sequential = true;
        } else if (std.mem.eql(u8, arg, "--reading-order")) {
            extraction_mode = .visual;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_file = arg;
        }
    }

    const path = input_file orelse {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    };

    if (!adaptive and !isLegacyOutputFormat(output_format)) {
        std.debug.print("Format {s} requires --adaptive.\n", .{outputFormatName(output_format)});
        return;
    }

    if (trace and !adaptive) {
        std.debug.print("--trace requires --adaptive.\n", .{});
        return;
    }

    // Open document
    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    // Warn about encrypted PDFs
    if (doc.isEncrypted()) {
        std.debug.print("Warning: {s} is encrypted. Text extraction may produce incorrect results.\n", .{path});
    }

    // Setup output
    const output_handle = if (output_file) |out_path|
        runtime.createFileCwd(out_path) catch |err| {
            std.debug.print("Error creating {s}: {}\n", .{ out_path, err });
            return;
        }
    else
        null;
    defer if (output_handle) |h| runtime.closeFile(h);

    // Parse page range
    const pages = parsePageRange(allocator, page_range, doc.pages.items.len) catch |err| {
        std.debug.print("Error parsing page range: {}\n", .{err});
        return;
    };
    defer allocator.free(pages);

    if (adaptive) {
        try doAdaptiveExtract(doc, pages, output_format, trace, allocator, output_handle);
        return;
    }

    // Use parallel structured extraction for all pages (text mode only, normal mode)
    const use_parallel = !sequential and output_format == .text and page_range == null and extraction_mode == .normal;

    // Use buffered output
    var write_buf: [4096]u8 = undefined;

    // Handle markdown format separately (extracts all at once)
    if (output_format == .markdown and page_range == null) {
        const result = doc.extractAllMarkdown(allocator) catch |err| {
            std.debug.print("Error during markdown extraction: {}\n", .{err});
            return;
        };
        defer allocator.free(result);

        if (output_handle) |h| {
            runtime.writeAllFile(h, result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        } else {
            runtime.writeAllStdout(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        }
    } else if (use_parallel) {
        // Structure tree extraction (uses stream order as fallback)
        const result = doc.extractAllTextStructured(allocator) catch |err| {
            std.debug.print("Error during structured extraction: {}\n", .{err});
            return;
        };
        defer allocator.free(result);

        if (output_handle) |h| {
            runtime.writeAllFile(h, result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        } else {
            runtime.writeAllStdout(result) catch |err| {
                std.debug.print("Error writing output: {}\n", .{err});
                return;
            };
        }
    } else if (output_handle) |h| {
        var file_writer = runtime.fileWriter(h, &write_buf);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, output_format, extraction_mode, allocator, writer);
    } else {
        var stdout_writer = runtime.stdoutWriter(&write_buf);
        const writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        try doExtract(doc, pages, output_format, extraction_mode, allocator, writer);
    }

    // Report errors if any
    if (doc.errors.items.len > 0) {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_bw = runtime.stderrWriter(&stderr_buf);
        const stderr = &stderr_bw.interface;
        defer stderr.flush() catch {};
        try stderr.print("\nWarning: {} errors encountered during extraction\n", .{doc.errors.items.len});
        for (doc.errors.items[0..@min(10, doc.errors.items.len)]) |err| {
            try stderr.print("  - {s} at offset {}\n", .{ err.message, err.offset });
        }
        if (doc.errors.items.len > 10) {
            try stderr.print("  ... and {} more\n", .{doc.errors.items.len - 10});
        }
    }
}

fn doExtract(doc: *zpdf.Document, pages: []const usize, output_format: OutputFormat, extraction_mode: ExtractionMode, allocator: std.mem.Allocator, writer: anytype) !void {
    if (output_format == .json) {
        try writer.writeAll("{\n");

        // Metadata
        const meta = doc.metadata();
        try writer.writeAll("  \"metadata\": {");
        var meta_first = true;
        inline for (.{
            .{ "title", meta.title },
            .{ "author", meta.author },
            .{ "subject", meta.subject },
            .{ "keywords", meta.keywords },
            .{ "creator", meta.creator },
            .{ "producer", meta.producer },
            .{ "creation_date", meta.creation_date },
            .{ "mod_date", meta.mod_date },
        }) |pair| {
            if (pair[1]) |val| {
                if (!meta_first) try writer.writeAll(",");
                try writer.print("\n    \"{s}\": \"", .{pair[0]});
                try writeJsonEscapedString(writer, val);
                try writer.writeAll("\"");
                meta_first = false;
            }
        }
        if (!meta_first) try writer.writeAll("\n  ");
        try writer.writeAll("},\n");

        // Page count
        try writer.print("  \"page_count\": {},\n", .{doc.pages.items.len});

        // Outline
        const outline_items = doc.getOutline(allocator) catch &.{};
        defer if (outline_items.len > 0) {
            for (outline_items) |item| {
                allocator.free(@constCast(item.title));
            }
            allocator.free(outline_items);
        };

        try writer.writeAll("  \"outline\": [");
        for (outline_items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("\n    {\"title\": \"");
            try writeJsonEscapedString(writer, item.title);
            try writer.print("\", \"page\": {}, \"level\": {}}}", .{
                if (item.page) |p| @as(i32, @intCast(p)) else @as(i32, -1),
                item.level,
            });
        }
        if (outline_items.len > 0) try writer.writeAll("\n  ");
        try writer.writeAll("],\n");

        // Pages
        try writer.writeAll("  \"pages\": [\n");
    }

    for (pages, 0..) |page_num, idx| {
        if (output_format == .json) {
            if (idx > 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.print("      \"page\": {}", .{page_num + 1});

            // Page label
            if (doc.getPageLabel(allocator, page_num)) |label| {
                defer allocator.free(label);
                try writer.writeAll(",\n      \"label\": \"");
                try writeJsonEscapedString(writer, label);
                try writer.writeAll("\"");
            }

            try writer.writeAll(",\n      \"text\": \"");
        }

        switch (output_format) {
            .markdown => {
                const text = doc.extractMarkdown(page_num, allocator) catch |err| {
                    std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                    continue;
                };
                defer allocator.free(text);
                try writer.writeAll(text);
                if (idx + 1 < pages.len) {
                    try writer.writeAll("\n---\n\n");
                }
            },
            .json, .text => {
                const text = switch (extraction_mode) {
                    .normal => doc.extractTextStructured(page_num, allocator) catch |err| {
                        std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                        continue;
                    },
                    .visual => extractPageReadingOrder(doc, page_num, allocator) catch |err| {
                        std.debug.print("Error extracting page {}: {}\n", .{ page_num + 1, err });
                        continue;
                    },
                };
                defer allocator.free(text);

                if (output_format == .json) {
                    try writeJsonEscapedString(writer, text);
                    try writer.writeAll("\"");

                    // Links for this page
                    try writer.writeAll(",\n      \"links\": [");
                    if (doc.getPageLinks(page_num, allocator)) |links| {
                        defer zpdf.Document.freeLinks(allocator, links);
                        for (links, 0..) |link, li| {
                            if (li > 0) try writer.writeAll(",");
                            try writer.writeAll("\n        {");
                            if (link.uri) |uri| {
                                try writer.writeAll("\"uri\": \"");
                                try writeJsonEscapedString(writer, uri);
                                try writer.writeAll("\", ");
                            }
                            if (link.dest_page) |dp| {
                                try writer.print("\"dest_page\": {}, ", .{dp});
                            }
                            try writer.print("\"rect\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}]}}", .{
                                link.rect[0], link.rect[1], link.rect[2], link.rect[3],
                            });
                        }
                        if (links.len > 0) try writer.writeAll("\n      ");
                    } else |_| {}
                    try writer.writeAll("]");

                    // Images for this page
                    try writer.writeAll(",\n      \"images\": [");
                    if (doc.getPageImages(page_num, allocator)) |images| {
                        defer zpdf.Document.freeImages(allocator, images);
                        for (images, 0..) |img, ii| {
                            if (ii > 0) try writer.writeAll(",");
                            try writer.print("\n        {{\"rect\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}], \"width\": {}, \"height\": {}}}", .{
                                img.rect[0], img.rect[1], img.rect[2], img.rect[3],
                                img.width,   img.height,
                            });
                        }
                        if (images.len > 0) try writer.writeAll("\n      ");
                    } else |_| {}
                    try writer.writeAll("]");

                    try writer.writeAll("\n    }");
                } else if (idx + 1 < pages.len) {
                    try writer.writeAll(text);
                    try writer.writeByte('\x0c');
                } else {
                    try writer.writeAll(text);
                }
            },
            .jsonl, .rag_jsonl, .hocr, .alto, .debug_svg => unreachable,
        }
    }

    if (output_format == .json) {
        try writer.writeAll("\n  ]\n}\n");
    }
}

fn doAdaptiveExtract(
    doc: *zpdf.Document,
    pages: []const usize,
    output_format: OutputFormat,
    trace: bool,
    allocator: std.mem.Allocator,
    output_handle: ?runtime.File,
) !void {
    const window = contiguousPageWindow(pages) catch |err| {
        std.debug.print("Error: --adaptive currently requires a contiguous page range: {}\n", .{err});
        return;
    };

    var result = doc.extractAdaptive(allocator, .{
        .page_start = window.start,
        .page_end = window.end,
    }) catch |err| {
        std.debug.print("Error during adaptive extraction: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const rendered = if (trace)
        renderAdaptiveTraceJson(allocator, &result) catch |err| {
            std.debug.print("Error rendering adaptive trace: {}\n", .{err});
            return;
        }
    else
        result.render(allocator, toAdaptiveOutputFormat(output_format)) catch |err| {
            std.debug.print("Error rendering adaptive output as {s}: {}\n", .{ outputFormatName(output_format), err });
            return;
        };
    defer allocator.free(rendered);

    if (output_handle) |h| {
        runtime.writeAllFile(h, rendered) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            return;
        };
    } else {
        runtime.writeAllStdout(rendered) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            return;
        };
    }
}

fn runInspect(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: pdf-parser inspect complexity [--format json] <input.pdf>\n", .{});
        return;
    }

    const subject = args[0];
    if (!std.mem.eql(u8, subject, "complexity")) {
        std.debug.print("Unknown inspect subject: {s}. Use complexity.\n", .{subject});
        return;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var format: []const u8 = "json";
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) format = args[i];
        } else if (std.mem.eql(u8, arg, "--strict")) {
            error_mode = zpdf.ErrorConfig.strict();
        } else if (std.mem.eql(u8, arg, "--permissive")) {
            error_mode = zpdf.ErrorConfig.permissive();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_file = arg;
        }
    }

    if (!std.mem.eql(u8, format, "json")) {
        std.debug.print("inspect complexity currently supports only --format json.\n", .{});
        return;
    }

    const path = input_file orelse {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    };

    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    const pages = parsePageRange(allocator, page_range, doc.pages.items.len) catch |err| {
        std.debug.print("Error parsing page range: {}\n", .{err});
        return;
    };
    defer allocator.free(pages);

    const window = contiguousPageWindow(pages) catch |err| {
        std.debug.print("Error: inspect complexity currently requires a contiguous page range: {}\n", .{err});
        return;
    };

    var result = doc.extractAdaptive(allocator, .{
        .page_start = window.start,
        .page_end = window.end,
    }) catch |err| {
        std.debug.print("Error inspecting complexity: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const rendered = renderComplexityJson(allocator, &result) catch |err| {
        std.debug.print("Error rendering complexity JSON: {}\n", .{err});
        return;
    };
    defer allocator.free(rendered);

    if (output_file) |out_path| {
        const output_handle = runtime.createFileCwd(out_path) catch |err| {
            std.debug.print("Error creating {s}: {}\n", .{ out_path, err });
            return;
        };
        defer runtime.closeFile(output_handle);
        runtime.writeAllFile(output_handle, rendered) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            return;
        };
    } else {
        runtime.writeAllStdout(rendered) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            return;
        };
    }
}

fn parseOutputFormat(fmt: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, fmt, "text") or std.mem.eql(u8, fmt, "txt")) return .text;
    if (std.mem.eql(u8, fmt, "json")) return .json;
    if (std.mem.eql(u8, fmt, "jsonl")) return .jsonl;
    if (std.mem.eql(u8, fmt, "rag-jsonl") or std.mem.eql(u8, fmt, "rag_jsonl")) return .rag_jsonl;
    if (std.mem.eql(u8, fmt, "markdown") or std.mem.eql(u8, fmt, "md")) return .markdown;
    if (std.mem.eql(u8, fmt, "hocr")) return .hocr;
    if (std.mem.eql(u8, fmt, "alto")) return .alto;
    if (std.mem.eql(u8, fmt, "debug-svg") or std.mem.eql(u8, fmt, "debug_svg")) return .debug_svg;
    return null;
}

fn outputFormatName(output_format: OutputFormat) []const u8 {
    return switch (output_format) {
        .text => "text",
        .json => "json",
        .jsonl => "jsonl",
        .rag_jsonl => "rag-jsonl",
        .markdown => "markdown",
        .hocr => "hocr",
        .alto => "alto",
        .debug_svg => "debug-svg",
    };
}

fn isLegacyOutputFormat(output_format: OutputFormat) bool {
    return switch (output_format) {
        .text, .json, .markdown => true,
        .jsonl, .rag_jsonl, .hocr, .alto, .debug_svg => false,
    };
}

fn toAdaptiveOutputFormat(output_format: OutputFormat) zpdf.AdaptiveOutputFormat {
    return switch (output_format) {
        .text => .text,
        .json => .json,
        .jsonl => .jsonl,
        .rag_jsonl => .rag_jsonl,
        .markdown => .markdown,
        .hocr => .hocr,
        .alto => .alto,
        .debug_svg => .debug_svg,
    };
}

fn renderComplexityJson(allocator: std.mem.Allocator, result: *const zpdf.AdaptiveResult) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\n  \"pages\": [");
    for (result.page_routes, 0..) |route, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writePageRouteJson(writer, route);
    }
    if (result.page_routes.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n  \"regions\": [");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeRegionRouteJson(writer, route);
    }
    if (result.region_routes.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");

    return output.toOwnedSlice(allocator);
}

fn renderAdaptiveTraceJson(allocator: std.mem.Allocator, result: *const zpdf.AdaptiveResult) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\n  \"pages\": [");
    for (result.page_routes, 0..) |route, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writePageRouteJson(writer, route);
    }
    if (result.page_routes.len > 0) try writer.writeAll("\n  ");

    try writer.writeAll("],\n  \"regions\": [");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeRegionRouteJson(writer, route);
    }
    if (result.region_routes.len > 0) try writer.writeAll("\n  ");

    try writer.writeAll("],\n  \"trace\": [");
    for (result.trace_records, 0..) |record, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeTraceRecordJson(writer, record);
    }
    if (result.trace_records.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]\n}\n");

    return output.toOwnedSlice(allocator);
}

fn writePageRouteJson(writer: anytype, route: zpdf.AdaptivePageRoute) !void {
    try writer.writeAll("{");
    try writer.print("\"page_index\":{},", .{route.page_index});
    try writer.print("\"span_count\":{},\"image_count\":{},\"char_count\":{},", .{
        route.span_count,
        route.image_count,
        route.char_count,
    });
    try writer.writeAll("\"route\":\"");
    try writer.writeAll(routeName(route.route));
    try writer.writeAll("\",");
    try writer.print("\"confidence\":{d:.3},", .{routeConfidence(route.route)});
    try writer.writeAll("\"reasons\":");
    try writeReasonArray(writer, route.reason_mask);
    try writer.writeAll(",\"signals\":");
    try writeSignalsJson(writer, route.signals);
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, route.bbox);
    try writer.writeAll("}");
}

fn writeRegionRouteJson(writer: anytype, route: zpdf.AdaptiveRegionRoute) !void {
    try writer.writeAll("{");
    try writer.print("\"page_index\":{},\"region_index\":{},", .{ route.page_index, route.region_index });
    if (route.layout_block_index) |layout_block_index| {
        try writer.print("\"layout_block_index\":{},", .{layout_block_index});
    }
    if (route.block_kind) |block_kind| {
        try writer.writeAll("\"block_kind\":\"");
        try writer.writeAll(blockKindName(block_kind));
        try writer.writeAll("\",");
    }
    try writer.print("\"span_count\":{},\"image_count\":{},\"char_count\":{},", .{
        route.span_count,
        route.image_count,
        route.char_count,
    });
    try writer.writeAll("\"route\":\"");
    try writer.writeAll(routeName(route.route));
    try writer.writeAll("\",");
    try writer.print("\"confidence\":{d:.3},", .{routeConfidence(route.route)});
    try writer.writeAll("\"reasons\":");
    try writeReasonArray(writer, route.reason_mask);
    try writer.writeAll(",\"signals\":");
    try writeSignalsJson(writer, route.signals);
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, route.bbox);
    try writer.writeAll("}");
}

fn writeTraceRecordJson(writer: anytype, record: zpdf.AdaptiveTraceRecord) !void {
    try writer.writeAll("{");
    try writer.print("\"page_index\":{},", .{record.page_index});
    if (record.region_index) |region_index| {
        try writer.print("\"region_index\":{},", .{region_index});
    } else {
        try writer.writeAll("\"region_index\":null,");
    }
    try writer.writeAll("\"stage\":\"");
    try writer.writeAll(traceStageName(record.stage));
    try writer.writeAll("\",");
    try writer.print("\"span_count\":{},\"block_count\":{},", .{ record.span_count, record.block_count });
    try writer.writeAll("\"route\":\"");
    try writer.writeAll(routeName(record.route));
    try writer.writeAll("\",");
    try writer.print("\"confidence\":{d:.3},", .{routeConfidence(record.route)});
    try writer.writeAll("\"reasons\":");
    try writeReasonArray(writer, record.reason_mask);
    try writer.writeAll("}");
}

fn writeSignalsJson(writer: anytype, signals: zpdf.adaptive.SignalScores) !void {
    try writer.print(
        "{{\"sparse_text\":{d:.3},\"image_dominant\":{d:.3},\"bad_unicode\":{d:.3},\"missing_tounicode\":{d:.3},\"hidden_ocr\":{d:.3},\"low_reading_order_confidence\":{d:.3},\"table_alignment\":{d:.3},\"formula_density\":{d:.3}}}",
        .{
            signals.sparse_text,
            signals.image_dominance,
            signals.bad_unicode,
            signals.missing_tounicode,
            signals.hidden_ocr,
            signals.low_reading_order_confidence,
            signals.table_alignment,
            signals.formula_density,
        },
    );
}

fn writeBBoxJson(writer: anytype, bbox: zpdf.adaptive.BBox) !void {
    try writer.print("{{\"x0\":{d:.2},\"y0\":{d:.2},\"x1\":{d:.2},\"y1\":{d:.2}}}", .{
        bbox.x0,
        bbox.y0,
        bbox.x1,
        bbox.y1,
    });
}

fn writeReasonArray(writer: anytype, mask: zpdf.adaptive.RouteReasonMask) !void {
    const reasons = [_]zpdf.adaptive.RouteReason{
        .native_fast_path,
        .sparse_text,
        .image_dominance,
        .bad_unicode,
        .missing_tounicode,
        .hidden_ocr,
        .low_reading_order_confidence,
        .table_alignment,
        .formula_density,
        .ocr_route_stub,
        .layout_route_stub,
        .table_route_stub,
        .formula_route_stub,
    };

    try writer.writeByte('[');
    var first = true;
    for (reasons) |reason| {
        if (!zpdf.adaptive.hasReason(mask, reason)) continue;
        if (!first) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(reasonName(reason));
        try writer.writeByte('"');
        first = false;
    }
    try writer.writeByte(']');
}

fn routeName(route: zpdf.adaptive.RouteDecision) []const u8 {
    if (route.native_fast_path) return "use_native";
    if (route.needs_ocr) return "queue_ocr";
    if (route.needs_table_model and route.needs_formula_model) return "candidate_table_formula";
    if (route.needs_table_model) return "candidate_table";
    if (route.needs_formula_model) return "candidate_formula";
    if (route.needs_layout_model) return "candidate_layout";
    return "review";
}

fn routeConfidence(route: zpdf.adaptive.RouteDecision) f32 {
    const signal = @max(0.0, @min(1.0, route.max_signal));
    if (route.native_fast_path) return 1.0 - signal;
    return signal;
}

fn reasonName(reason: zpdf.adaptive.RouteReason) []const u8 {
    return switch (reason) {
        .native_fast_path => "native_fast_path",
        .sparse_text => "sparse_text",
        .image_dominance => "image_dominant",
        .bad_unicode => "bad_unicode",
        .missing_tounicode => "missing_tounicode",
        .hidden_ocr => "hidden_ocr",
        .low_reading_order_confidence => "low_reading_order_confidence",
        .table_alignment => "table_alignment",
        .formula_density => "formula_density",
        .ocr_route_stub => "ocr_route_stub",
        .layout_route_stub => "layout_route_stub",
        .table_route_stub => "table_route_stub",
        .formula_route_stub => "formula_route_stub",
    };
}

fn traceStageName(stage: zpdf.adaptive.TraceStage) []const u8 {
    return switch (stage) {
        .native_spans => "native_spans",
        .layout_blocks => "layout_blocks",
        .complexity_score => "complexity_score",
        .route_decision => "route_decision",
        .ocr_route_stub => "ocr_route_stub",
        .table_route_stub => "table_route_stub",
        .formula_route_stub => "formula_route_stub",
        .reconcile => "reconcile",
        .output_ready => "output_ready",
    };
}

fn blockKindName(kind: zpdf.BlockKind) []const u8 {
    return switch (kind) {
        .paragraph => "paragraph",
        .heading => "heading",
        .list_item => "list_item",
        .header => "header",
        .footer => "footer",
        .caption => "caption",
        .table_candidate => "table_candidate",
        .formula_candidate => "formula_candidate",
        .figure_candidate => "figure_candidate",
    };
}

const PageWindow = struct {
    start: ?usize,
    end: ?usize,
};

fn contiguousPageWindow(pages: []const usize) !PageWindow {
    if (pages.len == 0) return .{ .start = 0, .end = 0 };

    const start = pages[0];
    for (pages, 0..) |page, index| {
        if (page != start + index) return error.NonContiguousPageRange;
    }

    return .{
        .start = start,
        .end = start + pages.len,
    };
}

test "parse adaptive output formats" {
    try std.testing.expectEqual(OutputFormat.text, parseOutputFormat("text").?);
    try std.testing.expectEqual(OutputFormat.text, parseOutputFormat("txt").?);
    try std.testing.expectEqual(OutputFormat.markdown, parseOutputFormat("markdown").?);
    try std.testing.expectEqual(OutputFormat.markdown, parseOutputFormat("md").?);
    try std.testing.expectEqual(OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expectEqual(OutputFormat.jsonl, parseOutputFormat("jsonl").?);
    try std.testing.expectEqual(OutputFormat.rag_jsonl, parseOutputFormat("rag-jsonl").?);
    try std.testing.expectEqual(OutputFormat.rag_jsonl, parseOutputFormat("rag_jsonl").?);
    try std.testing.expectEqual(OutputFormat.hocr, parseOutputFormat("hocr").?);
    try std.testing.expectEqual(OutputFormat.alto, parseOutputFormat("alto").?);
    try std.testing.expectEqual(OutputFormat.debug_svg, parseOutputFormat("debug-svg").?);
    try std.testing.expectEqual(OutputFormat.debug_svg, parseOutputFormat("debug_svg").?);
    try std.testing.expect(parseOutputFormat("xml") == null);
}

test "extract adaptive CLI supports reconciler formats" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "CLI Adaptive");
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-cli-adaptive-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    const cases = [_]struct {
        format: []const u8,
        needle: []const u8,
    }{
        .{ .format = "text", .needle = "CLI Adaptive" },
        .{ .format = "markdown", .needle = "CLI Adaptive" },
        .{ .format = "json", .needle = "\"spans\"" },
        .{ .format = "jsonl", .needle = "\"text\":\"CLI Adaptive\"" },
        .{ .format = "rag-jsonl", .needle = "\"source_id\":" },
        .{ .format = "hocr", .needle = "ocr_page" },
        .{ .format = "alto", .needle = "<alto>" },
        .{ .format = "debug-svg", .needle = "<svg" },
    };

    for (cases, 0..) |case, index| {
        var output_buf: [128]u8 = undefined;
        const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-cli-adaptive-{x}-{d}.out", .{
            std.testing.random_seed,
            index,
        });
        runtime.deleteFileCwd(output_path);
        defer runtime.deleteFileCwd(output_path);

        try runExtract(allocator, &.{ "--adaptive", "--format", case.format, "-o", output_path, input_path });

        const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, case.needle) != null);
    }
}

test "inspect complexity reports native route as JSON" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-inspect-native-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var output_buf: [96]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-inspect-native-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(output_path);
    defer runtime.deleteFileCwd(output_path);

    try runInspect(allocator, &.{ "complexity", input_path, "--format", "json", "-o", output_path });

    const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"page_index\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"route\":\"use_native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"span_count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"confidence\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"native_fast_path\"") != null);
}

test "extract adaptive trace reports OCR queue for image-only page" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateImageOnlyPdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-trace-image-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var output_buf: [96]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-trace-image-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(output_path);
    defer runtime.deleteFileCwd(output_path);

    try runExtract(allocator, &.{ input_path, "--adaptive", "--trace", "-o", output_path });

    const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"route\":\"queue_ocr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"image_dominant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"sparse_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ocr_route_stub\"") != null);
}

test "inspect complexity reports table and formula candidate routes" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateTableFormulaPdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-inspect-candidates-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var output_buf: [96]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-inspect-candidates-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(output_path);
    defer runtime.deleteFileCwd(output_path);

    try runInspect(allocator, &.{ "complexity", "--format", "json", "-o", output_path, input_path });

    const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"route\":\"candidate_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"route\":\"candidate_formula\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"table_alignment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"formula_density\"") != null);
}

test "adaptive debug svg shows two columns and block boundaries" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateTwoColumnPdf(allocator);
    defer allocator.free(pdf_data);

    const output = try renderFixtureDebugSvg(allocator, pdf_data, "two-column");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "data-debug-svg=\"adaptive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "id=\"native-spans\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "id=\"layout-blocks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-layer=\"layout-block\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-column=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-column=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-kind=\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-kind=\"footer\"") != null);
}

test "adaptive debug svg shows table candidates" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateTablePdf(allocator);
    defer allocator.free(pdf_data);

    const output = try renderFixtureDebugSvg(allocator, pdf_data, "table");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "class=\"table-candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-layer=\"table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-route=\"candidate_table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "table_route_stub") != null);
}

test "adaptive debug svg shows formula candidates" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateFormulaPdf(allocator);
    defer allocator.free(pdf_data);

    const output = try renderFixtureDebugSvg(allocator, pdf_data, "formula");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "class=\"formula-candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-layer=\"formula\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "formula_density") != null);
}

test "adaptive debug svg shows OCR-needed regions" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateImageOnlyPdf(allocator);
    defer allocator.free(pdf_data);

    const output = try renderFixtureDebugSvg(allocator, pdf_data, "image");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "class=\"ocr-needed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "data-route=\"queue_ocr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "image_dominant") != null);
}

fn renderFixtureDebugSvg(allocator: std.mem.Allocator, pdf_data: []const u8, name: []const u8) ![]u8 {
    var input_buf: [128]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-debug-svg-{s}-{x}.pdf", .{ name, std.testing.random_seed });
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var output_buf: [128]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-debug-svg-{s}-{x}.svg", .{ name, std.testing.random_seed });
    runtime.deleteFileCwd(output_path);
    defer runtime.deleteFileCwd(output_path);

    try runExtract(allocator, &.{ "--adaptive", "--format", "debug-svg", "-o", output_path, input_path });
    return runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
}

fn writeJsonEscapedString(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Extract text from a single page in reading order
fn extractPageReadingOrder(doc: *zpdf.Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
    const page = doc.pages.items[page_num];
    const page_width = page.media_box[2] - page.media_box[0];

    const spans = try doc.extractTextWithBounds(page_num, allocator);
    if (spans.len == 0) {
        return allocator.alloc(u8, 0);
    }
    defer zpdf.Document.freeTextSpans(allocator, spans);

    var layout_result = try zpdf.layout.analyzeLayout(allocator, spans, page_width);
    defer layout_result.deinit();

    return layout_result.getReconstructedText(allocator);
}

/// Extract text from all pages in reading order (parallel)
fn extractAllTextReadingOrderParallel(doc: *zpdf.Document, allocator: std.mem.Allocator) ![]u8 {
    const num_pages = doc.pages.items.len;
    if (num_pages == 0) return try allocator.alloc(u8, 0);

    // Allocate result buffers for each page
    const results = try allocator.alloc([]u8, num_pages);
    defer allocator.free(results);
    @memset(results, &[_]u8{});

    const Thread = std.Thread;
    const cpu_count = Thread.getCpuCount() catch 4;
    const num_threads: usize = @min(num_pages, @min(cpu_count, 8));

    const Context = struct {
        doc: *zpdf.Document,
        results: [][]u8,
        alloc: std.mem.Allocator,
    };

    const ctx = Context{
        .doc = doc,
        .results = results,
        .alloc = allocator,
    };

    const worker = struct {
        fn run(c: Context, start: usize, end: usize) void {
            for (start..end) |page_idx| {
                const page = c.doc.pages.items[page_idx];
                const page_width = page.media_box[2] - page.media_box[0];

                const spans = c.doc.extractTextWithBounds(page_idx, c.alloc) catch continue;
                if (spans.len == 0) continue;
                defer zpdf.Document.freeTextSpans(c.alloc, spans);

                var layout_result = zpdf.layout.analyzeLayout(c.alloc, spans, page_width) catch continue;
                defer layout_result.deinit();

                const text = layout_result.getReconstructedText(c.alloc) catch continue;
                c.results[page_idx] = text;
            }
        }
    }.run;

    // Spawn threads
    var threads: [8]?Thread = [_]?Thread{null} ** 8;
    const pages_per_thread = (num_pages + num_threads - 1) / num_threads;

    for (0..num_threads) |i| {
        const start = i * pages_per_thread;
        const end = @min(start + pages_per_thread, num_pages);
        if (start < end) {
            threads[i] = Thread.spawn(.{}, worker, .{ ctx, start, end }) catch null;
        }
    }

    // Wait for all threads
    for (&threads) |*t| {
        if (t.*) |thread| thread.join();
    }

    // Calculate total size
    var total_size: usize = 0;
    var non_empty_count: usize = 0;
    for (results) |r| {
        if (r.len > 0) {
            total_size += r.len;
            non_empty_count += 1;
        }
    }
    if (non_empty_count > 1) {
        total_size += non_empty_count - 1; // separators
    }

    if (total_size == 0) return allocator.alloc(u8, 0);

    var output = try allocator.alloc(u8, total_size);
    var pos: usize = 0;
    var first_written = false;
    for (results) |r| {
        if (r.len > 0) {
            if (first_written) {
                output[pos] = '\x0c';
                pos += 1;
            }
            @memcpy(output[pos..][0..r.len], r);
            pos += r.len;
            allocator.free(r);
            first_written = true;
        }
    }

    return output;
}

fn runInfo(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    }

    const path = args[0];

    const doc = zpdf.Document.open(allocator, path) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = runtime.stdoutWriter(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        \\pdf-parser Document Info
        \\==================
        \\File: {s}
        \\Size: {} bytes
        \\Pages: {}
        \\XRef entries: {}
        \\Encrypted: {s}
        \\
    , .{
        path,
        doc.data.len,
        doc.pages.items.len,
        doc.xref_table.entries.count(),
        if (doc.isEncrypted()) "yes" else "no",
    });

    // Print metadata
    const meta = doc.metadata();
    var has_meta = false;
    inline for (.{ .{ "Title", meta.title }, .{ "Author", meta.author }, .{ "Subject", meta.subject }, .{ "Keywords", meta.keywords }, .{ "Creator", meta.creator }, .{ "Producer", meta.producer }, .{ "Created", meta.creation_date }, .{ "Modified", meta.mod_date } }) |pair| {
        if (pair[1]) |val| {
            if (!has_meta) {
                try stdout.writeAll("\nMetadata:\n");
                has_meta = true;
            }
            try stdout.print("  {s}: {s}\n", .{ pair[0], val });
        }
    }

    // Print page sizes
    try stdout.writeAll("\nPage sizes:\n");
    for (doc.pages.items, 0..) |page, i| {
        const width = page.media_box[2] - page.media_box[0];
        const height = page.media_box[3] - page.media_box[1];
        try stdout.print("  Page {}: {d:.0} x {d:.0} pts", .{ i + 1, width, height });
        if (page.rotation != 0) {
            try stdout.print(" (rotated {}°)", .{page.rotation});
        }
        try stdout.writeByte('\n');
        if (i >= 9) {
            if (doc.pages.items.len > 10) {
                try stdout.print("  ... and {} more pages\n", .{doc.pages.items.len - 10});
            }
            break;
        }
    }

    // Print outline
    const outline_items = doc.getOutline(allocator) catch &.{};
    defer if (outline_items.len > 0) {
        for (outline_items) |item| {
            allocator.free(@constCast(item.title));
        }
        allocator.free(outline_items);
    };

    if (outline_items.len > 0) {
        try stdout.writeAll("\nOutline:\n");
        for (outline_items, 0..) |item, i| {
            // Indent by level
            var indent: u32 = 0;
            while (indent < item.level) : (indent += 1) {
                try stdout.writeAll("  ");
            }
            try stdout.print("  {s}", .{item.title});
            if (item.page) |p| {
                try stdout.print(" (page {})", .{p + 1});
            }
            try stdout.writeByte('\n');
            if (i >= 49) {
                if (outline_items.len > 50) {
                    try stdout.print("  ... and {} more entries\n", .{outline_items.len - 50});
                }
                break;
            }
        }
    }

    // Print form fields count
    if (doc.getFormFields(allocator)) |fields| {
        defer zpdf.Document.freeFormFields(allocator, fields);
        if (fields.len > 0) {
            try stdout.print("\nForm fields: {}\n", .{fields.len});
        }
    } else |_| {}
}

fn runSearch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: pdf-parser search <query> <input.pdf>\n", .{});
        return;
    }

    const query = args[0];
    const path = args[1];

    const doc = zpdf.Document.openWithConfig(allocator, path, zpdf.ErrorConfig.default()) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return;
    };
    defer doc.close();

    const results = doc.search(allocator, query) catch |err| {
        std.debug.print("Error searching: {}\n", .{err});
        return;
    };
    defer zpdf.Document.freeSearchResults(allocator, results);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = runtime.stdoutWriter(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    if (results.len == 0) {
        try stdout.print("No matches found for \"{s}\" in {s}\n", .{ query, path });
        return;
    }

    try stdout.print("Found {} match{s} for \"{s}\" in {s}:\n\n", .{
        results.len,
        if (results.len == 1) "" else "es",
        query,
        path,
    });

    for (results) |r| {
        try stdout.print("  Page {}, offset {}: \"...{s}...\"\n", .{
            r.page + 1,
            r.offset,
            r.context,
        });
    }
}

fn runBench(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    }

    const path = args[0];
    const parallel = args.len > 1 and std.mem.eql(u8, args[1], "--parallel");

    var stdout_buf: [4096]u8 = undefined;
    var stdout_bw = runtime.stdoutWriter(&stdout_buf);
    const stdout = &stdout_bw.interface;
    defer stdout.flush() catch {};

    try stdout.print("Benchmarking: {s}{s}\n\n", .{ path, if (parallel) " (parallel)" else "" });

    const RUNS = 5;
    var times: [RUNS]i64 = undefined;
    var page_count: usize = 0;

    for (&times) |*t| {
        const start = runtime.nanoTimestamp();

        const doc = zpdf.Document.open(allocator, path) catch |err| {
            std.debug.print("Error opening {s}: {}\n", .{ path, err });
            return;
        };
        page_count = doc.pages.items.len;

        if (parallel) {
            // Use structured extraction (reading order) with parallel support
            const result = doc.extractAllTextStructured(allocator) catch {
                doc.close();
                continue;
            };
            allocator.free(result);
        } else {
            var counter = CharCounter{};
            for (0..doc.pages.items.len) |page_num| {
                doc.extractText(page_num, &counter) catch continue;
            }
        }

        doc.close();

        const end = runtime.nanoTimestamp();
        t.* = @intCast(end - start);
    }

    // Calculate stats
    var sum: i64 = 0;
    var min: i64 = times[0];
    var max: i64 = times[0];
    for (times) |t| {
        sum += t;
        if (t < min) min = t;
        if (t > max) max = t;
    }
    const mean_ns = @divTrunc(sum, RUNS);
    const mean_ms = @as(f64, @floatFromInt(mean_ns)) / 1_000_000.0;

    try stdout.print("pdf-parser Results ({} runs):\n", .{RUNS});
    try stdout.print("  Mean:   {d:.2} ms\n", .{mean_ms});
    try stdout.print("  Min:    {d:.2} ms\n", .{@as(f64, @floatFromInt(min)) / 1_000_000.0});
    try stdout.print("  Max:    {d:.2} ms\n", .{@as(f64, @floatFromInt(max)) / 1_000_000.0});
    try stdout.print("  Pages:  {}\n", .{page_count});
    try stdout.print("  Pages/s: {d:.0}\n", .{@as(f64, @floatFromInt(page_count)) / (mean_ms / 1000.0)});

    // Try to run mutool for comparison
    try stdout.writeAll("\nAttempting mutool comparison...\n");

    const mutool_start = runtime.nanoTimestamp();
    const mutool_exit_code = runtime.runIgnored(&.{ "mutool", "convert", "-F", "text", "-o", "/dev/null", path }) catch {
        try stdout.writeAll("  mutool not found or failed\n");
        return;
    };
    const mutool_end = runtime.nanoTimestamp();

    if (mutool_exit_code == 0) {
        const mutool_ms = @as(f64, @floatFromInt(mutool_end - mutool_start)) / 1_000_000.0;
        try stdout.print("  MuPDF:  {d:.2} ms\n", .{mutool_ms});
        try stdout.print("  Speedup: {d:.2}x\n", .{mutool_ms / mean_ms});
    } else {
        try stdout.writeAll("  mutool failed\n");
    }
}

const CharCounter = struct {
    count: usize = 0,

    pub fn writeAll(self: *CharCounter, data: []const u8) !void {
        self.count += data.len;
    }

    pub fn writeByte(self: *CharCounter, _: u8) !void {
        self.count += 1;
    }

    pub fn print(self: *CharCounter, comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
        self.count += 1;
    }
};

fn parsePageRange(allocator: std.mem.Allocator, range_str: ?[]const u8, total_pages: usize) ![]usize {
    if (range_str == null or range_str.?.len == 0) {
        // Return all pages
        const pages = try allocator.alloc(usize, total_pages);
        for (pages, 0..) |*p, i| {
            p.* = i;
        }
        return pages;
    }

    const spec = range_str.?;

    // Count how many pages we'll need
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, spec, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1 ..];
            const start = (std.fmt.parseInt(usize, start_str, 10) catch 1) -| 1;
            const end = std.fmt.parseInt(usize, end_str, 10) catch total_pages;
            count += @min(end, total_pages) -| start;
        } else {
            count += 1;
        }
    }

    var pages = try allocator.alloc(usize, count);
    var idx: usize = 0;

    iter = std.mem.splitScalar(u8, spec, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.indexOf(u8, trimmed, "-")) |dash_pos| {
            const start_str = trimmed[0..dash_pos];
            const end_str = trimmed[dash_pos + 1 ..];
            const start = (std.fmt.parseInt(usize, start_str, 10) catch 1) -| 1;
            const end = std.fmt.parseInt(usize, end_str, 10) catch total_pages;

            var page = start;
            while (page < @min(end, total_pages)) : (page += 1) {
                if (idx < pages.len) {
                    pages[idx] = page;
                    idx += 1;
                }
            }
        } else {
            const page = (std.fmt.parseInt(usize, trimmed, 10) catch continue) -| 1;
            if (page < total_pages and idx < pages.len) {
                pages[idx] = page;
                idx += 1;
            }
        }
    }

    return pages[0..idx];
}
