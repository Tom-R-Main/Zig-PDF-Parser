//! Integration Tests for pdf-parser
//!
//! Tests the full parsing and extraction pipeline using generated PDFs.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");
const testpdf = @import("testpdf.zig");

fn expectIndexBefore(haystack: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, haystack, before) orelse return error.MissingBeforeNeedle;
    const after_index = std.mem.indexOf(u8, haystack, after) orelse return error.MissingAfterNeedle;
    try std.testing.expect(before_index < after_index);
}

fn countNeedle(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |index| {
        count += 1;
        offset += index + needle.len;
    }
    return count;
}

fn expectJsonlLinesParse(allocator: std.mem.Allocator, jsonl: []const u8) !void {
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    var parsed_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("schema_name") != null);
        try std.testing.expect(parsed.value.object.get("schema_version") != null);
        try std.testing.expect(parsed.value.object.get("record_type") != null);
        try expectProvenanceObject(parsed.value);
        parsed_count += 1;
    }
    try std.testing.expect(parsed_count > 0);
}

fn expectProvenanceObject(value: std.json.Value) !void {
    const provenance = value.object.get("provenance") orelse return error.MissingProvenance;
    try std.testing.expect(provenance.object.get("document_id") != null);
    try std.testing.expect(provenance.object.get("source_id") != null);
    try std.testing.expect(provenance.object.get("input_sha256") != null);
    try std.testing.expect(provenance.object.get("artifact_id") != null);
    try std.testing.expect(provenance.object.get("page_index") != null);
    try std.testing.expect(provenance.object.get("bbox") != null);
    try std.testing.expect(provenance.object.get("source_kind") != null);
    try std.testing.expect(provenance.object.get("confidence") != null);
    try std.testing.expect(provenance.object.get("span_ids") != null);
    try std.testing.expect(provenance.object.get("block_ids") != null);
    try std.testing.expect(provenance.object.get("chunk_ids") != null);
    try std.testing.expect(provenance.object.get("route_trace_ids") != null);
    try std.testing.expect(provenance.object.get("route_reasons") != null);
}

test "parse minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "extract text from minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test123");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));

    // Should contain our test text
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Test123") != null);
}

test "Sleisenger Symbol reduction decodes exact Adobe glyph-name Unicode" {
    const allocator = std.testing.allocator;
    const pdf_data = try testpdf.generateSleisengerSymbolNamesPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const output = try doc.extractTextStructured(0, allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("δγ −↑+βα", std.mem.trim(u8, output, " \t\r\n\x0c"));

    const pages = [_]usize{0};
    var diagnostics = try doc.inspectExtraction(allocator, &pages);
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 8), diagnostics.mapped_glyph_count);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.unmapped_glyph_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.fonts.len);
    try std.testing.expectEqual(@as(usize, 8), diagnostics.fonts[0].count(.glyph_name));
}

test "Sleisenger MathematicalPi reduction decodes scoped private glyph names" {
    const allocator = std.testing.allocator;
    const pdf_data = try testpdf.generateSleisengerMathematicalPiPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const output = try doc.extractTextStructured(0, allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "BMI <25 BMI >30 IRP ≥ upper limit → muscle",
        std.mem.trim(u8, output, " \t\r\n\x0c"),
    );

    const pages = [_]usize{0};
    var diagnostics = try doc.inspectExtraction(allocator, &pages);
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 0), diagnostics.unmapped_glyph_count);

    var glyph_name_count: usize = 0;
    for (diagnostics.fonts) |font| glyph_name_count += font.count(.glyph_name);
    try std.testing.expectEqual(@as(usize, 4), glyph_name_count);
}

test "structured extraction preserves Form XObject text omitted by partial tags" {
    const allocator = std.testing.allocator;
    const pdf_data = try testpdf.generatePartiallyTaggedFormXObjectPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const output = try doc.extractTextStructured(0, allocator);
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "Tagged main Form-only recall text",
        std.mem.trim(u8, output, " \t\r\n\x0c"),
    );

    const pages = [_]usize{0};
    var diagnostics = try doc.inspectExtraction(allocator, &pages);
    defer diagnostics.deinit();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.form_xobjects_decoded);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.pages_selected_full_context);
    try std.testing.expect(diagnostics.selection_missing_codepoints > 0);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.selection_extra_codepoints);
}

test "page tree resolves an indirect Kids array" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIndirectKidsPdf(allocator, "IndirectKids");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "IndirectKids") != null);
}

test "adaptive extraction returns native spans routes traces and chunks" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Adaptive Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    try std.testing.expect(result.reconciled.spans.len > 0);
    try std.testing.expect(result.reconciled.blocks.len > 0);
    try std.testing.expect(result.reconciled.chunks.len > 0);
    try std.testing.expect(result.layout_blocks.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.page_routes.len);
    try std.testing.expect(result.region_routes.len > 0);
    try std.testing.expect(result.trace_records.len > 0);
    try std.testing.expectEqual(zpdf.adaptive.TraceStage.native_spans, result.trace_records[0].stage);

    const markdown = try result.render(allocator, .markdown);
    defer allocator.free(markdown);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Adaptive Test") != null);
}

test "adaptive OCR route invokes rasterizer and Tesseract adapter into fresh OCR spans" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateImageOnlyPdf(allocator);
    defer allocator.free(pdf_data);

    var pdf_buf: [96]u8 = undefined;
    const pdf_path = try std.fmt.bufPrint(&pdf_buf, "pdf-parser-ocr-adaptive-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(pdf_path);
    defer runtime.deleteFileCwd(pdf_path);

    const pdf_file = try runtime.createFileCwd(pdf_path);
    try runtime.writeAllFile(pdf_file, pdf_data);
    runtime.closeFile(pdf_file);

    const fake_rasterizer =
        \\#!/bin/sh
        \\last=""
        \\for arg do last="$arg"; done
        \\printf '\211PNG\r\n\032\n\000\000\000\rIHDR\000\000\003\350\000\000\007\320' > "$last.png"
        \\
    ;
    var raster_buf: [96]u8 = undefined;
    const raster_path = try std.fmt.bufPrint(&raster_buf, "pdf-parser-fake-raster-{x}.sh", .{std.testing.random_seed});
    runtime.deleteFileCwd(raster_path);
    defer runtime.deleteFileCwd(raster_path);
    const raster_file = try runtime.createFileCwd(raster_path);
    try runtime.writeAllFile(raster_file, fake_rasterizer);
    runtime.closeFile(raster_file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", raster_path }));
    var raster_exec_buf: [112]u8 = undefined;
    const raster_exec = try std.fmt.bufPrint(&raster_exec_buf, "./{s}", .{raster_path});

    const fake_tesseract =
        "#!/bin/sh\n" ++
        "printf '%s\\n' 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext'\n" ++
        "printf '%s\\n' '1\t1\t0\t0\t0\t0\t0\t0\t1000\t2000\t-1\t'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t1\t100\t200\t160\t40\t91\tScanned'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t2\t300\t200\t260\t40\t92\ttypewritten'\n" ++
        "printf '%s\\n' '5\t1\t1\t1\t1\t3\t600\t200\t120\t40\t93\ttext'\n";
    var tess_buf: [96]u8 = undefined;
    const tess_path = try std.fmt.bufPrint(&tess_buf, "pdf-parser-fake-tesseract-{x}.sh", .{std.testing.random_seed});
    runtime.deleteFileCwd(tess_path);
    defer runtime.deleteFileCwd(tess_path);
    const tess_file = try runtime.createFileCwd(tess_path);
    try runtime.writeAllFile(tess_file, fake_tesseract);
    runtime.closeFile(tess_file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", tess_path }));
    var tess_exec_buf: [112]u8 = undefined;
    const tess_exec = try std.fmt.bufPrint(&tess_exec_buf, "./{s}", .{tess_path});

    const doc = try zpdf.Document.openWithConfig(allocator, pdf_path, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{
        .ocr_config = .{
            .executable = tess_exec,
            .rasterizer_executable = raster_exec,
            .dpi = 300,
        },
    });
    defer result.deinit();

    try std.testing.expect(result.reconciled.spans.len >= 3);
    try std.testing.expect(result.reconciled.spans[0].chosen_source == .fresh_ocr);

    const text = try result.render(allocator, .text);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Scanned typewritten text") != null);

    var saw_ocr_recognize = false;
    for (result.trace_records) |record| {
        if (record.stage == .ocr_recognize and record.span_count == 3) {
            saw_ocr_recognize = true;
        }
    }
    try std.testing.expect(saw_ocr_recognize);
}

test "adaptive extraction preserves layout reading order for two columns" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTwoColumnPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const text = try result.render(allocator, .text);
    defer allocator.free(text);

    const labels = [_][]const u8{
        "Chapter 1",
        "Left column first line",
        "Left column second line",
        "Left column third line",
        "Right column first line",
        "Right column second line",
        "Right column third line",
        "42",
    };
    var cursor: usize = 0;
    for (labels) |label| {
        const found = std.mem.indexOf(u8, text[cursor..], label) orelse return error.MissingExpectedText;
        cursor += found + label.len;
    }
}

test "adaptive extraction renders reconstructed complex financial tables" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateComplexFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const text = try result.render(allocator, .text);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Table 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Account Revenue Expense Net") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Total revenue 1,200 (950) 250") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Services* -300 (450) (750)\n* excludes setup fees") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Totalrevenue") == null);

    var saw_table_model = false;
    for (result.reconciled.spans) |span| {
        if (span.chosen_source == .table_model) saw_table_model = true;
    }
    try std.testing.expect(saw_table_model);
}

test "versioned schema renders native document manifest spans blocks chunks and debug assets" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const json = try zpdf.schema.renderArtifactJson(allocator, &result, .{
        .document_id = "clean-native",
        .source_id = "external-clean-native",
        .input_sha256 = "fixture-hash",
        .page_count = doc.pageCount(),
        .encrypted = doc.isEncrypted(),
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("document_manifest", parsed.value.object.get("schema_name").?.string);
    try std.testing.expectEqualStrings("0.9.0", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings("document_manifest", parsed.value.object.get("record_type").?.string);
    try std.testing.expectEqualStrings("external-clean-native", parsed.value.object.get("source_id").?.string);
    try expectProvenanceObject(parsed.value);
    try std.testing.expectEqualStrings("lifecycle", parsed.value.object.get("provenance").?.object.get("source_kind").?.string);
    try std.testing.expectEqualStrings("external-clean-native", parsed.value.object.get("provenance").?.object.get("source_id").?.string);
    try std.testing.expectEqualStrings("fixture-hash", parsed.value.object.get("provenance").?.object.get("input_sha256").?.string);
    try std.testing.expectEqual(false, parsed.value.object.get("corrupt").?.bool);
    const encryption = parsed.value.object.get("encryption") orelse return error.MissingEncryptionInfo;
    try std.testing.expectEqual(false, encryption.object.get("encrypted").?.bool);
    try std.testing.expectEqual(false, encryption.object.get("requires_password").?.bool);
    try std.testing.expectEqual(false, encryption.object.get("authenticated").?.bool);
    try std.testing.expectEqualStrings("none", encryption.object.get("auth_type").?.string);
    try std.testing.expectEqual(@as(i64, 0), encryption.object.get("encryption_version").?.integer);
    try std.testing.expect(encryption.object.get("permissions") != null);
    try std.testing.expect(parsed.value.object.get("route_counts") != null);
    try std.testing.expect(parsed.value.object.get("artifact_counts") != null);
    try std.testing.expect(parsed.value.object.get("extraction_counts") != null);
    try std.testing.expect(parsed.value.object.get("capability_coverage") != null);
    try std.testing.expect(parsed.value.object.get("output_artifacts") != null);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("warnings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("errors").?.array.items.len);
    try std.testing.expectEqual(true, parsed.value.object.get("capability_coverage").?.object.get("native_text").?.bool);
    try std.testing.expectEqual(false, parsed.value.object.get("capability_coverage").?.object.get("formula_recognition").?.bool);
    const artifacts = parsed.value.object.get("output_artifacts").?.array.items;
    try std.testing.expect(artifacts.len >= 7);
    try std.testing.expectEqualStrings("spans", artifacts[0].object.get("artifact_name").?.string);
    try std.testing.expectEqual(@as(usize, 64), artifacts[0].object.get("sha256").?.string.len);
    const spans = parsed.value.object.get("spans").?.array.items;
    try std.testing.expect(spans.len > 0);
    try expectProvenanceObject(spans[0]);
    try std.testing.expectEqualStrings("external-clean-native", spans[0].object.get("source_id").?.string);
    try std.testing.expectEqualStrings("external-clean-native", spans[0].object.get("provenance").?.object.get("source_id").?.string);
    try std.testing.expectEqualStrings("native", spans[0].object.get("provenance").?.object.get("source_kind").?.string);
    try std.testing.expect(spans[0].object.get("provenance").?.object.get("route_trace_ids").?.array.items.len > 0);
    const blocks = parsed.value.object.get("blocks").?.array.items;
    try std.testing.expect(blocks.len > 0);
    try expectProvenanceObject(blocks[0]);
    const chunks = parsed.value.object.get("rag_chunks").?.array.items;
    try std.testing.expect(chunks.len > 0);
    try expectProvenanceObject(chunks[0]);
    try std.testing.expectEqualStrings("external-clean-native", chunks[0].object.get("source_id").?.string);
    const debug_assets = parsed.value.object.get("debug_assets").?.array.items;
    try std.testing.expect(debug_assets.len > 0);
    try expectProvenanceObject(debug_assets[0]);
    try std.testing.expectEqualStrings("0.9.0", debug_assets[0].object.get("schema_version").?.string);
    try std.testing.expect(debug_assets[0].object.get("asset_kind") != null);
    try std.testing.expect(debug_assets[0].object.get("path") != null);
    try std.testing.expectEqual(.null, debug_assets[0].object.get("path").?);
    try std.testing.expect(debug_assets[0].object.get("uri") != null);
    try std.testing.expect(debug_assets[0].object.get("sha256") != null);
    try std.testing.expect(debug_assets[0].object.get("byte_length") != null);
    try std.testing.expect(debug_assets[0].object.get("layers") != null);
    try std.testing.expectEqualStrings("debug", debug_assets[0].object.get("provenance").?.object.get("source_kind").?.string);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_name\":\"document_manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":\"0.9.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"block\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"rag_chunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"debug_asset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bbox\":{\"x0\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_sha256\":\"fixture-hash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_id\":\"external-clean-native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provenance\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"asset_kind\":\"page_overlay_svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"asset_kind\":\"table_grid_overlay_svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"asset_kind\":\"ocr_route_overlay_svg\"") != null);
}

test "versioned schema materializes visual review assets when directory is supplied" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateMergedCellFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    var dir_buf: [96]u8 = undefined;
    const asset_dir = try std.fmt.bufPrint(&dir_buf, "pdf-parser-debug-assets-{x}", .{std.testing.random_seed});
    runtime.deleteTreeCwd(asset_dir);
    defer runtime.deleteTreeCwd(asset_dir);

    const json = try zpdf.schema.renderArtifactJson(allocator, &result, .{
        .document_id = "visual-assets",
        .source_id = "external-visual-assets",
        .debug_assets_dir = asset_dir,
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const debug_assets = parsed.value.object.get("debug_assets").?.array.items;
    try std.testing.expect(debug_assets.len >= 9);

    var saw_table_grid_record = false;
    var saw_glyph_trace_record = false;
    for (debug_assets) |asset| {
        try expectProvenanceObject(asset);
        try std.testing.expectEqualStrings("external-visual-assets", asset.object.get("source_id").?.string);
        try std.testing.expect(asset.object.get("path") != null);
        if (asset.object.get("path").? == .string) {
            try std.testing.expectEqual(@as(usize, 64), asset.object.get("sha256").?.string.len);
            try std.testing.expect(asset.object.get("byte_length").?.integer > 0);
        }
        if (std.mem.eql(u8, asset.object.get("asset_kind").?.string, "table_grid_overlay_svg")) saw_table_grid_record = true;
        if (std.mem.eql(u8, asset.object.get("asset_kind").?.string, "glyph_trace_jsonl")) saw_glyph_trace_record = true;
    }
    try std.testing.expect(saw_table_grid_record);
    try std.testing.expect(saw_glyph_trace_record);

    const table_grid_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.table-grid.svg" });
    defer allocator.free(table_grid_path);
    const table_grid = try runtime.readFileAllocAlignedCwd(allocator, table_grid_path, .fromByteUnits(1));
    defer allocator.free(table_grid);
    try std.testing.expect(std.mem.indexOf(u8, table_grid, "id=\"table-grid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, table_grid, "class=\"table-grid-cell\"") != null);

    const span_block_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.span-block-ids.svg" });
    defer allocator.free(span_block_path);
    const span_block = try runtime.readFileAllocAlignedCwd(allocator, span_block_path, .fromByteUnits(1));
    defer allocator.free(span_block);
    try std.testing.expect(std.mem.indexOf(u8, span_block, "id=\"span-block-id-overlay\"") != null);

    const low_conf_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.low-confidence.svg" });
    defer allocator.free(low_conf_path);
    const low_conf = try runtime.readFileAllocAlignedCwd(allocator, low_conf_path, .fromByteUnits(1));
    defer allocator.free(low_conf);
    try std.testing.expect(std.mem.indexOf(u8, low_conf, "id=\"low-confidence-regions\"") != null);

    const ocr_route_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.ocr-routes.svg" });
    defer allocator.free(ocr_route_path);
    const ocr_route = try runtime.readFileAllocAlignedCwd(allocator, ocr_route_path, .fromByteUnits(1));
    defer allocator.free(ocr_route);
    try std.testing.expect(std.mem.indexOf(u8, ocr_route, "id=\"ocr-route-overlay\"") != null);

    const glyph_trace_path = try std.fs.path.join(allocator, &.{ asset_dir, "page-0001.glyph-trace.jsonl" });
    defer allocator.free(glyph_trace_path);
    const glyph_trace = try runtime.readFileAllocAlignedCwd(allocator, glyph_trace_path, .fromByteUnits(1));
    defer allocator.free(glyph_trace);
    try std.testing.expect(std.mem.indexOf(u8, glyph_trace, "\"record_type\":\"glyph_trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, glyph_trace, "\"unicode_map_error\"") != null);
}

test "versioned artifact jsonl starts with manifest then typed records" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Schema JSONL");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const jsonl = try zpdf.schema.renderArtifactJsonl(allocator, &result, .{
        .document_id = "jsonl-fixture",
        .source_id = "external-jsonl",
    });
    defer allocator.free(jsonl);

    try std.testing.expect(std.mem.startsWith(u8, jsonl, "{\"schema_name\":\"document_manifest\""));
    const first_newline = std.mem.indexOfScalar(u8, jsonl, '\n') orelse return error.MissingJsonlRecord;
    const manifest = try std.json.parseFromSlice(std.json.Value, allocator, jsonl[0..first_newline], .{});
    defer manifest.deinit();
    try std.testing.expectEqualStrings("document_manifest", manifest.value.object.get("record_type").?.string);
    try std.testing.expectEqualStrings("external-jsonl", manifest.value.object.get("source_id").?.string);
    try expectProvenanceObject(manifest.value);
    try std.testing.expectEqualStrings("external-jsonl", manifest.value.object.get("provenance").?.object.get("source_id").?.string);
    try std.testing.expect(manifest.value.object.get("output_artifacts") != null);
    try std.testing.expect(manifest.value.object.get("extraction_counts") != null);
    try std.testing.expect(manifest.value.object.get("capability_coverage") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl[first_newline + 1 ..], "\"schema_version\":\"0.9.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl[first_newline + 1 ..], "\"record_type\":\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"record_type\":\"route_trace\"") != null);
    try expectJsonlLinesParse(allocator, jsonl);
}

test "specialist protocol emits batch request records for routed table formula regions" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTableFormulaPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const json = try zpdf.schema.renderArtifactJson(allocator, &result, .{
        .document_id = "specialist-table-formula",
        .source_id = "external-specialist",
        .input_sha256 = "specialist-hash",
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const requests = parsed.value.object.get("specialist_requests").?.array.items;
    try std.testing.expect(requests.len > 0);
    try expectProvenanceObject(requests[0]);
    try std.testing.expectEqualStrings("0.9.0", requests[0].object.get("schema_version").?.string);
    try std.testing.expectEqualStrings("specialist_request", requests[0].object.get("record_type").?.string);
    try std.testing.expectEqualStrings("external-specialist", requests[0].object.get("source_id").?.string);
    try std.testing.expect(requests[0].object.get("requested_kind") != null);
    try std.testing.expect(requests[0].object.get("requested_outputs") != null);
    try std.testing.expect(requests[0].object.get("signals") != null);
    try std.testing.expect(requests[0].object.get("spans") != null);
    try std.testing.expect(requests[0].object.get("blocks") != null);
    try std.testing.expectEqualStrings("lifecycle", requests[0].object.get("provenance").?.object.get("source_kind").?.string);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"specialist_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"specialist_request_ids\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"specialist_status\":\"requested\"") != null);
}

test "artifact jsonl and streaming jsonl expose specialist request ordering" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTableFormulaPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const jsonl = try zpdf.schema.renderArtifactJsonl(allocator, &result, .{
        .document_id = "specialist-jsonl",
        .source_id = "external-jsonl-specialist",
    });
    defer allocator.free(jsonl);

    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"record_type\":\"specialist_request\"") != null);
    try expectIndexBefore(jsonl, "\"record_type\":\"route_trace\"", "\"record_type\":\"specialist_request\"");
    try expectJsonlLinesParse(allocator, jsonl);

    const stream_pdf_data = try testpdf.generateMixedNativeScanPdf(allocator);
    defer allocator.free(stream_pdf_data);

    const stream_doc = try zpdf.Document.openFromMemory(allocator, stream_pdf_data, zpdf.ErrorConfig.permissive());
    defer stream_doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);
    const summary = try stream_doc.extractAdaptiveStreaming(allocator, writer, .{
        .schema_options = .{
            .document_id = "specialist-stream",
            .source_id = "external-stream-specialist",
        },
    });

    try std.testing.expect(summary.artifact_counts.specialist_requests > 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event_type\":\"specialist_request\"") != null);
    try expectIndexBefore(output.items, "\"event_type\":\"route_trace\"", "\"event_type\":\"specialist_request\"");
    try expectIndexBefore(output.items, "\"event_type\":\"specialist_request\"", "\"event_type\":\"span\"");
    try expectJsonlLinesParse(allocator, output.items);
}

test "streaming adaptive jsonl emits manifest page artifacts and document finish in order" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "Stream Page One", "Stream Page Two" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const summary = try doc.extractAdaptiveStreaming(allocator, writer, .{
        .schema_options = .{
            .document_id = "stream-native",
            .source_id = "external-stream",
            .page_count = doc.pageCount(),
            .encrypted = doc.isEncrypted(),
        },
    });

    try std.testing.expectEqual(@as(usize, 2), summary.page_count);
    try std.testing.expect(summary.event_count > 0);
    try std.testing.expect(std.mem.startsWith(u8, output.items, "{\"schema_name\":\"document_manifest\""));
    const first_newline = std.mem.indexOfScalar(u8, output.items, '\n') orelse return error.MissingJsonlRecord;
    const manifest = try std.json.parseFromSlice(std.json.Value, allocator, output.items[0..first_newline], .{});
    defer manifest.deinit();
    try std.testing.expectEqual(true, manifest.value.object.get("streaming").?.bool);
    try std.testing.expectEqualStrings("external-stream", manifest.value.object.get("source_id").?.string);
    try expectProvenanceObject(manifest.value);
    try std.testing.expectEqualStrings("external-stream", manifest.value.object.get("provenance").?.object.get("source_id").?.string);
    try std.testing.expectEqualStrings("lifecycle", manifest.value.object.get("provenance").?.object.get("source_kind").?.string);
    try std.testing.expectEqual(true, manifest.value.object.get("capability_coverage").?.object.get("streaming").?.bool);
    const artifacts = manifest.value.object.get("output_artifacts").?.array.items;
    try std.testing.expect(artifacts.len >= 7);
    try std.testing.expectEqual(.null, artifacts[0].object.get("sha256").?);
    try expectIndexBefore(output.items, "\"event_type\":\"document_manifest\"", "\"event_type\":\"page_started\"");
    try expectIndexBefore(output.items, "\"event_type\":\"page_started\"", "\"event_type\":\"span\"");
    try expectIndexBefore(output.items, "\"event_type\":\"span\"", "\"event_type\":\"page_finished\"");
    try expectIndexBefore(output.items, "\"event_type\":\"page_finished\"", "\"event_type\":\"document_finished\"");
    try expectJsonlLinesParse(allocator, output.items);
}

test "streaming adaptive jsonl emits financial table before page finish" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const pdf_data = try testpdf.generateMergedCellFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    var dir_buf: [96]u8 = undefined;
    const asset_dir = try std.fmt.bufPrint(&dir_buf, "pdf-parser-stream-debug-assets-{x}", .{std.testing.random_seed});
    runtime.deleteTreeCwd(asset_dir);
    defer runtime.deleteTreeCwd(asset_dir);

    const summary = try doc.extractAdaptiveStreaming(allocator, writer, .{ .schema_options = .{ .document_id = "stream-table", .debug_assets_dir = asset_dir } });
    try std.testing.expect(summary.artifact_counts.tables > 0);
    try std.testing.expect(summary.artifact_counts.debug_assets > 0);
    try expectIndexBefore(output.items, "\"record_type\":\"table\"", "\"event_type\":\"page_finished\"");
    try expectIndexBefore(output.items, "\"asset_kind\":\"table_grid_overlay_svg\"", "\"event_type\":\"page_finished\"");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"colspan\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"record_type\":\"debug_asset\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"path\":\"") != null);
    try expectJsonlLinesParse(allocator, output.items);
}

test "streaming adaptive jsonl links multipage financial tables" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMultipageFinancialStatementPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const summary = try doc.extractAdaptiveStreaming(allocator, writer, .{ .schema_options = .{ .document_id = "stream-multipage-table" } });
    try std.testing.expect(summary.artifact_counts.tables >= 2);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"logical_table_id\":\"logical-table-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"table_part_index\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"continued_from_table_id\":\"table-0\"") != null);
    try expectJsonlLinesParse(allocator, output.items);
}

test "streaming adaptive jsonl exposes mixed native scan OCR route traces" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMixedNativeScanPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    _ = try doc.extractAdaptiveStreaming(allocator, writer, .{ .schema_options = .{ .document_id = "stream-mixed-scan" } });
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"event_type\":\"route_trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"route\":\"queue_ocr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"image_dominant\"") != null);
    try expectJsonlLinesParse(allocator, output.items);
}

test "streaming adaptive jsonl emits chunks before document finish" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const summary = try doc.extractAdaptiveStreaming(allocator, writer, .{ .schema_options = .{ .document_id = "stream-chunks" } });
    try std.testing.expect(summary.artifact_counts.rag_chunks > 0);
    try expectIndexBefore(output.items, "\"record_type\":\"rag_chunk\"", "\"event_type\":\"document_finished\"");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"source_block_ids\"") != null);
}

test "streaming adaptive jsonl processes multipage document without batch result" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{
        "Large stream page 01",
        "Large stream page 02",
        "Large stream page 03",
        "Large stream page 04",
        "Large stream page 05",
        "Large stream page 06",
        "Large stream page 07",
        "Large stream page 08",
    };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const summary = try doc.extractAdaptiveStreaming(allocator, writer, .{ .schema_options = .{ .document_id = "stream-large" } });
    try std.testing.expectEqual(pages.len, summary.page_count);
    try std.testing.expectEqual(pages.len, countNeedle(output.items, "\"event_type\":\"page_started\""));
    try std.testing.expectEqual(pages.len, countNeedle(output.items, "\"event_type\":\"page_finished\""));
    try std.testing.expect(summary.artifact_counts.spans >= pages.len);
    try expectJsonlLinesParse(allocator, output.items);
}

test "versioned schema exposes financial table cell span metadata" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMergedCellFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const json = try zpdf.schema.renderArtifactJson(allocator, &result, .{
        .document_id = "merged-cells",
        .source_id = "external-merged-cells",
    });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const tables = parsed.value.object.get("tables").?.array.items;
    try std.testing.expect(tables.len > 0);
    try expectProvenanceObject(tables[0]);
    try std.testing.expectEqualStrings("0.9.0", tables[0].object.get("schema_version").?.string);
    try std.testing.expect(tables[0].object.get("logical_table_id") != null);
    try std.testing.expect(tables[0].object.get("table_part_index") != null);
    try std.testing.expect(tables[0].object.get("continued_from_table_id") != null);
    try std.testing.expect(tables[0].object.get("continued_to_table_id") != null);
    try std.testing.expect(tables[0].object.get("source_span_ids") != null);
    try std.testing.expectEqualStrings("table_model", tables[0].object.get("provenance").?.object.get("source_kind").?.string);
    const cells = tables[0].object.get("rows").?.array.items[0].object.get("cells").?.array.items;
    try std.testing.expect(cells.len > 0);
    try std.testing.expectEqualStrings("table_cell", cells[0].object.get("schema_name").?.string);
    try std.testing.expectEqualStrings("0.9.0", cells[0].object.get("schema_version").?.string);
    try std.testing.expect(cells[0].object.get("cell_id") != null);
    try std.testing.expectEqualStrings("external-merged-cells", cells[0].object.get("source_id").?.string);
    try std.testing.expect(cells[0].object.get("raw_text") != null);
    try std.testing.expect(cells[0].object.get("normalized_text") != null);
    try std.testing.expect(cells[0].object.get("numeric") != null);
    try expectProvenanceObject(cells[0]);
    try std.testing.expectEqualStrings("external-merged-cells", cells[0].object.get("provenance").?.object.get("source_id").?.string);
    try std.testing.expectEqualStrings("table_model", cells[0].object.get("provenance").?.object.get("source_kind").?.string);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"table\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"table_cell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"logical_table_id\":\"logical-table-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Operating metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"raw_text\":\"Operating metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"normalized_text\":\"Operating metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"colspan\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"numeric\":{\"is_numeric\":true,\"value\":1200.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_span_ids\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bbox\":{\"x0\":") != null);
}

test "versioned schema exposes AcroForm field records" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateAllFormFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const json = try zpdf.schema.renderArtifactJson(allocator, &result, .{ .document_id = "forms" });
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const fields = parsed.value.object.get("form_fields").?.array.items;
    try std.testing.expect(fields.len > 0);
    try expectProvenanceObject(fields[0]);
    try std.testing.expectEqualStrings("form", fields[0].object.get("provenance").?.object.get("source_kind").?.string);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"record_type\":\"form_field\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"email\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"choice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value\":\"USA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source_span_id\":\"span-") != null);
}

test "versioned schema exposes mixed scan OCR route traces" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMixedNativeScanPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var result = try doc.extractAdaptive(allocator, .{});
    defer result.deinit();

    const trace = try zpdf.schema.renderTraceJson(allocator, &result, "mixed-native-scan");
    defer allocator.free(trace);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trace, .{});
    defer parsed.deinit();
    const pages = parsed.value.object.get("pages").?.array.items;
    try std.testing.expect(pages.len > 0);
    try expectProvenanceObject(pages[0]);
    try std.testing.expectEqualStrings("lifecycle", pages[0].object.get("provenance").?.object.get("source_kind").?.string);

    try std.testing.expect(std.mem.indexOf(u8, trace, "\"record_type\":\"route_trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"route\":\"queue_ocr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"image_dominant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"stage\":\"ocr_recognize\"") != null);
}

test "parse multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "First Page", "Second Page", "Third Page" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 3), doc.pageCount());
}

test "extract all text from multi-page PDF" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "PageA", "PageB" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractAllText(runtime.arrayListWriter(&output, allocator));

    try std.testing.expect(std.mem.indexOf(u8, output.items, "PageA") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "PageB") != null);
}

test "parse TJ operator PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateTJPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));

    // TJ with spacing should produce "Hello World" (with space from -200 adjustment)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "World") != null);
}

test "page info extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const info = doc.getPageInfo(0);
    try std.testing.expect(info != null);

    // Should be letter size (612 x 792 points)
    try std.testing.expectApproxEqRel(@as(f64, 612), info.?.width, 0.1);
    try std.testing.expectApproxEqRel(@as(f64, 792), info.?.height, 0.1);
}

test "error tolerance - permissive mode" {
    const allocator = std.testing.allocator;

    // Create slightly malformed PDF
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    // Even with strict mode, a valid PDF should parse
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.strict());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "XRef parsing" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "XRef Test");
    defer allocator.free(pdf_data);

    // Use arena for parsed objects (like real usage)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Should have entries for objects 1-5 (and 0 for free list)
    try std.testing.expect(xref_table.entries.count() >= 5);
}

test "content lexer tokens" {
    const content = "BT /F1 12 Tf (Hello) Tj ET";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = zpdf.interpreter.ContentLexer.init(arena.allocator(), content);

    // BT operator
    const t1 = (try lexer.next()).?;
    try std.testing.expect(t1 == .operator);
    try std.testing.expectEqualStrings("BT", t1.operator);

    // /F1 name
    const t2 = (try lexer.next()).?;
    try std.testing.expect(t2 == .name);

    // 12 number
    const t3 = (try lexer.next()).?;
    try std.testing.expect(t3 == .number);

    // Tf operator
    const t4 = (try lexer.next()).?;
    try std.testing.expect(t4 == .operator);

    // (Hello) string
    const t5 = (try lexer.next()).?;
    try std.testing.expect(t5 == .string);

    // Tj operator
    const t6 = (try lexer.next()).?;
    try std.testing.expect(t6 == .operator);

    // ET operator
    const t7 = (try lexer.next()).?;
    try std.testing.expect(t7 == .operator);
}

test "decompression - uncompressed passthrough" {
    const allocator = std.testing.allocator;
    const data = "Hello uncompressed";

    // With no filter, should return data as-is (allocated copy)
    const result = try zpdf.decompress.decompressStream(allocator, data, null, null);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}

test "parse incremental PDF update" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    // Parse the XRef table - should follow /Prev chain
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var xref_table = try zpdf.xref.parseXRef(allocator, arena.allocator(), pdf_data);
    defer xref_table.deinit();

    // Object 4 should point to the NEW offset (from incremental update)
    const obj4_entry = xref_table.get(4);
    try std.testing.expect(obj4_entry != null);

    // The object 4 entry should exist and be in_use
    try std.testing.expectEqual(zpdf.xref.XRefEntry.EntryType.in_use, obj4_entry.?.entry_type);

    // Find where "Updated Text" appears in the PDF (should be at higher offset than "Original Text")
    const orig_pos = std.mem.indexOf(u8, pdf_data, "Original Text");
    const upd_pos = std.mem.indexOf(u8, pdf_data, "Updated Text");

    try std.testing.expect(orig_pos != null);
    try std.testing.expect(upd_pos != null);

    // Updated Text should come after Original Text (it's in the incremental section)
    try std.testing.expect(upd_pos.? > orig_pos.?);

    // Object 4's offset should point to the updated version
    // The updated object 4 starts just before "Updated Text"
    try std.testing.expect(obj4_entry.?.offset > orig_pos.?);
}

test "isEncrypted returns false for normal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Not encrypted");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    try std.testing.expect(!doc.isEncrypted());
}

test "isEncrypted returns true for encrypted PDF" {
    const allocator = std.testing.allocator;

    // Build a minimal PDF with /Encrypt in the trailer
    const pdf_data = try testpdf.generateEncryptedPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expect(doc.isEncrypted());
}

test "extract text from incremental PDF - gets updated content" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateIncrementalPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Should have 1 page
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));

    // Should extract "Updated Text" NOT "Original Text"
    // because incremental update replaced object 4
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Updated") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Original") == null);
}

test "page tree tolerates leaf node without /Type" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePdfWithoutPageType(allocator, "NoTypeTest");
    defer allocator.free(pdf_data);

    // Should still open and report 1 page (Fix 2: /Type default inference)
    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "NoTypeTest") != null);
}

test "inline image does not corrupt text extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateInlineImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));

    // Both text spans surrounding the inline image must be present (Fix 1: BI/EI skip)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "After") != null);
}

// =========================================================================
// New feature integration tests
// =========================================================================

test "metadata extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMetadataPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title != null);
    try std.testing.expectEqualStrings("Test Document", meta.title.?);
    try std.testing.expectEqualStrings("Test Author", meta.author.?);
    try std.testing.expectEqualStrings("Test Subject", meta.subject.?);
    try std.testing.expectEqualStrings("test, pdf, zpdf", meta.keywords.?);
    try std.testing.expectEqualStrings("TestGenerator", meta.creator.?);
    try std.testing.expectEqualStrings("zpdf", meta.producer.?);
}

test "metadata returns empty for PDF without Info dict" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No metadata");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    try std.testing.expect(meta.title == null);
    try std.testing.expect(meta.author == null);
}

test "outline extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateOutlinePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer {
        for (outline_items) |item| {
            allocator.free(@constCast(item.title));
        }
        allocator.free(outline_items);
    }

    try std.testing.expectEqual(@as(usize, 1), outline_items.len);
    try std.testing.expectEqualStrings("Chapter 1", outline_items[0].title);
    try std.testing.expect(outline_items[0].page != null);
    try std.testing.expectEqual(@as(usize, 0), outline_items[0].page.?);
    try std.testing.expectEqual(@as(u32, 0), outline_items[0].level);
}

test "outline returns empty for PDF without outlines" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No outlines");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const outline_items = try doc.getOutline(allocator);
    defer allocator.free(outline_items);

    try std.testing.expectEqual(@as(usize, 0), outline_items.len);
}

test "link extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateLinkPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);

    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expect(links[0].uri != null);
    try std.testing.expectEqualStrings("https://example.com", links[0].uri.?);
    // Check rect
    try std.testing.expectApproxEqRel(@as(f64, 100), links[0].rect[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 690), links[0].rect[1], 0.01);
}

test "links returns empty for page without annotations" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No links");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer allocator.free(links);

    try std.testing.expectEqual(@as(usize, 0), links.len);
}

test "form field extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateFormFieldPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);

    // Find text field
    var found_text = false;
    var found_button = false;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            found_text = true;
            try std.testing.expect(f.field_type == .text);
            try std.testing.expect(f.value != null);
            try std.testing.expectEqualStrings("John Doe", f.value.?);
        }
        if (std.mem.eql(u8, f.name, "submit")) {
            found_button = true;
            try std.testing.expect(f.field_type == .button);
        }
    }
    try std.testing.expect(found_text);
    try std.testing.expect(found_button);
}

test "form field extraction inherits parent type and value" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateInheritedWidgetFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 3), fields.len);

    var found_consent = false;
    var found_region = false;
    var found_phone = false;
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "consent.agree")) {
            found_consent = true;
            try std.testing.expectEqual(zpdf.Document.FieldType.button, field.field_type);
            try std.testing.expectEqualStrings("Yes", field.value.?);
        } else if (std.mem.eql(u8, field.name, "preferences.region")) {
            found_region = true;
            try std.testing.expectEqual(zpdf.Document.FieldType.choice, field.field_type);
            try std.testing.expectEqualStrings("EMEA", field.value.?);
        } else if (std.mem.eql(u8, field.name, "profile.phone")) {
            found_phone = true;
            try std.testing.expectEqual(zpdf.Document.FieldType.text, field.field_type);
            try std.testing.expectEqualStrings("555-0100", field.value.?);
        }
    }

    try std.testing.expect(found_consent);
    try std.testing.expect(found_region);
    try std.testing.expect(found_phone);

    const form_text = try doc.extractFormFieldText(allocator);
    defer allocator.free(form_text);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "consent.agree Yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "preferences.region EMEA") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "profile.phone 555-0100") != null);
}

test "structured text includes value-bearing form fields once" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateAllFormFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const page_text = try doc.extractTextStructured(0, allocator);
    defer allocator.free(page_text);

    try std.testing.expect(std.mem.indexOf(u8, page_text, "All Fields") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_text, "email user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_text, "country USA") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_text, "ok_button") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_text, "signature") == null);

    const form_text = try doc.extractFormFieldText(allocator);
    defer allocator.free(form_text);
    try std.testing.expectEqualStrings("email user@example.com\ncountry USA", form_text);

    const fast_text = try doc.extractAllTextFast(allocator);
    defer allocator.free(fast_text);
    try std.testing.expect(std.mem.indexOf(u8, fast_text, "email user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, fast_text, "country USA") != null);
}

test "realistic widget fields include nested and name-valued values" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateRealisticWidgetFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const form_text = try doc.extractFormFieldText(allocator);
    defer allocator.free(form_text);

    try std.testing.expect(std.mem.indexOf(u8, form_text, "profile.first_name Ada") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "profile.email ada@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "subscribe Yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "cadence Quarterly") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_text, "country USA") != null);
}

test "multipage financial statement extracts both pages" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMultipageFinancialStatementPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractAllText(runtime.arrayListWriter(&output, allocator));

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Statement page 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Cash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "1,000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Statement page 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Debt") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "(300)") != null);
}

test "multipage financial statement emits page-indexed table JSON" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMultipageFinancialStatementPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var page1_json: std.ArrayList(u8) = .empty;
    defer page1_json.deinit(allocator);
    try doc.writePageTablesJson(0, allocator, runtime.arrayListWriter(&page1_json, allocator));

    var page2_json: std.ArrayList(u8) = .empty;
    defer page2_json.deinit(allocator);
    try doc.writePageTablesJson(1, allocator, runtime.arrayListWriter(&page2_json, allocator));

    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"text\":\"Cash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"text\":\"1,000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"normalized_text\":\"1,000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"numeric\":{\"is_numeric\":true,\"value\":1000.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"logical_table_id\":\"logical-table-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"cell_id\":\"table-0-cell-1-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page1_json.items, "\"page\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, page2_json.items, "\"text\":\"Debt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page2_json.items, "\"text\":\"(300)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page2_json.items, "\"numeric\":{\"is_numeric\":true,\"value\":-300.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, page2_json.items, "\"page\":1") != null);
}

test "form fields returns empty for PDF without AcroForm" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No form");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer allocator.free(fields);

    try std.testing.expectEqual(@as(usize, 0), fields.len);
}

test "text search" {
    const allocator = std.testing.allocator;

    const pages = &[_][]const u8{ "Hello World", "Goodbye World", "Hello Again" };
    const pdf_data = try testpdf.generateMultiPagePdf(allocator, pages);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    // Search for "Hello" - should find 2 matches
    const results = try doc.search(allocator, "Hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(usize, 0), results[0].page); // Page 0
    try std.testing.expectEqual(@as(usize, 2), results[1].page); // Page 2
}

test "text search case insensitive" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "hello");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

test "text search no matches" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "notfound");
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "page labels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 0 should be "i" (lowercase roman)
    const label0 = doc.getPageLabel(allocator, 0);
    defer if (label0) |l| allocator.free(l);
    try std.testing.expect(label0 != null);
    try std.testing.expectEqualStrings("i", label0.?);

    // Page 1 should be "ii"
    const label1 = doc.getPageLabel(allocator, 1);
    defer if (label1) |l| allocator.free(l);
    try std.testing.expect(label1 != null);
    try std.testing.expectEqualStrings("ii", label1.?);

    // Page 2 should be "1" (decimal, starting at 1)
    const label2 = doc.getPageLabel(allocator, 2);
    defer if (label2) |l| allocator.free(l);
    try std.testing.expect(label2 != null);
    try std.testing.expectEqualStrings("1", label2.?);
}

test "page labels returns null for PDF without PageLabels" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No labels");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const label = doc.getPageLabel(allocator, 0);
    try std.testing.expect(label == null);
}

// =========================================================================
// decodePdfString unit tests
// =========================================================================

test "decodePdfString - plain ASCII passthrough" {
    const allocator = std.testing.allocator;
    const result = try zpdf.decodePdfString(allocator, "Hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "decodePdfString - empty string" {
    const allocator = std.testing.allocator;
    const result = try zpdf.decodePdfString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "decodePdfString - UTF-16BE BOM simple ASCII" {
    const allocator = std.testing.allocator;
    // FE FF 0048 0069 = "Hi"
    const input = "\xFE\xFF\x00\x48\x00\x69";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi", result);
}

test "decodePdfString - UTF-16BE with non-ASCII" {
    const allocator = std.testing.allocator;
    // FE FF 00E9 = "é" (U+00E9 → UTF-8: C3 A9)
    const input = "\xFE\xFF\x00\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\xC3\xA9", result); // "é" in UTF-8
}

test "decodePdfString - UTF-16BE CJK character" {
    const allocator = std.testing.allocator;
    // FE FF 4E2D = "中" (U+4E2D → UTF-8: E4 B8 AD)
    const input = "\xFE\xFF\x4E\x2D";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\xE4\xB8\xAD", result); // "中" in UTF-8
}

test "decodePdfString - PDFDocEncoding high byte" {
    const allocator = std.testing.allocator;
    // 0xE9 without BOM → Latin-1 "é" → UTF-8 C3 A9
    const input = "caf\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("caf\xC3\xA9", result);
}

test "decodePdfString - UTF-16BE Cafe with accent" {
    const allocator = std.testing.allocator;
    // FE FF 0043 0061 0066 00E9 = "Café"
    const input = "\xFE\xFF\x00\x43\x00\x61\x00\x66\x00\xE9";
    const result = try zpdf.decodePdfString(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Caf\xC3\xA9", result);
}

// =========================================================================
// Nested outline tests
// =========================================================================

test "nested outline with levels and siblings" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateNestedOutlinePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const items = try doc.getOutline(allocator);
    defer {
        for (items) |item| allocator.free(@constCast(item.title));
        allocator.free(items);
    }

    // Should have 3 items: Part I (level 0), Section 1.1 (level 1), Part II (level 0)
    try std.testing.expectEqual(@as(usize, 3), items.len);

    try std.testing.expectEqualStrings("Part I", items[0].title);
    try std.testing.expectEqual(@as(u32, 0), items[0].level);
    try std.testing.expect(items[0].page != null);
    try std.testing.expectEqual(@as(usize, 0), items[0].page.?);

    try std.testing.expectEqualStrings("Section 1.1", items[1].title);
    try std.testing.expectEqual(@as(u32, 1), items[1].level);

    try std.testing.expectEqualStrings("Part II", items[2].title);
    try std.testing.expectEqual(@as(u32, 0), items[2].level);
    try std.testing.expect(items[2].page != null);
    try std.testing.expectEqual(@as(usize, 1), items[2].page.?); // GoTo → page 2
}

test "outline with UTF-16BE encoded title" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateUtf16BePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const items = try doc.getOutline(allocator);
    defer {
        for (items) |item| allocator.free(@constCast(item.title));
        allocator.free(items);
    }

    try std.testing.expectEqual(@as(usize, 1), items.len);
    // "Café" decoded from UTF-16BE
    try std.testing.expectEqualStrings("Caf\xC3\xA9", items[0].title);
}

// =========================================================================
// Multi-link and GoTo link tests
// =========================================================================

test "multiple links with URI and GoTo" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMultiLinkPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const links = try doc.getPageLinks(0, allocator);
    defer zpdf.Document.freeLinks(allocator, links);

    // Should have 2 links (highlight annotation filtered out)
    try std.testing.expectEqual(@as(usize, 2), links.len);

    // First: URI link
    try std.testing.expect(links[0].uri != null);
    try std.testing.expectEqualStrings("https://example.org", links[0].uri.?);
    try std.testing.expect(links[0].dest_page == null);

    // Second: GoTo internal link → page 0
    try std.testing.expect(links[1].uri == null);
    try std.testing.expect(links[1].dest_page != null);
    try std.testing.expectEqual(@as(usize, 0), links[1].dest_page.?);
}

test "links out of range page returns error" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const result = doc.getPageLinks(999, allocator);
    try std.testing.expectError(error.PageNotFound, result);
}

// =========================================================================
// All form field types
// =========================================================================

test "all form field types: text, button, choice, signature" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateAllFormFieldsPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const fields = try doc.getFormFields(allocator);
    defer zpdf.Document.freeFormFields(allocator, fields);

    try std.testing.expectEqual(@as(usize, 4), fields.len);

    var found_text = false;
    var found_button = false;
    var found_choice = false;
    var found_sig = false;

    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "email")) {
            found_text = true;
            try std.testing.expect(f.field_type == .text);
            try std.testing.expect(f.value != null);
            try std.testing.expectEqualStrings("user@example.com", f.value.?);
            try std.testing.expect(f.rect != null);
        }
        if (std.mem.eql(u8, f.name, "ok_button")) {
            found_button = true;
            try std.testing.expect(f.field_type == .button);
            try std.testing.expect(f.value == null);
            try std.testing.expect(f.rect == null);
        }
        if (std.mem.eql(u8, f.name, "country")) {
            found_choice = true;
            try std.testing.expect(f.field_type == .choice);
            try std.testing.expectEqualStrings("USA", f.value.?);
        }
        if (std.mem.eql(u8, f.name, "signature")) {
            found_sig = true;
            try std.testing.expect(f.field_type == .signature);
        }
    }

    try std.testing.expect(found_text);
    try std.testing.expect(found_button);
    try std.testing.expect(found_choice);
    try std.testing.expect(found_sig);
}

// =========================================================================
// Extended page label tests
// =========================================================================

test "page labels - uppercase roman" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 0: uppercase roman → "I"
    const label0 = doc.getPageLabel(allocator, 0);
    defer if (label0) |l| allocator.free(l);
    try std.testing.expect(label0 != null);
    try std.testing.expectEqualStrings("I", label0.?);

    // Page 1: uppercase roman → "II"
    const label1 = doc.getPageLabel(allocator, 1);
    defer if (label1) |l| allocator.free(l);
    try std.testing.expect(label1 != null);
    try std.testing.expectEqualStrings("II", label1.?);
}

test "page labels - lowercase alpha" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 2: alpha lowercase → "a"
    const label2 = doc.getPageLabel(allocator, 2);
    defer if (label2) |l| allocator.free(l);
    try std.testing.expect(label2 != null);
    try std.testing.expectEqualStrings("a", label2.?);
}

test "page labels - prefix and custom start" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateExtendedPageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 3: decimal with prefix "App-" starting at 1 → "App-1"
    const label3 = doc.getPageLabel(allocator, 3);
    defer if (label3) |l| allocator.free(l);
    try std.testing.expect(label3 != null);
    try std.testing.expectEqualStrings("App-1", label3.?);

    // Page 4: → "App-2"
    const label4 = doc.getPageLabel(allocator, 4);
    defer if (label4) |l| allocator.free(l);
    try std.testing.expect(label4 != null);
    try std.testing.expectEqualStrings("App-2", label4.?);
}

test "page label out of range does not crash" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generatePageLabelPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    // Page 999 doesn't exist, but getPageLabel may still compute a label
    // from the last range. What matters is it doesn't crash.
    const label = doc.getPageLabel(allocator, 999);
    if (label) |l| allocator.free(l);
}

// =========================================================================
// Image detection tests
// =========================================================================

test "image detection" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator);
    defer zpdf.Document.freeImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqual(@as(u32, 640), images[0].width);
    try std.testing.expectEqual(@as(u32, 480), images[0].height);

    // CTM was "200 0 0 150 100 500 cm"
    try std.testing.expectApproxEqRel(@as(f64, 100), images[0].rect[0], 0.01);
    try std.testing.expectApproxEqRel(@as(f64, 500), images[0].rect[1], 0.01);
}

test "ruling line detection from stroked rectangle" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateRulingLinesPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.strict());
    defer doc.close();

    const lines = try doc.getPageRulingLines(0, allocator);
    defer zpdf.Document.freeRulingLines(allocator, lines);

    var horizontal_count: usize = 0;
    var vertical_count: usize = 0;
    for (lines) |line| {
        switch (line.orientation) {
            .horizontal => horizontal_count += 1,
            .vertical => vertical_count += 1,
        }
    }

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqual(@as(usize, 2), horizontal_count);
    try std.testing.expectEqual(@as(usize, 2), vertical_count);
}

test "ruled financial table JSON preserves cell geometry metadata" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateRuledFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try doc.writePageTablesJson(0, allocator, runtime.arrayListWriter(&json, allocator));

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"Account\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"(200)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"role\":\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"rowspan\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"colspan\":1") != null);
}

test "ruled multiline table keeps wrapped label in one cell" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateRuledMultilineFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try doc.writePageTablesJson(0, allocator, runtime.arrayListWriter(&json, allocator));

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"Deferred revenue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"1,250\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"(300)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"-25\"") != null);
}

test "merged ruled header reports colspan" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMergedCellFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try doc.writePageTablesJson(0, allocator, runtime.arrayListWriter(&json, allocator));

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"Operating metrics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"colspan\":3") != null);
}

test "rowspan ruled section label reports rowspan" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateRowspanFinancialTablePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try doc.writePageTablesJson(0, allocator, runtime.arrayListWriter(&json, allocator));

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"Assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"rowspan\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"300\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"text\":\"Liabilities\"") != null);
}

test "page complexity sees parser spans, image boxes, and missing ToUnicode" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateImagePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const score = try doc.analyzePageComplexity(0, allocator);

    try std.testing.expectEqual(@as(u32, 0), score.page_index);
    try std.testing.expect(score.score.span_count > 0);
    try std.testing.expectEqual(@as(usize, 1), score.score.image_count);
    try std.testing.expect(score.score.signals.missing_tounicode >= 0.9);
}

test "page complexity preserves ToUnicode metadata from native extraction" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateSimpleToUnicodePdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const score = try doc.analyzePageComplexity(0, allocator);

    try std.testing.expect(score.score.span_count > 0);
    try std.testing.expect(score.score.signals.missing_tounicode < 0.1);
}

test "images returns empty for page without images" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "No images");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const images = try doc.getPageImages(0, allocator);
    defer allocator.free(images);

    try std.testing.expectEqual(@as(usize, 0), images.len);
}

test "images out of range page returns error" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Test");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const result = doc.getPageImages(999, allocator);
    try std.testing.expectError(error.PageNotFound, result);
}

// =========================================================================
// Search edge cases
// =========================================================================

test "search empty query returns empty" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello World");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "");
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "search context contains surrounding text" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "The quick brown fox jumps over the lazy dog");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "fox");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 0), results[0].page);
    // Context should contain the match
    try std.testing.expect(std.mem.indexOf(u8, results[0].context, "fox") != null);
}

test "search multiple matches on same page" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "cat and cat and cat");
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    const results = try doc.search(allocator, "cat");
    defer zpdf.Document.freeSearchResults(allocator, results);

    try std.testing.expectEqual(@as(usize, 3), results.len);
    // All on page 0
    for (results) |r| {
        try std.testing.expectEqual(@as(usize, 0), r.page);
    }
}

// =========================================================================
// Metadata edge cases
// =========================================================================

test "metadata with partial fields" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateMetadataPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.default());
    defer doc.close();

    const meta = doc.metadata();
    // creation_date and mod_date are not in our test PDF
    try std.testing.expect(meta.creation_date == null);
    try std.testing.expect(meta.mod_date == null);
    // But title, author etc. should be present
    try std.testing.expect(meta.title != null);
}

test "superscript positioning does not insert spurious newline" {
    const allocator = std.testing.allocator;

    const pdf_data = try testpdf.generateSuperscriptPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try zpdf.Document.openFromMemory(allocator, pdf_data, zpdf.ErrorConfig.permissive());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try doc.extractText(0, runtime.arrayListWriter(&output, allocator));

    // All three text chunks must be present
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "World") != null);

    // No newline should appear between them: the 7-unit Y shift for the
    // superscript is below the threshold max(7,12)*0.7=8.4 (Fix 8)
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\n") == null);
}
