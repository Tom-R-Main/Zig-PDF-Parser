//! Versioned adaptive output schema and artifact renderers.
//!
//! This module is the public JSON/JSONL contract. Internal extraction structs
//! may change, but records emitted here carry a semver-like schema version.

const std = @import("std");
const complexity = @import("complexity.zig");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");

pub const schema_version = "0.1.0";
pub const parser_version = "0.1.0-alpha";

pub const RenderOptions = struct {
    document_id: []const u8 = "document",
    input_sha256: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    page_count: ?usize = null,
    encrypted: ?bool = null,
    include_debug_asset_refs: bool = true,
};

pub fn renderArtifactJson(allocator: std.mem.Allocator, result: anytype, options: RenderOptions) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeDocumentManifestOpen(writer, result, options);
    try writer.writeAll(",\"spans\":[");
    for (result.reconciled.spans, 0..) |span, index| {
        if (index > 0) try writer.writeByte(',');
        try writeSpanRecord(writer, options.document_id, span, @intCast(index));
    }
    try writer.writeAll("],\"blocks\":[");
    for (result.reconciled.blocks, 0..) |block, index| {
        if (index > 0) try writer.writeByte(',');
        try writeBlockRecord(writer, options.document_id, block);
    }
    try writer.writeAll("],\"tables\":[");
    for (result.tables, 0..) |table, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTableRecord(writer, options.document_id, result, table, @intCast(index));
    }
    try writer.writeAll("],\"form_fields\":[");
    for (result.form_fields, 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try writeFormFieldRecord(writer, options.document_id, result, field, @intCast(index));
    }
    try writer.writeAll("],\"route_traces\":[");
    try writeRouteTraceRecords(writer, options.document_id, result, false);
    try writer.writeAll("],\"rag_chunks\":[");
    for (result.reconciled.chunks, 0..) |chunk, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRagChunkRecord(writer, options.document_id, chunk);
    }
    try writer.writeAll("],\"debug_assets\":[");
    if (options.include_debug_asset_refs) try writeDebugAssetRecords(writer, options.document_id, false);
    try writer.writeAll("]}");

    return output.toOwnedSlice(allocator);
}

pub fn renderArtifactJsonl(allocator: std.mem.Allocator, result: anytype, options: RenderOptions) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeDocumentManifestRecord(writer, result, options);
    try writer.writeByte('\n');
    for (result.reconciled.spans, 0..) |span, index| {
        try writeSpanRecord(writer, options.document_id, span, @intCast(index));
        try writer.writeByte('\n');
    }
    for (result.reconciled.blocks) |block| {
        try writeBlockRecord(writer, options.document_id, block);
        try writer.writeByte('\n');
    }
    for (result.tables, 0..) |table, index| {
        try writeTableRecord(writer, options.document_id, result, table, @intCast(index));
        try writer.writeByte('\n');
    }
    for (result.form_fields, 0..) |field, index| {
        try writeFormFieldRecord(writer, options.document_id, result, field, @intCast(index));
        try writer.writeByte('\n');
    }
    try writeRouteTraceRecords(writer, options.document_id, result, true);
    for (result.reconciled.chunks) |chunk| {
        try writeRagChunkRecord(writer, options.document_id, chunk);
        try writer.writeByte('\n');
    }
    if (options.include_debug_asset_refs) {
        try writeDebugAssetRecords(writer, options.document_id, true);
    }

    return output.toOwnedSlice(allocator);
}

pub fn renderComplexityJson(allocator: std.mem.Allocator, result: anytype, document_id: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\"schema_version\":\"");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeAll("\",\"pages\":[");
    for (result.page_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writePageRouteRecord(writer, document_id, route);
    }
    try writer.writeAll("],\"regions\":[");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRegionRouteRecord(writer, document_id, route);
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice(allocator);
}

pub fn renderTraceJson(allocator: std.mem.Allocator, result: anytype, document_id: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\"schema_version\":\"");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeAll("\",\"pages\":[");
    for (result.page_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writePageRouteRecord(writer, document_id, route);
    }
    try writer.writeAll("],\"regions\":[");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRegionRouteRecord(writer, document_id, route);
    }
    try writer.writeAll("],\"trace\":[");
    for (result.trace_records, 0..) |record, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTraceRecord(writer, document_id, result, record, @intCast(index));
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice(allocator);
}

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &encoded);
    return out;
}

fn writeDocumentManifestRecord(writer: anytype, result: anytype, options: RenderOptions) !void {
    try writeDocumentManifestOpen(writer, result, options);
    try writer.writeByte('}');
}

fn writeDocumentManifestOpen(writer: anytype, result: anytype, options: RenderOptions) !void {
    try writeRecordHeader(writer, "document_manifest");
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, options.document_id);
    try writer.writeAll("\",\"parser_version\":\"");
    try writer.writeAll(parser_version);
    try writer.writeAll("\",\"page_count\":");
    try writer.print("{}", .{options.page_count orelse result.page_routes.len});
    try writer.writeAll(",\"encrypted\":");
    if (options.encrypted) |encrypted| {
        try writer.print("{}", .{encrypted});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, options.input_sha256);
    try writer.writeAll(",\"source_path\":");
    try writeOptionalString(writer, options.source_path);
    try writer.writeAll(",\"extraction_options\":{\"adaptive\":true}");
    try writer.writeAll(",\"route_counts\":");
    try writeRouteCounts(writer, result);
    try writer.writeAll(",\"artifact_counts\":");
    try writeArtifactCounts(writer, result, options);
    try writer.writeAll(",\"warnings\":[]");
    try writer.writeAll(",\"available_outputs\":[\"json\",\"artifact-jsonl\",\"jsonl\",\"rag-jsonl\",\"hocr\",\"alto\",\"debug-svg\"]");
}

fn writeRouteCounts(writer: anytype, result: anytype) !void {
    var native_pages: u32 = 0;
    var ocr_regions: u32 = 0;
    var table_regions: u32 = 0;
    var formula_regions: u32 = 0;
    for (result.page_routes) |route| {
        if (route.route.native_fast_path) native_pages += 1;
    }
    for (result.region_routes) |route| {
        if (route.route.needs_ocr) ocr_regions += 1;
        if (route.route.needs_table_model) table_regions += 1;
        if (route.route.needs_formula_model) formula_regions += 1;
    }
    try writer.print(
        "{{\"native_pages\":{},\"page_routes\":{},\"region_routes\":{},\"ocr_regions\":{},\"table_regions\":{},\"formula_regions\":{}}}",
        .{ native_pages, result.page_routes.len, result.region_routes.len, ocr_regions, table_regions, formula_regions },
    );
}

fn writeArtifactCounts(writer: anytype, result: anytype, options: RenderOptions) !void {
    try writer.print(
        "{{\"spans\":{},\"blocks\":{},\"tables\":{},\"form_fields\":{},\"route_traces\":{},\"rag_chunks\":{},\"debug_assets\":{}}}",
        .{
            result.reconciled.spans.len,
            result.reconciled.blocks.len,
            result.tables.len,
            result.form_fields.len,
            routeTraceCount(result),
            result.reconciled.chunks.len,
            if (options.include_debug_asset_refs) debug_asset_specs.len else 0,
        },
    );
}

fn writeSpanRecord(writer: anytype, document_id: []const u8, span: anytype, span_index: u32) !void {
    try writeRecordHeader(writer, "span");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"span_id\":\"span-{d}\",\"span_index\":{},\"page_index\":{}", .{
        span_index,
        span_index,
        span.span.page_index,
    });
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, span.span.bbox);
    try writer.writeAll(",\"text\":\"");
    try writeJsonEscaped(writer, span.span.text);
    try writer.writeAll("\",\"source\":\"");
    try writer.writeAll(sourceKindName(span.span.source));
    try writer.writeAll("\",\"chosen_source\":\"");
    try writer.writeAll(sourceKindName(span.chosen_source));
    try writer.writeAll("\",\"sources\":\"");
    try writer.writeAll(sourceMaskName(span.source_mask));
    try writer.print("\",\"source_mask\":{},\"source_count\":{},\"duplicate_count\":{},\"confidence\":{d:.3}", .{
        span.source_mask,
        span.source_count,
        span.duplicate_count,
        span.confidence,
    });
    try writer.writeAll(",\"font\":");
    try writeFontJson(writer, span.span.font, span.span.font_size);
    try writer.writeAll(",\"block_id\":");
    try writeOptionalU32(writer, span.span.block_id);
    try writer.writeAll(",\"line_id\":");
    try writeOptionalU32(writer, span.span.line_id);
    try writer.writeAll(",\"mcid\":");
    try writeOptionalI32(writer, span.span.mcid);
    try writer.writeByte('}');
}

fn writeBlockRecord(writer: anytype, document_id: []const u8, block: anytype) !void {
    try writeRecordHeader(writer, "block");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"block_id\":\"block-{d}\",\"block_index\":{},\"page_index\":{},\"kind\":\"{s}\"", .{
        block.id,
        block.id,
        block.page_index,
        blockKindName(block.kind),
    });
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, block.bbox);
    try writer.writeAll(",\"text\":\"");
    try writeJsonEscaped(writer, block.text);
    try writer.writeAll("\",\"sources\":\"");
    try writer.writeAll(sourceMaskName(block.source_mask));
    try writer.print("\",\"source_mask\":{},\"confidence\":{d:.3},\"span_start\":{},\"span_count\":{}", .{
        block.source_mask,
        block.confidence,
        block.span_start,
        block.span_count,
    });
    try writer.writeAll(",\"candidate_kind\":");
    try writeCandidateKind(writer, block.kind);
    try writer.writeByte('}');
}

fn writeTableRecord(writer: anytype, document_id: []const u8, result: anytype, table: anytype, table_index: u32) !void {
    try writeRecordHeader(writer, "table");
    try writeDocumentId(writer, document_id);
    try writer.print(
        ",\"table_id\":\"table-{d}\",\"table_index\":{},\"page_index\":{},\"block_index\":{},\"block_count\":{},\"column_count\":{},\"confidence\":{d:.3}",
        .{ table_index, table_index, table.page_index, table.block_index, table.block_count, table.column_count, table.confidence },
    );
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, table.bounds.bbox);
    try writer.writeAll(",\"rows\":[");
    for (table.rows, 0..) |row, row_index| {
        if (row_index > 0) try writer.writeByte(',');
        try writer.print("{{\"row_index\":{},\"bbox\":", .{row.row_index});
        try writeBBoxJson(writer, row.bounds.bbox);
        try writer.writeAll(",\"cells\":[");
        for (row.cells, 0..) |cell, cell_index| {
            if (cell_index > 0) try writer.writeByte(',');
            try writeCellJson(writer, result, cell);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}");
}

fn writeCellJson(writer: anytype, result: anytype, cell: layout.TableCell) !void {
    try writer.print(
        "{{\"page_index\":{},\"row\":{},\"column\":{},\"rowspan\":{},\"colspan\":{},\"role\":\"{s}\",\"confidence\":{d:.3},\"text\":\"",
        .{
            cell.bounds.page_index,
            cell.row_index,
            cell.column_index,
            cell.rowspan,
            cell.colspan,
            tableCellRoleName(cell.role),
            cell.confidence,
        },
    );
    try writeJsonEscaped(writer, cell.text);
    try writer.writeAll("\",\"bbox\":");
    try writeBBoxJson(writer, cell.bounds.bbox);
    try writer.writeAll(",\"source_span_ids\":[");
    var first = true;
    for (result.reconciled.spans, 0..) |span, span_index| {
        if (span.span.page_index != cell.bounds.page_index) continue;
        if (!centerInside(span.span.bbox, cell.bounds.bbox)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("\"span-{d}\"", .{span_index});
        first = false;
    }
    try writer.writeAll("]}");
}

fn writeFormFieldRecord(writer: anytype, document_id: []const u8, result: anytype, field: anytype, field_index: u32) !void {
    try writeRecordHeader(writer, "form_field");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"form_field_id\":\"form-field-{d}\",\"field_index\":{},\"name\":\"", .{ field_index, field_index });
    try writeJsonEscaped(writer, field.name);
    try writer.writeAll("\",\"type\":\"");
    try writeJsonEscaped(writer, field.field_type);
    try writer.writeAll("\",\"value\":");
    try writeOptionalString(writer, field.value);
    try writer.writeAll(",\"page_index\":");
    try writer.writeAll(if (field.rect == null) "null" else "0");
    try writer.writeAll(",\"bbox\":");
    if (field.rect) |rect| {
        try writeRectJson(writer, rect);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"source_span_id\":");
    if (findManualSpanForField(result, field)) |span_index| {
        try writer.print("\"span-{d}\"", .{span_index});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"visible_value_mismatch\":false,\"missing_appearance\":false}");
}

fn writeRouteTraceRecords(writer: anytype, document_id: []const u8, result: anytype, jsonl: bool) !void {
    var wrote = false;
    for (result.page_routes) |route| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        try writePageRouteRecord(writer, document_id, route);
        wrote = true;
    }
    for (result.region_routes) |route| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        try writeRegionRouteRecord(writer, document_id, route);
        wrote = true;
    }
    for (result.trace_records, 0..) |record, index| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        try writeTraceRecord(writer, document_id, result, record, @intCast(index));
        wrote = true;
    }
    if (jsonl and wrote) try writer.writeByte('\n');
}

fn writePageRouteRecord(writer: anytype, document_id: []const u8, route: anytype) !void {
    try writeRecordHeader(writer, "route_trace");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"route_trace_id\":\"route-page-{d}\",\"trace_kind\":\"page_route\",\"page_index\":{},\"region_index\":null,\"stage\":\"route_decision\"", .{
        route.page_index,
        route.page_index,
    });
    try writeRouteFields(writer, route.route, route.reason_mask, route.span_count, 0, route.image_count, route.char_count, route.signals, route.bbox);
    try writer.writeByte('}');
}

fn writeRegionRouteRecord(writer: anytype, document_id: []const u8, route: anytype) !void {
    try writeRecordHeader(writer, "route_trace");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"route_trace_id\":\"route-region-{d}\",\"trace_kind\":\"region_route\",\"page_index\":{},\"region_index\":{},\"stage\":\"route_decision\"", .{
        route.region_index,
        route.page_index,
        route.region_index,
    });
    try writer.writeAll(",\"layout_block_index\":");
    try writeOptionalU32(writer, route.layout_block_index);
    try writer.writeAll(",\"block_kind\":");
    if (route.block_kind) |kind| {
        try writer.writeByte('"');
        try writer.writeAll(blockKindName(kind));
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
    try writeRouteFields(writer, route.route, route.reason_mask, route.span_count, 0, route.image_count, route.char_count, route.signals, route.bbox);
    try writer.writeAll(",\"specialist\":");
    try writeSpecialistJson(writer, route);
    try writer.writeByte('}');
}

fn writeTraceRecord(writer: anytype, document_id: []const u8, result: anytype, record: anytype, trace_index: u32) !void {
    try writeRecordHeader(writer, "route_trace");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"route_trace_id\":\"trace-{d}\",\"trace_kind\":\"stage\",\"page_index\":{},\"region_index\":", .{
        trace_index,
        record.page_index,
    });
    try writeOptionalU32(writer, record.region_index);
    try writer.writeAll(",\"stage\":\"");
    try writer.writeAll(@tagName(record.stage));
    try writer.writeByte('"');
    const bbox = traceBBox(result, record);
    try writeRouteFields(writer, record.route, record.reason_mask, record.span_count, record.block_count, 0, 0, null, bbox);
    try writer.writeByte('}');
}

fn writeRouteFields(
    writer: anytype,
    route: anytype,
    reason_mask: u32,
    span_count: usize,
    block_count: usize,
    image_count: usize,
    char_count: usize,
    signals: ?complexity.SignalScores,
    bbox: ?layout.BBox,
) !void {
    try writer.writeAll(",\"route\":\"");
    try writer.writeAll(routeName(route));
    try writer.print("\",\"confidence\":{d:.3},\"reasons\":", .{routeConfidence(route)});
    try writeReasonArray(writer, reason_mask);
    try writer.print(",\"span_count\":{},\"block_count\":{},\"image_count\":{},\"char_count\":{}", .{
        span_count,
        block_count,
        image_count,
        char_count,
    });
    try writer.writeAll(",\"signals\":");
    if (signals) |signal_scores| {
        try writeSignalsJson(writer, signal_scores);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"bbox\":");
    if (bbox) |box| {
        try writeBBoxJson(writer, box);
    } else {
        try writer.writeAll("null");
    }
}

fn writeRagChunkRecord(writer: anytype, document_id: []const u8, chunk: anytype) !void {
    try writeRecordHeader(writer, "rag_chunk");
    try writeDocumentId(writer, document_id);
    try writer.print(",\"chunk_id\":\"chunk-{d}\",\"chunk_index\":{},\"source_id\":\"", .{ chunk.chunk_index, chunk.chunk_index });
    try writeJsonEscaped(writer, chunk.source_id);
    try writer.writeAll("\",\"content\":\"");
    try writeJsonEscaped(writer, chunk.content);
    try writer.print("\",\"block_start\":{},\"block_count\":{},\"page_start\":{},\"page_end\":{}", .{
        chunk.block_start,
        chunk.block_count,
        chunk.page_start,
        chunk.page_end,
    });
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, chunk.bbox);
    try writer.writeAll(",\"sources\":\"");
    try writer.writeAll(sourceMaskName(chunk.source_mask));
    try writer.print("\",\"source_mask\":{},\"confidence\":{d:.3},\"source_block_ids\":[", .{ chunk.source_mask, chunk.confidence });
    for (0..chunk.block_count) |offset| {
        if (offset > 0) try writer.writeByte(',');
        try writer.print("\"block-{d}\"", .{chunk.block_start + offset});
    }
    try writer.writeAll("],\"source_span_ids\":[]}");
}

const DebugAssetSpec = struct {
    id: []const u8,
    kind: []const u8,
    media_type: []const u8,
    output_format: []const u8,
};

const debug_asset_specs = [_]DebugAssetSpec{
    .{ .id = "debug-svg", .kind = "debug_overlay", .media_type = "image/svg+xml", .output_format = "debug-svg" },
    .{ .id = "route-trace", .kind = "route_trace", .media_type = "application/json", .output_format = "trace-json" },
    .{ .id = "hocr", .kind = "coordinate_text", .media_type = "text/html", .output_format = "hocr" },
    .{ .id = "alto", .kind = "coordinate_text", .media_type = "application/xml", .output_format = "alto" },
};

fn writeDebugAssetRecords(writer: anytype, document_id: []const u8, jsonl: bool) !void {
    for (debug_asset_specs, 0..) |asset, index| {
        if (index > 0) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        try writeRecordHeader(writer, "debug_asset");
        try writeDocumentId(writer, document_id);
        try writer.writeAll(",\"debug_asset_id\":\"");
        try writeJsonEscaped(writer, asset.id);
        try writer.writeAll("\",\"kind\":\"");
        try writeJsonEscaped(writer, asset.kind);
        try writer.writeAll("\",\"media_type\":\"");
        try writeJsonEscaped(writer, asset.media_type);
        try writer.writeAll("\",\"output_format\":\"");
        try writeJsonEscaped(writer, asset.output_format);
        try writer.writeAll("\",\"uri\":null,\"page_index\":null,\"region_index\":null,\"stage\":\"output_ready\"}");
    }
    if (jsonl and debug_asset_specs.len > 0) try writer.writeByte('\n');
}

fn writeRecordHeader(writer: anytype, name: []const u8) !void {
    try writer.writeAll("{\"schema_name\":\"");
    try writer.writeAll(name);
    try writer.writeAll("\",\"schema_version\":\"");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"record_type\":\"");
    try writer.writeAll(name);
    try writer.writeByte('"');
}

fn writeDocumentId(writer: anytype, document_id: []const u8) !void {
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeByte('"');
}

fn writeFontJson(writer: anytype, font: layout.FontMetadata, fallback_size: f64) !void {
    try writer.writeAll("{\"name\":");
    try writeOptionalString(writer, font.name);
    try writer.print(",\"size\":{d:.3},\"encoding\":", .{if (font.size != 0) font.size else fallback_size});
    try writeOptionalString(writer, font.encoding);
    try writer.writeAll(",\"has_to_unicode\":");
    if (font.has_to_unicode) |value| {
        try writer.print("{}", .{value});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeSpecialistJson(writer: anytype, route: anytype) !void {
    try writer.writeAll("{\"table\":");
    if (route.table) |table| {
        try writer.print(
            "{{\"confidence\":{d:.3},\"estimated_rows\":{},\"estimated_columns\":{}}}",
            .{ table.confidence, table.estimated_rows, table.estimated_columns },
        );
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"formula\":");
    if (route.formula) |formula| {
        try writer.print("{{\"confidence\":{d:.3}}}", .{formula.confidence});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeSignalsJson(writer: anytype, signals: anytype) !void {
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

fn writeReasonArray(writer: anytype, mask: u32) !void {
    const reasons = [_]struct { bit: u5, name: []const u8 }{
        .{ .bit = 0, .name = "native_fast_path" },
        .{ .bit = 1, .name = "sparse_text" },
        .{ .bit = 2, .name = "image_dominant" },
        .{ .bit = 3, .name = "bad_unicode" },
        .{ .bit = 4, .name = "missing_tounicode" },
        .{ .bit = 5, .name = "hidden_ocr" },
        .{ .bit = 6, .name = "low_reading_order_confidence" },
        .{ .bit = 7, .name = "table_alignment" },
        .{ .bit = 8, .name = "formula_density" },
        .{ .bit = 9, .name = "ocr_route_stub" },
        .{ .bit = 10, .name = "layout_route_stub" },
        .{ .bit = 11, .name = "table_route_stub" },
        .{ .bit = 12, .name = "formula_route_stub" },
    };

    try writer.writeByte('[');
    var first = true;
    for (reasons) |reason| {
        if ((mask & (@as(u32, 1) << reason.bit)) == 0) continue;
        if (!first) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(reason.name);
        try writer.writeByte('"');
        first = false;
    }
    try writer.writeByte(']');
}

fn writeCandidateKind(writer: anytype, kind: layout.BlockKind) !void {
    switch (kind) {
        .table_candidate => try writer.writeAll("\"table\""),
        .formula_candidate => try writer.writeAll("\"formula\""),
        .figure_candidate => try writer.writeAll("\"figure\""),
        else => try writer.writeAll("null"),
    }
}

fn writeBBoxJson(writer: anytype, box: layout.BBox) !void {
    try writer.print("{{\"x0\":{d:.2},\"y0\":{d:.2},\"x1\":{d:.2},\"y1\":{d:.2}}}", .{
        box.x0,
        box.y0,
        box.x1,
        box.y1,
    });
}

fn writeRectJson(writer: anytype, rect: [4]f64) !void {
    try writer.print("{{\"x0\":{d:.2},\"y0\":{d:.2},\"x1\":{d:.2},\"y1\":{d:.2}}}", .{
        rect[0],
        rect[1],
        rect[2],
        rect[3],
    });
}

fn writeOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeByte('"');
        try writeJsonEscaped(writer, text);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalU32(writer: anytype, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalI32(writer: anytype, value: ?i32) !void {
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => if (byte < 0x20) {
                try writer.print("\\u00{X:0>2}", .{byte});
            } else {
                try writer.writeByte(byte);
            },
        }
    }
}

fn sourceKindName(source: layout.SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native_pdf",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula_model",
        .manual => "manual",
    };
}

fn sourceMaskName(mask: u32) []const u8 {
    if (hasSource(mask, .manual)) return "manual";
    if (hasSource(mask, .native_pdf) and countSourceBits(mask) == 1) return "native_pdf";
    if (hasSource(mask, .table_model) and countSourceBits(mask) == 1) return "table_model";
    if (hasSource(mask, .formula_model) and countSourceBits(mask) == 1) return "formula_model";
    if (hasSource(mask, .fresh_ocr) and countSourceBits(mask) == 1) return "fresh_ocr";
    if (hasSource(mask, .embedded_ocr) and countSourceBits(mask) == 1) return "embedded_ocr";
    return "mixed";
}

fn hasSource(mask: u32, source: layout.SourceKind) bool {
    return (mask & (@as(u32, 1) << @as(u5, @intCast(@intFromEnum(source))))) != 0;
}

fn countSourceBits(mask: u32) u8 {
    return @intCast(@popCount(mask));
}

fn blockKindName(kind: layout.BlockKind) []const u8 {
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

fn tableCellRoleName(role: layout.TableCellRole) []const u8 {
    return switch (role) {
        .data => "data",
        .header => "header",
        .row_header => "row_header",
        .note => "note",
    };
}

fn routeName(route: anytype) []const u8 {
    if (route.native_fast_path) return "use_native";
    if (route.needs_ocr) return "queue_ocr";
    if (route.needs_table_model and route.needs_formula_model) return "candidate_table_formula";
    if (route.needs_table_model) return "candidate_table";
    if (route.needs_formula_model) return "candidate_formula";
    if (route.needs_layout_model) return "candidate_layout";
    return "review";
}

fn routeConfidence(route: anytype) f32 {
    const signal = @max(0.0, @min(1.0, route.max_signal));
    if (route.native_fast_path) return 1.0 - signal;
    return signal;
}

fn routeTraceCount(result: anytype) usize {
    return result.page_routes.len + result.region_routes.len + result.trace_records.len;
}

fn centerInside(inner: layout.BBox, outer: layout.BBox) bool {
    const x = (inner.x0 + inner.x1) / 2.0;
    const y = (inner.y0 + inner.y1) / 2.0;
    return x >= outer.x0 and x <= outer.x1 and y >= outer.y0 and y <= outer.y1;
}

fn findManualSpanForField(result: anytype, field: anytype) ?usize {
    const value = field.value orelse return null;
    for (result.reconciled.spans, 0..) |span, index| {
        if (span.chosen_source != .manual) continue;
        const text = span.span.text;
        if (text.len != field.name.len + 1 + value.len) continue;
        if (!std.mem.startsWith(u8, text, field.name)) continue;
        if (text[field.name.len] != ' ') continue;
        if (!std.mem.eql(u8, text[field.name.len + 1 ..], value)) continue;
        return index;
    }
    return null;
}

fn traceBBox(result: anytype, record: anytype) ?layout.BBox {
    if (record.region_index) |region_index| {
        for (result.region_routes) |route| {
            if (route.region_index == region_index) return route.bbox;
        }
    }
    for (result.page_routes) |route| {
        if (route.page_index == record.page_index) return route.bbox;
    }
    return null;
}
