//! pdf-parser CLI - Text extraction tool
//!
//! Usage: pdf-parser extract [options] input.pdf [pages]
//!        pdf-parser extract-adaptive --input input.pdf [options]
//!        pdf-parser inspect complexity [options] input.pdf
//!        pdf-parser check [options] input.pdf
//!        pdf-parser info input.pdf
//!        pdf-parser bench input.pdf
//!        pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv
//!        pdf-parser serve --host 0.0.0.0 --port 8080
//!
//! Designed to be a drop-in comparison with `mutool draw -F txt`

const std = @import("std");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");
const benchmark_runner = @import("benchmark_runner.zig");
const server = @import("server.zig");

pub const main = runtime.MainWithArgs(mainInner).main;

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "extract")) {
        try runExtract(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "extract-adaptive")) {
        try runExtractAdaptive(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "inspect")) {
        try runInspect(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "info")) {
        try runInfo(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "search")) {
        try runSearch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "bench")) {
        try runBench(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "benchmark")) {
        try benchmark_runner.runCli(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        try server.runCli(allocator, args[2..]);
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
        \\  extract-adaptive
        \\              Host adapter extraction surface for adaptive artifacts
        \\  inspect     Inspect parser decisions and document signals
        \\  check       Run structural parser check and recovery diagnostics
        \\  info        Show PDF structure information (metadata, outline, etc.)
        \\  search      Search for text across all pages
        \\  bench       Benchmark extraction performance
        \\  benchmark   Run corpus benchmark scorecards for parser/tool comparison
        \\  serve       Run stateless HTTP adapter server
        \\  help        Show this help
        \\
        \\Extract options:
        \\  -o FILE         Output to file (default: stdout)
        \\  -p PAGES        Page range (e.g., "1-10" or "1,3,5")
        \\  --pages PAGES   Page range alias for adapter-style commands
        \\  -f, --format    Output format: text, markdown, json, jsonl, artifact-jsonl, stream-jsonl, rag-jsonl, hocr, alto, or debug-svg
        \\  -m, --markdown  Shortcut for --format markdown
        \\  --adaptive      Use adaptive routing and reconciled outputs
        \\  --source-id ID  External caller-owned source id for adaptive artifacts
        \\  --password PASS Open an encrypted PDF with a supplied password
        \\  --password-file FILE
        \\                  Read the encrypted PDF password from FILE (trailing newline ignored)
        \\  --ocr-executable FILE
        \\                  Tesseract executable for adaptive OCR routes
        \\  --ocr-rasterizer FILE
        \\                  pdftoppm-compatible rasterizer for adaptive OCR routes
        \\  --ocr-dpi N     Rasterization DPI for adaptive OCR routes (default: 200)
        \\  --ocr-color     Rasterize OCR pages as RGB instead of default grayscale
        \\  --ocr-grayscale Rasterize OCR pages as grayscale (default)
        \\  --no-ocr        Disable adaptive OCR subprocess routing
        \\  --debug-assets-dir DIR
        \\                  Write visual review sidecar assets for adaptive outputs
        \\  --emit-specialist-requests FILE
        \\                  Write specialist request JSONL without invoking specialists
        \\  --specialist-config FILE
        \\                  Specialist executable config for future local adapters
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
        \\  pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
        \\  pdf-parser extract --adaptive -f stream-jsonl doc.pdf
        \\  pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl
        \\  pdf-parser extract-adaptive --input encrypted.pdf --password-file .password --format artifact-jsonl
        \\  pdf-parser extract --adaptive -f debug-svg doc.pdf
        \\  pdf-parser extract doc.pdf --adaptive --trace
        \\  pdf-parser inspect complexity doc.pdf --format json
        \\  pdf-parser inspect structure doc.pdf --format json
        \\  pdf-parser check doc.pdf --format json
        \\  pdf-parser extract --reading-order doc.pdf   # Visual reading order
        \\  pdf-parser search "revenue" document.pdf      # Search across all pages
        \\  pdf-parser bench document.pdf                # Benchmark vs mutool
        \\  pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv --tools pdf-parser:adaptive
        \\  pdf-parser serve --host 0.0.0.0 --port 8080
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
    artifact_jsonl, // Versioned JSON Lines artifact stream
    stream_jsonl, // Versioned page-by-page JSON Lines artifact stream
    markdown, // Markdown with headings, lists, etc.
    hocr, // hOCR-like HTML coordinates
    alto, // ALTO-like XML coordinates
    debug_svg, // SVG block overlay
};

const PasswordInput = struct {
    value: ?[]const u8 = null,
    owned: ?[]align(1) u8 = null,

    fn deinit(self: *PasswordInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = .{};
    }
};

fn loadPasswordInput(
    allocator: std.mem.Allocator,
    password: ?[]const u8,
    password_file: ?[]const u8,
) !PasswordInput {
    if (password != null and password_file != null) return error.DuplicatePasswordSource;
    if (password) |value| return .{ .value = value };
    const path = password_file orelse return .{};
    const data = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    const trimmed = trimTrailingNewlines(data);
    return .{ .value = trimmed, .owned = data };
}

fn trimTrailingNewlines(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) {
        end -= 1;
    }
    return bytes[0..end];
}

fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var output_format: OutputFormat = .text;
    var sequential = false;
    var extraction_mode: ExtractionMode = .normal;
    var adaptive = false;
    var trace = false;
    var source_id: ?[]const u8 = null;
    var debug_assets_dir: ?[]const u8 = null;
    var specialist_requests_file: ?[]const u8 = null;
    var specialist_config_file: ?[]const u8 = null;
    var ocr_config = zpdf.OcrConfig{};
    var enable_ocr = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--source-id")) {
            i += 1;
            if (i < args.len) source_id = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i < args.len) password = args[i];
        } else if (std.mem.eql(u8, arg, "--password-file")) {
            i += 1;
            if (i < args.len) password_file = args[i];
        } else if (std.mem.eql(u8, arg, "--debug-assets-dir")) {
            i += 1;
            if (i < args.len) debug_assets_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--emit-specialist-requests")) {
            i += 1;
            if (i < args.len) specialist_requests_file = args[i];
        } else if (std.mem.eql(u8, arg, "--specialist-config")) {
            i += 1;
            if (i < args.len) specialist_config_file = args[i];
        } else if (std.mem.eql(u8, arg, "--no-ocr")) {
            enable_ocr = false;
        } else if (std.mem.eql(u8, arg, "--ocr-executable")) {
            i += 1;
            if (i < args.len) ocr_config.executable = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-rasterizer")) {
            i += 1;
            if (i < args.len) ocr_config.rasterizer_executable = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-lang")) {
            i += 1;
            if (i < args.len) ocr_config.lang = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-dpi")) {
            i += 1;
            if (i < args.len) ocr_config.dpi = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid --ocr-dpi value: {s}\n", .{args[i]});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--ocr-color")) {
            ocr_config.rasterize_grayscale = false;
        } else if (std.mem.eql(u8, arg, "--ocr-grayscale")) {
            ocr_config.rasterize_grayscale = true;
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
                    std.debug.print("Unknown format: {s}. Use text, markdown, json, jsonl, artifact-jsonl, stream-jsonl, rag-jsonl, hocr, alto, or debug-svg.\n", .{args[i]});
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

    var password_input = loadPasswordInput(allocator, password, password_file) catch |err| {
        std.debug.print("Error loading password input: {}\n", .{err});
        return err;
    };
    defer password_input.deinit(allocator);
    error_mode.password = password_input.value;

    // Open document
    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    // Warn about encrypted PDFs
    if (doc.isEncrypted() and !doc.isAuthenticated()) {
        std.debug.print("Warning: {s} is encrypted and was not authenticated. Text extraction may produce incorrect results.\n", .{path});
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
        try doAdaptiveExtract(doc, pages, output_format, trace, source_id, debug_assets_dir, specialist_requests_file, specialist_config_file, enable_ocr, ocr_config, allocator, output_handle);
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

        // AcroForm fields are document-level metadata/widgets. Keep them
        // structured here even though value-bearing fields are also appended
        // to page text for plain-text extraction.
        try writer.writeAll("  \"form_fields\": ");
        try writeFormFieldsJson(doc, allocator, writer);
        try writer.writeAll(",\n");

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

                    try writer.writeAll(",\n      \"tables\": ");
                    doc.writePageTablesJson(page_num, allocator, writer) catch {
                        try writer.writeAll("[]");
                    };

                    try writer.writeAll("\n    }");
                } else if (idx + 1 < pages.len) {
                    try writer.writeAll(text);
                    try writer.writeByte('\x0c');
                } else {
                    try writer.writeAll(text);
                }
            },
            .jsonl, .rag_jsonl, .artifact_jsonl, .stream_jsonl, .hocr, .alto, .debug_svg => unreachable,
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
    source_id: ?[]const u8,
    debug_assets_dir: ?[]const u8,
    specialist_requests_file: ?[]const u8,
    specialist_config_file: ?[]const u8,
    enable_ocr: bool,
    ocr_config: zpdf.OcrConfig,
    allocator: std.mem.Allocator,
    output_handle: ?runtime.File,
) !void {
    const window = contiguousPageWindow(pages) catch |err| {
        std.debug.print("Error: --adaptive currently requires a contiguous page range: {}\n", .{err});
        return;
    };

    const input_sha256 = zpdf.schema.sha256Hex(allocator, doc.data) catch |err| {
        std.debug.print("Error hashing input: {}\n", .{err});
        return;
    };
    defer allocator.free(input_sha256);

    const parser_errors = try allocator.alloc(zpdf.schema.ManifestDiagnostic, doc.errors.items.len);
    defer allocator.free(parser_errors);
    for (doc.errors.items, 0..) |parse_error, index| {
        parser_errors[index] = .{
            .code = @tagName(parse_error.kind),
            .message = parse_error.message,
            .offset = parse_error.offset,
        };
    }
    const encryption_info = doc.encryptionInfo();
    var encryption_warning_storage: [2]zpdf.schema.ManifestDiagnostic = undefined;
    const encryption_warnings = zpdf.schema.collectEncryptionWarnings(
        &encryption_warning_storage,
        encryption_info,
        doc.error_config.respect_permissions,
    );

    const schema_options = zpdf.schema.RenderOptions{
        .document_id = doc.source_path orelse "document",
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .source_path = doc.source_path,
        .page_count = doc.pageCount(),
        .encrypted = doc.isEncrypted(),
        .encryption_info = encryption_info,
        .corrupt = doc.errors.items.len > 0,
        .warnings = encryption_warnings,
        .errors = parser_errors,
        .debug_assets_dir = debug_assets_dir,
        .specialist_config_path = specialist_config_file,
    };

    if (!trace and output_format == .stream_jsonl) {
        if (specialist_requests_file) |requests_path| {
            var request_result = doc.extractAdaptive(allocator, .{
                .page_start = window.start,
                .page_end = window.end,
                .enable_ocr = enable_ocr,
                .ocr_config = ocr_config,
            }) catch |err| {
                std.debug.print("Error generating specialist requests: {}\n", .{err});
                return;
            };
            defer request_result.deinit();
            writeSpecialistRequestsFile(allocator, requests_path, &request_result, schema_options) catch |err| {
                std.debug.print("Error writing specialist requests: {}\n", .{err});
                return;
            };
        }
        var write_buf: [runtime.large_output_buffer_size]u8 = undefined;
        if (output_handle) |h| {
            var file_writer = runtime.fileWriter(h, &write_buf);
            const writer = &file_writer.interface;
            defer writer.flush() catch {};
            _ = doc.extractAdaptiveStreaming(allocator, writer, .{
                .adaptive_options = .{
                    .page_start = window.start,
                    .page_end = window.end,
                    .enable_ocr = enable_ocr,
                    .ocr_config = ocr_config,
                },
                .schema_options = schema_options,
            }) catch |err| {
                std.debug.print("Error during streaming adaptive extraction: {}\n", .{err});
                return;
            };
        } else {
            var stdout_writer = runtime.stdoutWriter(&write_buf);
            const writer = &stdout_writer.interface;
            defer writer.flush() catch {};
            _ = doc.extractAdaptiveStreaming(allocator, writer, .{
                .adaptive_options = .{
                    .page_start = window.start,
                    .page_end = window.end,
                    .enable_ocr = enable_ocr,
                    .ocr_config = ocr_config,
                },
                .schema_options = schema_options,
            }) catch |err| {
                std.debug.print("Error during streaming adaptive extraction: {}\n", .{err});
                return;
            };
        }
        return;
    }

    var result = doc.extractAdaptive(allocator, .{
        .page_start = window.start,
        .page_end = window.end,
        .enable_ocr = enable_ocr,
        .ocr_config = ocr_config,
    }) catch |err| {
        std.debug.print("Error during adaptive extraction: {}\n", .{err});
        return;
    };
    defer result.deinit();

    if (specialist_requests_file) |requests_path| {
        writeSpecialistRequestsFile(allocator, requests_path, &result, schema_options) catch |err| {
            std.debug.print("Error writing specialist requests: {}\n", .{err});
            return;
        };
    }

    if (!trace and output_format == .artifact_jsonl) {
        var write_buf: [runtime.large_output_buffer_size]u8 = undefined;
        if (output_handle) |h| {
            var file_writer = runtime.fileWriter(h, &write_buf);
            const writer = &file_writer.interface;
            defer writer.flush() catch {};
            zpdf.schema.writeArtifactJsonl(allocator, writer, &result, schema_options) catch |err| {
                std.debug.print("Error rendering adaptive output as artifact-jsonl: {}\n", .{err});
                return;
            };
        } else {
            var stdout_writer = runtime.stdoutWriter(&write_buf);
            const writer = &stdout_writer.interface;
            defer writer.flush() catch {};
            zpdf.schema.writeArtifactJsonl(allocator, writer, &result, schema_options) catch |err| {
                std.debug.print("Error rendering adaptive output as artifact-jsonl: {}\n", .{err});
                return;
            };
        }
        return;
    }

    const rendered = if (trace)
        zpdf.schema.renderTraceJsonWithOptions(allocator, &result, schema_options) catch |err| {
            std.debug.print("Error rendering adaptive trace: {}\n", .{err});
            return;
        }
    else if (output_format == .json)
        zpdf.schema.renderArtifactJson(allocator, &result, schema_options) catch |err| {
            std.debug.print("Error rendering adaptive output as json: {}\n", .{err});
            return;
        }
    else if (output_format == .artifact_jsonl)
        unreachable
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

fn writeSpecialistRequestsFile(allocator: std.mem.Allocator, path: []const u8, result: anytype, options: zpdf.schema.RenderOptions) !void {
    const rendered = try zpdf.specialist_protocol.renderRequestsJsonl(allocator, result, .{
        .document_id = options.document_id,
        .source_id = options.source_id,
        .input_sha256 = options.input_sha256,
    });
    defer allocator.free(rendered);

    const file = try runtime.createFileCwd(path);
    defer runtime.closeFile(file);
    try runtime.writeAllFile(file, rendered);
}

fn runExtractAdaptive(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var source_id: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;
    var debug_assets_dir: ?[]const u8 = null;
    var specialist_requests_file: ?[]const u8 = null;
    var specialist_config_file: ?[]const u8 = null;
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var adapter_format: zpdf.AdaptiveAdapterFormat = .artifact_jsonl;
    var ocr_config = zpdf.OcrConfig{};
    var enable_ocr = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i < args.len) input_file = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pages")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--source-id")) {
            i += 1;
            if (i < args.len) source_id = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i < args.len) password = args[i];
        } else if (std.mem.eql(u8, arg, "--password-file")) {
            i += 1;
            if (i < args.len) password_file = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-executable")) {
            i += 1;
            if (i < args.len) ocr_config.executable = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-rasterizer")) {
            i += 1;
            if (i < args.len) ocr_config.rasterizer_executable = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-lang")) {
            i += 1;
            if (i < args.len) ocr_config.lang = args[i];
        } else if (std.mem.eql(u8, arg, "--ocr-dpi")) {
            i += 1;
            if (i < args.len) ocr_config.dpi = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid --ocr-dpi value: {s}\n", .{args[i]});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--ocr-color")) {
            ocr_config.rasterize_grayscale = false;
        } else if (std.mem.eql(u8, arg, "--ocr-grayscale")) {
            ocr_config.rasterize_grayscale = true;
        } else if (std.mem.eql(u8, arg, "--no-ocr")) {
            enable_ocr = false;
        } else if (std.mem.eql(u8, arg, "--debug-assets-dir")) {
            i += 1;
            if (i < args.len) debug_assets_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--emit-specialist-requests")) {
            i += 1;
            if (i < args.len) specialist_requests_file = args[i];
        } else if (std.mem.eql(u8, arg, "--specialist-config")) {
            i += 1;
            if (i < args.len) specialist_config_file = args[i];
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) {
                adapter_format = zpdf.adapter.formatFromName(args[i]) orelse {
                    std.debug.print("Unknown extract-adaptive format: {s}. Use json, artifact-jsonl, stream-jsonl, or trace-json.\n", .{args[i]});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--trace")) {
            adapter_format = .trace_json;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            error_mode = zpdf.ErrorConfig.strict();
        } else if (std.mem.eql(u8, arg, "--permissive")) {
            error_mode = zpdf.ErrorConfig.permissive();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("extract-adaptive requires --input; unexpected positional argument: {s}\n", .{arg});
            return;
        }
    }

    const path = input_file orelse {
        std.debug.print("Error: extract-adaptive requires --input <file.pdf>\n", .{});
        return;
    };

    var password_input = loadPasswordInput(allocator, password, password_file) catch |err| {
        std.debug.print("Error loading password input: {}\n", .{err});
        return err;
    };
    defer password_input.deinit(allocator);
    error_mode.password = password_input.value;

    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const pages = parsePageRange(allocator, page_range, doc.pages.items.len) catch |err| {
        std.debug.print("Error parsing page range: {}\n", .{err});
        return;
    };
    defer allocator.free(pages);

    const window = contiguousPageWindow(pages) catch |err| {
        std.debug.print("Error: extract-adaptive currently requires a contiguous page range: {}\n", .{err});
        return;
    };

    const output_handle = if (output_file) |out_path|
        runtime.createFileCwd(out_path) catch |err| {
            std.debug.print("Error creating {s}: {}\n", .{ out_path, err });
            return;
        }
    else
        null;
    defer if (output_handle) |h| runtime.closeFile(h);

    var write_buf: [runtime.large_output_buffer_size]u8 = undefined;
    if (output_handle) |h| {
        var file_writer = runtime.fileWriter(h, &write_buf);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};
        _ = zpdf.adapter.extractAdaptive(allocator, doc, writer, .{
            .source_id = source_id,
            .format = adapter_format,
            .debug_assets_dir = debug_assets_dir,
            .emit_specialist_requests_path = specialist_requests_file,
            .specialist_config_path = specialist_config_file,
            .adaptive_options = .{
                .page_start = window.start,
                .page_end = window.end,
                .enable_ocr = enable_ocr,
                .ocr_config = ocr_config,
            },
        }) catch |err| {
            std.debug.print("Error during extract-adaptive: {}\n", .{err});
            return;
        };
    } else {
        var stdout_writer = runtime.stdoutWriter(&write_buf);
        const writer = &stdout_writer.interface;
        defer writer.flush() catch {};
        _ = zpdf.adapter.extractAdaptive(allocator, doc, writer, .{
            .source_id = source_id,
            .format = adapter_format,
            .debug_assets_dir = debug_assets_dir,
            .emit_specialist_requests_path = specialist_requests_file,
            .specialist_config_path = specialist_config_file,
            .adaptive_options = .{
                .page_start = window.start,
                .page_end = window.end,
                .enable_ocr = enable_ocr,
                .ocr_config = ocr_config,
            },
        }) catch |err| {
            std.debug.print("Error during extract-adaptive: {}\n", .{err});
            return;
        };
    }
}

fn runInspect(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("Usage: pdf-parser inspect complexity|structure [--format json] <input.pdf>\n", .{});
        return;
    }

    const subject = args[0];
    if (std.mem.eql(u8, subject, "structure")) {
        try runStructureCheck(allocator, args[1..]);
        return;
    }
    if (!std.mem.eql(u8, subject, "complexity")) {
        std.debug.print("Unknown inspect subject: {s}. Use complexity or structure.\n", .{subject});
        return;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var page_range: ?[]const u8 = null;
    var format: []const u8 = "json";
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.default();
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i < args.len) page_range = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i < args.len) password = args[i];
        } else if (std.mem.eql(u8, arg, "--password-file")) {
            i += 1;
            if (i < args.len) password_file = args[i];
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

    var password_input = loadPasswordInput(allocator, password, password_file) catch |err| {
        std.debug.print("Error loading password input: {}\n", .{err});
        return err;
    };
    defer password_input.deinit(allocator);
    error_mode.password = password_input.value;

    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return err;
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
        .enable_ocr = false,
    }) catch |err| {
        std.debug.print("Error inspecting complexity: {}\n", .{err});
        return;
    };
    defer result.deinit();

    const rendered = zpdf.schema.renderComplexityJson(allocator, &result, doc.source_path orelse "document") catch |err| {
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

fn runCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    try runStructureCheck(allocator, args);
}

fn runStructureCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var format: []const u8 = "json";
    var error_mode: zpdf.ErrorConfig = zpdf.ErrorConfig.permissive();
    var password: ?[]const u8 = null;
    var password_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--password")) {
            i += 1;
            if (i < args.len) password = args[i];
        } else if (std.mem.eql(u8, arg, "--password-file")) {
            i += 1;
            if (i < args.len) password_file = args[i];
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
        std.debug.print("structure check currently supports only --format json.\n", .{});
        return;
    }

    const path = input_file orelse {
        std.debug.print("Error: No input file specified\n", .{});
        return;
    };

    var password_input = loadPasswordInput(allocator, password, password_file) catch |err| {
        std.debug.print("Error loading password input: {}\n", .{err});
        return err;
    };
    defer password_input.deinit(allocator);
    error_mode.password = password_input.value;

    const doc = zpdf.Document.openWithConfig(allocator, path, error_mode) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ path, err });
        return err;
    };
    defer doc.close();

    const input_sha256 = try zpdf.schema.sha256Hex(allocator, doc.data);
    defer allocator.free(input_sha256);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try zpdf.structural.renderCheckJson(
        allocator,
        runtime.arrayListWriter(&output, allocator),
        doc.source_path orelse "document",
        input_sha256,
        zpdf.schema.parser_version,
        doc.pageCount(),
        doc.isEncrypted(),
        doc.structuralSummary(),
        doc.structuralDiagnostics(),
    );

    if (output_file) |out_path| {
        const output_handle = runtime.createFileCwd(out_path) catch |err| {
            std.debug.print("Error creating {s}: {}\n", .{ out_path, err });
            return;
        };
        defer runtime.closeFile(output_handle);
        runtime.writeAllFile(output_handle, output.items) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            return;
        };
    } else {
        runtime.writeAllStdout(output.items) catch |err| {
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
    if (std.mem.eql(u8, fmt, "artifact-jsonl") or std.mem.eql(u8, fmt, "artifact_jsonl")) return .artifact_jsonl;
    if (std.mem.eql(u8, fmt, "stream-jsonl") or std.mem.eql(u8, fmt, "stream_jsonl")) return .stream_jsonl;
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
        .artifact_jsonl => "artifact-jsonl",
        .stream_jsonl => "stream-jsonl",
        .markdown => "markdown",
        .hocr => "hocr",
        .alto => "alto",
        .debug_svg => "debug-svg",
    };
}

fn isLegacyOutputFormat(output_format: OutputFormat) bool {
    return switch (output_format) {
        .text, .json, .markdown => true,
        .jsonl, .rag_jsonl, .artifact_jsonl, .stream_jsonl, .hocr, .alto, .debug_svg => false,
    };
}

fn toAdaptiveOutputFormat(output_format: OutputFormat) zpdf.AdaptiveOutputFormat {
    return switch (output_format) {
        .text => .text,
        .json => .json,
        .jsonl => .jsonl,
        .rag_jsonl => .rag_jsonl,
        .artifact_jsonl => .artifact_jsonl,
        .stream_jsonl => .artifact_jsonl,
        .markdown => .markdown,
        .hocr => .hocr,
        .alto => .alto,
        .debug_svg => .debug_svg,
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
    try std.testing.expectEqual(OutputFormat.artifact_jsonl, parseOutputFormat("artifact-jsonl").?);
    try std.testing.expectEqual(OutputFormat.artifact_jsonl, parseOutputFormat("artifact_jsonl").?);
    try std.testing.expectEqual(OutputFormat.stream_jsonl, parseOutputFormat("stream-jsonl").?);
    try std.testing.expectEqual(OutputFormat.stream_jsonl, parseOutputFormat("stream_jsonl").?);
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
        .{ .format = "artifact-jsonl", .needle = "\"record_type\":\"document_manifest\"" },
        .{ .format = "stream-jsonl", .needle = "\"record_type\":\"document_finished\"" },
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

test "extract-adaptive CLI emits neutral source id artifacts" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-cli-adapter-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    const cases = [_]struct {
        output_suffix: []const u8,
        args: []const []const u8,
        needles: []const []const u8,
    }{
        .{
            .output_suffix = "artifact",
            .args = &.{ "extract-adaptive", "--input", input_path, "--source-id", "external-123", "--format", "artifact-jsonl" },
            .needles = &.{ "\"record_type\":\"document_manifest\"", "\"source_id\":\"external-123\"", "\"record_type\":\"rag_chunk\"" },
        },
        .{
            .output_suffix = "stream",
            .args = &.{ "extract-adaptive", "--input", input_path, "--source-id", "external-123", "--format", "stream-jsonl" },
            .needles = &.{ "\"record_type\":\"document_finished\"", "\"source_id\":\"external-123\"", "\"event_type\":\"page_started\"" },
        },
        .{
            .output_suffix = "legacy",
            .args = &.{ "extract", "--adaptive", "--source-id", "external-123", "--format", "artifact-jsonl", input_path },
            .needles = &.{ "\"record_type\":\"document_manifest\"", "\"source_id\":\"external-123\"", "\"provenance\":{\"document_id\"" },
        },
    };

    for (cases) |case| {
        var output_buf: [128]u8 = undefined;
        const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-cli-adapter-{x}-{s}.out", .{
            std.testing.random_seed,
            case.output_suffix,
        });
        runtime.deleteFileCwd(output_path);
        defer runtime.deleteFileCwd(output_path);

        if (std.mem.eql(u8, case.args[0], "extract-adaptive")) {
            var argv = try std.ArrayList([]const u8).initCapacity(allocator, case.args.len + 2);
            defer argv.deinit(allocator);
            try argv.appendSlice(allocator, case.args);
            try argv.appendSlice(allocator, &.{ "--output", output_path });
            try runExtractAdaptive(allocator, argv.items[1..]);
        } else {
            var argv = try std.ArrayList([]const u8).initCapacity(allocator, case.args.len + 2);
            defer argv.deinit(allocator);
            try argv.appendSlice(allocator, case.args);
            try argv.appendSlice(allocator, &.{ "-o", output_path });
            try runExtract(allocator, argv.items[1..]);
        }

        const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
        defer allocator.free(output);
        for (case.needles) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
        }
    }
}

test "adaptive CLI emits specialist request JSONL sidecars" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateTableFormulaPdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-cli-specialist-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    const cases = [_]struct {
        suffix: []const u8,
        legacy: bool,
    }{
        .{ .suffix = "adapter", .legacy = false },
        .{ .suffix = "legacy", .legacy = true },
    };

    for (cases) |case| {
        var output_buf: [128]u8 = undefined;
        const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-cli-specialist-{x}-{s}.jsonl", .{ std.testing.random_seed, case.suffix });
        runtime.deleteFileCwd(output_path);
        defer runtime.deleteFileCwd(output_path);

        var requests_buf: [128]u8 = undefined;
        const requests_path = try std.fmt.bufPrint(&requests_buf, "pdf-parser-cli-specialist-{x}-{s}.requests.jsonl", .{ std.testing.random_seed, case.suffix });
        runtime.deleteFileCwd(requests_path);
        defer runtime.deleteFileCwd(requests_path);

        if (case.legacy) {
            try runExtract(allocator, &.{
                "--adaptive",
                "--source-id",
                "external-specialist-cli",
                "--format",
                "artifact-jsonl",
                "--emit-specialist-requests",
                requests_path,
                "--specialist-config",
                "specialists.json",
                "-o",
                output_path,
                input_path,
            });
        } else {
            try runExtractAdaptive(allocator, &.{
                "--input",
                input_path,
                "--source-id",
                "external-specialist-cli",
                "--format",
                "artifact-jsonl",
                "--emit-specialist-requests",
                requests_path,
                "--specialist-config",
                "specialists.json",
                "--output",
                output_path,
            });
        }

        const requests = try runtime.readFileAllocAlignedCwd(allocator, requests_path, .fromByteUnits(1));
        defer allocator.free(requests);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"record_type\":\"specialist_request\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"schema_version\":\"0.9.0\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"source_id\":\"external-specialist-cli\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"requested_kind\":\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"requested_outputs\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, requests, "\"provenance\"") != null);

        const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
        defer allocator.free(output);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"record_type\":\"specialist_request\"") != null);
    }
}

test "extract-adaptive CLI writes visual review sidecars only when requested" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateMergedCellFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-cli-assets-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var no_assets_output_buf: [112]u8 = undefined;
    const no_assets_output_path = try std.fmt.bufPrint(&no_assets_output_buf, "pdf-parser-cli-assets-{x}-none.jsonl", .{std.testing.random_seed});
    runtime.deleteFileCwd(no_assets_output_path);
    defer runtime.deleteFileCwd(no_assets_output_path);

    try runExtractAdaptive(allocator, &.{ "--input", input_path, "--source-id", "external-assets", "--format", "artifact-jsonl", "--output", no_assets_output_path });
    const no_assets_output = try runtime.readFileAllocAlignedCwd(allocator, no_assets_output_path, .fromByteUnits(1));
    defer allocator.free(no_assets_output);
    try std.testing.expect(std.mem.indexOf(u8, no_assets_output, "\"asset_kind\":\"table_grid_overlay_svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_assets_output, "\"path\":null") != null);

    var asset_dir_buf: [96]u8 = undefined;
    const asset_dir = try std.fmt.bufPrint(&asset_dir_buf, "pdf-parser-cli-assets-dir-{x}", .{std.testing.random_seed});
    runtime.deleteTreeCwd(asset_dir);
    defer runtime.deleteTreeCwd(asset_dir);
    var output_buf: [112]u8 = undefined;
    const output_path = try std.fmt.bufPrint(&output_buf, "pdf-parser-cli-assets-{x}.jsonl", .{std.testing.random_seed});
    runtime.deleteFileCwd(output_path);
    defer runtime.deleteFileCwd(output_path);

    try runExtractAdaptive(allocator, &.{ "--input", input_path, "--source-id", "external-assets", "--format", "artifact-jsonl", "--debug-assets-dir", asset_dir, "--output", output_path });
    const output = try runtime.readFileAllocAlignedCwd(allocator, output_path, .fromByteUnits(1));
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"path\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"sha256\":\"") != null);

    const table_grid_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.table-grid.svg" });
    defer allocator.free(table_grid_path);
    const table_grid = try runtime.readFileAllocAlignedCwd(allocator, table_grid_path, .fromByteUnits(1));
    defer allocator.free(table_grid);
    try std.testing.expect(std.mem.indexOf(u8, table_grid, "id=\"table-grid\"") != null);
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

test "inspect structure and check emit structural diagnostics JSON" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generatePdfWithoutPageType(allocator, "Recovered structure");
    defer allocator.free(pdf_data);

    var input_buf: [112]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-structure-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var inspect_buf: [112]u8 = undefined;
    const inspect_path = try std.fmt.bufPrint(&inspect_buf, "pdf-parser-structure-inspect-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(inspect_path);
    defer runtime.deleteFileCwd(inspect_path);

    try runInspect(allocator, &.{ "structure", "--format", "json", "-o", inspect_path, input_path });
    const inspect_output = try runtime.readFileAllocAlignedCwd(allocator, inspect_path, .fromByteUnits(1));
    defer allocator.free(inspect_output);
    try std.testing.expect(std.mem.indexOf(u8, inspect_output, "\"record_type\":\"structural_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_output, "\"status\":\"recovered\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_output, "\"page_tree_missing_type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inspect_output, "\"input_sha256\":\"") != null);

    var check_buf: [112]u8 = undefined;
    const check_path = try std.fmt.bufPrint(&check_buf, "pdf-parser-structure-check-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(check_path);
    defer runtime.deleteFileCwd(check_path);

    try runCheck(allocator, &.{ "--format", "json", "-o", check_path, input_path });
    const check_output = try runtime.readFileAllocAlignedCwd(allocator, check_path, .fromByteUnits(1));
    defer allocator.free(check_output);
    try std.testing.expect(std.mem.indexOf(u8, check_output, "\"xref_summary\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, check_output, "\"diagnostic_count\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, check_output, "\"page_count\":1") != null);
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

test "extract CLI reconstructs financial table cells across text json and markdown" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateTablePdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-table-cli-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var text_buf: [96]u8 = undefined;
    const text_path = try std.fmt.bufPrint(&text_buf, "pdf-parser-table-cli-{x}.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(text_path);
    defer runtime.deleteFileCwd(text_path);
    try runExtract(allocator, &.{ "-o", text_path, input_path });
    const text_output = try runtime.readFileAllocAlignedCwd(allocator, text_path, .fromByteUnits(1));
    defer allocator.free(text_output);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "Year Revenue Margin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "2019 100 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "YearRevenueMargin") == null);

    var json_buf: [96]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_buf, "pdf-parser-table-cli-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(json_path);
    defer runtime.deleteFileCwd(json_path);
    try runExtract(allocator, &.{ "--format", "json", "-o", json_path, input_path });
    const json_output = try runtime.readFileAllocAlignedCwd(allocator, json_path, .fromByteUnits(1));
    defer allocator.free(json_output);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"tables\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"text\":\"Revenue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"text\":\"140\"") != null);

    var markdown_buf: [96]u8 = undefined;
    const markdown_path = try std.fmt.bufPrint(&markdown_buf, "pdf-parser-table-cli-{x}.md", .{std.testing.random_seed});
    runtime.deleteFileCwd(markdown_path);
    defer runtime.deleteFileCwd(markdown_path);
    try runExtract(allocator, &.{ "--format", "markdown", "-o", markdown_path, input_path });
    const markdown_output = try runtime.readFileAllocAlignedCwd(allocator, markdown_path, .fromByteUnits(1));
    defer allocator.free(markdown_output);
    try std.testing.expect(std.mem.indexOf(u8, markdown_output, "| Year | Revenue | Margin |") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_output, "| 2021 | 140 | 25 |") != null);
}

test "extract CLI includes AcroForm field values in text and structured JSON" {
    const testpdf = @import("testpdf.zig");
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateAllFormFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    var input_buf: [96]u8 = undefined;
    const input_path = try std.fmt.bufPrint(&input_buf, "pdf-parser-form-cli-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(input_path);
    defer runtime.deleteFileCwd(input_path);

    const input_file = try runtime.createFileCwd(input_path);
    try runtime.writeAllFile(input_file, pdf_data);
    runtime.closeFile(input_file);

    var text_buf: [96]u8 = undefined;
    const text_path = try std.fmt.bufPrint(&text_buf, "pdf-parser-form-cli-{x}.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(text_path);
    defer runtime.deleteFileCwd(text_path);
    try runExtract(allocator, &.{ "-o", text_path, input_path });
    const text_output = try runtime.readFileAllocAlignedCwd(allocator, text_path, .fromByteUnits(1));
    defer allocator.free(text_output);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "All Fields") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "email user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "country USA") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "ok_button") == null);

    var json_buf: [96]u8 = undefined;
    const json_path = try std.fmt.bufPrint(&json_buf, "pdf-parser-form-cli-{x}.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(json_path);
    defer runtime.deleteFileCwd(json_path);
    try runExtract(allocator, &.{ "--format", "json", "-o", json_path, input_path });
    const json_output = try runtime.readFileAllocAlignedCwd(allocator, json_path, .fromByteUnits(1));
    defer allocator.free(json_output);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"form_fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"name\": \"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"type\": \"choice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"value\": \"USA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"text\": \"All Fields\\nemail user@example.com\\ncountry USA\"") != null);

    var adaptive_text_buf: [112]u8 = undefined;
    const adaptive_text_path = try std.fmt.bufPrint(&adaptive_text_buf, "pdf-parser-form-cli-{x}-adaptive.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(adaptive_text_path);
    defer runtime.deleteFileCwd(adaptive_text_path);
    try runExtract(allocator, &.{ "--adaptive", "-o", adaptive_text_path, input_path });
    const adaptive_text_output = try runtime.readFileAllocAlignedCwd(allocator, adaptive_text_path, .fromByteUnits(1));
    defer allocator.free(adaptive_text_output);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_text_output, "email user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_text_output, "country USA") != null);

    var adaptive_json_buf: [112]u8 = undefined;
    const adaptive_json_path = try std.fmt.bufPrint(&adaptive_json_buf, "pdf-parser-form-cli-{x}-adaptive.json", .{std.testing.random_seed});
    runtime.deleteFileCwd(adaptive_json_path);
    defer runtime.deleteFileCwd(adaptive_json_path);
    try runExtract(allocator, &.{ "--adaptive", "--format", "json", "-o", adaptive_json_path, input_path });
    const adaptive_json_output = try runtime.readFileAllocAlignedCwd(allocator, adaptive_json_path, .fromByteUnits(1));
    defer allocator.free(adaptive_json_output);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_json_output, "\"form_fields\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_json_output, "\"name\":\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_json_output, "\"type\":\"choice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_json_output, "\"value\":\"USA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, adaptive_json_output, "\"chosen_source\":\"manual\"") != null);
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

fn writeFormFieldsJson(doc: *zpdf.Document, allocator: std.mem.Allocator, writer: anytype) !void {
    const fields = doc.getFormFields(allocator) catch {
        try writer.writeAll("[]");
        return;
    };
    defer zpdf.Document.freeFormFields(allocator, fields);

    try writer.writeAll("[");
    for (fields, 0..) |field, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\"name\": \"");
        try writeJsonEscapedString(writer, field.name);
        try writer.writeAll("\", \"type\": \"");
        try writer.writeAll(formFieldTypeName(field.field_type));
        try writer.writeAll("\"");
        if (field.value) |value| {
            try writer.writeAll(", \"value\": \"");
            try writeJsonEscapedString(writer, value);
            try writer.writeAll("\"");
        } else {
            try writer.writeAll(", \"value\": null");
        }
        if (field.rect) |rect| {
            try writer.print(", \"rect\": [{d:.1}, {d:.1}, {d:.1}, {d:.1}]", .{
                rect[0], rect[1], rect[2], rect[3],
            });
        }
        try writer.writeAll("}");
    }
    if (fields.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("]");
}

fn formFieldTypeName(field_type: zpdf.Document.FieldType) []const u8 {
    return switch (field_type) {
        .text => "text",
        .button => "button",
        .choice => "choice",
        .signature => "signature",
        .unknown => "unknown",
    };
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
