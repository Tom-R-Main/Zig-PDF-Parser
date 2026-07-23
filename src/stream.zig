//! Streaming adaptive extraction.
//!
//! This module emits the public schema as JSONL while processing one page at a
//! time, so host applications can persist stage artifacts and enqueue chunk
//! embeddings before the full document has completed.

const std = @import("std");
const adaptive = @import("adaptive.zig");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");
const schema = @import("schema.zig");
const specialist_protocol = @import("specialist_protocol.zig");
const visual_assets = @import("visual_assets.zig");

pub const StreamingEventType = enum {
    document_manifest,
    page_started,
    span,
    block,
    table,
    rag_chunk,
    route_trace,
    specialist_request,
    specialist_attempt,
    specialist_response,
    specialist_result,
    page_finished,
    document_finished,
    debug_asset,
};

pub const StreamingOptions = struct {
    adaptive_options: adaptive.ExtractOptions = .{},
    schema_options: schema.RenderOptions = .{},
    include_debug_asset_refs: bool = true,
};

pub const StreamingSummary = struct {
    page_count: usize = 0,
    event_count: u64 = 0,
    artifact_counts: schema.StreamCounts = .{},
    route_counts: schema.RouteTotals = .{},
    specialist_failure_count: usize = 0,
    elapsed_ms: u64 = 0,
};

pub fn extractAdaptiveStreaming(
    allocator: std.mem.Allocator,
    document: anytype,
    writer: anytype,
    options: StreamingOptions,
) !StreamingSummary {
    const page_start = options.adaptive_options.page_start orelse 0;
    const page_end = options.adaptive_options.page_end orelse document.pages.items.len;
    if (page_start > page_end or page_end > document.pages.items.len) return error.InvalidPageRange;

    const started_ns = runtime.nanoTimestamp();
    var summary = StreamingSummary{ .page_count = page_end - page_start };
    var event_index: u64 = 0;
    var table_context = StreamTableContext{};

    var manifest_options = options.schema_options;
    manifest_options.include_debug_asset_refs = options.include_debug_asset_refs;
    if (manifest_options.page_count == null) manifest_options.page_count = document.pages.items.len;

    try schema.writeStreamManifestRecord(writer, manifest_options, event_index);
    event_index += 1;
    try writer.writeByte('\n');

    for (page_start..page_end) |page_idx| {
        const page = document.pages.items[page_idx];
        const page_index: u32 = @intCast(page_idx);
        const page_bbox = pageBBox(page);

        try schema.writePageStartedRecord(writer, manifest_options.document_id, manifest_options.source_id, manifest_options.input_sha256, page_index, page_bbox, event_index);
        event_index += 1;
        try writer.writeByte('\n');

        var page_options = options.adaptive_options;
        page_options.page_start = page_idx;
        page_options.page_end = page_idx + 1;

        var page_result = try adaptive.extractDocument(allocator, document, page_options);
        defer page_result.deinit();
        if (page_result.hasSpecialistFailures()) summary.specialist_failure_count += 1;

        const page_counts = try writePageArtifacts(
            allocator,
            writer,
            manifest_options.document_id,
            manifest_options.source_id,
            manifest_options.input_sha256,
            manifest_options.debug_assets_dir,
            page_index,
            &page_result,
            summary.artifact_counts,
            &table_context,
            &event_index,
        );
        summary.artifact_counts.spans += page_counts.spans;
        summary.artifact_counts.blocks += page_counts.blocks;
        summary.artifact_counts.tables += page_counts.tables;
        summary.artifact_counts.route_traces += page_counts.route_traces;
        summary.artifact_counts.specialist_requests += page_counts.specialist_requests;
        summary.artifact_counts.specialist_attempts += page_counts.specialist_attempts;
        summary.artifact_counts.specialist_responses += page_counts.specialist_responses;
        summary.artifact_counts.specialist_results += page_counts.specialist_results;
        summary.artifact_counts.rag_chunks += page_counts.rag_chunks;
        summary.artifact_counts.debug_assets += page_counts.debug_assets;

        const page_routes = routeTotals(&page_result);
        addRouteTotals(&summary.route_counts, page_routes);

        try schema.writePageFinishedRecord(
            writer,
            manifest_options.document_id,
            manifest_options.source_id,
            manifest_options.input_sha256,
            page_index,
            page_bbox,
            page_counts,
            page_routes,
            event_index,
        );
        event_index += 1;
        try writer.writeByte('\n');
    }

    if (options.include_debug_asset_refs) {
        const document_debug_assets = try visual_assets.collectDocumentRefs(allocator, manifest_options.debug_assets_dir);
        defer visual_assets.deinitRecords(allocator, document_debug_assets);
        summary.artifact_counts.debug_assets += try schema.writeDebugAssetStreamRecords(writer, manifest_options.document_id, manifest_options.source_id, manifest_options.input_sha256, document_debug_assets, &event_index);
    }

    const elapsed_ns = runtime.nanoTimestamp() - started_ns;
    summary.elapsed_ms = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1_000_000)) else 0;
    try schema.writeDocumentFinishedRecord(
        writer,
        manifest_options.document_id,
        manifest_options.source_id,
        manifest_options.input_sha256,
        summary.artifact_counts,
        summary.route_counts,
        summary.elapsed_ms,
        event_index,
    );
    event_index += 1;
    try writer.writeByte('\n');

    summary.event_count = event_index;
    return summary;
}

fn writePageArtifacts(
    allocator: std.mem.Allocator,
    writer: anytype,
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    debug_assets_dir: ?[]const u8,
    page_index: u32,
    result: anytype,
    global_counts: schema.StreamCounts,
    table_context: *StreamTableContext,
    event_index: *u64,
) !schema.StreamCounts {
    var counts = schema.StreamCounts{};
    const offsets = schema.RecordOffsets{
        .span_base = @intCast(global_counts.spans),
        .block_base = @intCast(global_counts.blocks),
        .table_base = @intCast(global_counts.tables),
        .chunk_base = @intCast(global_counts.rag_chunks),
        .route_base = @intCast(global_counts.route_traces),
    };

    counts.route_traces = try schema.writeRouteTraceStreamRecords(writer, document_id, source_id, input_sha256, result, offsets, event_index);
    const specialist_context = specialist_protocol.RenderContext{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
    };
    counts.specialist_requests = try specialist_protocol.writePageRequestsJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_attempts = try specialist_protocol.writePageAttemptsJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_responses = try specialist_protocol.writePageResponsesJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_results = try specialist_protocol.writePageResultsJsonl(writer, result, specialist_context, page_index, event_index);

    for (result.reconciled.spans, 0..) |span, local_index| {
        if (span.span.page_index != page_index) continue;
        try schema.writeSpanStreamRecord(writer, result, document_id, source_id, input_sha256, span, offsets.span_base + @as(u32, @intCast(local_index)), offsets, .{
            .event_type = "span",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.spans += 1;
        try writer.writeByte('\n');
    }

    for (result.reconciled.blocks) |block| {
        if (block.page_index != page_index) continue;
        try schema.writeBlockStreamRecord(writer, result, document_id, source_id, input_sha256, block, offsets, .{
            .event_type = "block",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.blocks += 1;
        try writer.writeByte('\n');
    }

    var table_scratch: schema.TableRenderScratch = .{};
    defer table_scratch.deinit(allocator);
    for (result.tables, 0..) |table, local_index| {
        if (table.page_index != page_index) continue;
        const global_table_index = offsets.table_base + @as(u32, @intCast(local_index));
        var stream_table = table;
        table_context.apply(&stream_table, global_table_index);
        try schema.writeTableStreamRecord(allocator, writer, document_id, source_id, input_sha256, result, stream_table, global_table_index, offsets, .{
            .event_type = "table",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        }, &table_scratch);
        event_index.* += 1;
        counts.tables += 1;
        try writer.writeByte('\n');
    }

    for (result.reconciled.chunks) |chunk| {
        if (chunk.page_start > page_index or chunk.page_end < page_index) continue;
        try schema.writeRagChunkStreamRecord(writer, result, document_id, source_id, input_sha256, chunk, offsets, .{
            .event_type = "rag_chunk",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.rag_chunks += 1;
        try writer.writeByte('\n');
    }

    const page_debug_assets = try visual_assets.collectPageMaterialized(allocator, result, debug_assets_dir, page_index);
    defer visual_assets.deinitRecords(allocator, page_debug_assets);
    counts.debug_assets = try schema.writeDebugAssetStreamRecords(writer, document_id, source_id, input_sha256, page_debug_assets, event_index);

    return counts;
}

const StreamTableContext = struct {
    previous: ?PreviousTable = null,

    fn apply(self: *StreamTableContext, table: *layout.TableGrid, global_table_index: u32) void {
        table.logical_table_index = global_table_index;
        table.table_part_index = 0;
        table.continued_from_table_index = null;
        table.continued_to_table_index = null;

        const signature = PreviousTable.fromTable(table.*, global_table_index) orelse {
            self.previous = null;
            return;
        };

        if (self.previous) |previous| {
            if (previous.continuesTo(signature)) {
                table.logical_table_index = previous.logical_table_index;
                table.table_part_index = previous.table_part_index + 1;
                table.continued_from_table_index = previous.table_index;
            }
        }

        self.previous = .{
            .table_index = global_table_index,
            .logical_table_index = table.logical_table_index orelse global_table_index,
            .table_part_index = table.table_part_index,
            .page_index = table.page_index,
            .column_count = table.column_count,
            .x0 = table.bounds.x0,
            .width = table.bounds.x1 - table.bounds.x0,
            .header_hash = signature.header_hash,
        };
    }
};

const PreviousTable = struct {
    table_index: u32,
    logical_table_index: u32,
    table_part_index: u32,
    page_index: u32,
    column_count: usize,
    x0: f64,
    width: f64,
    header_hash: u64,

    fn fromTable(table: layout.TableGrid, table_index: u32) ?PreviousTable {
        const header_hash = tableHeaderHash(table) orelse return null;
        return .{
            .table_index = table_index,
            .logical_table_index = table.logical_table_index orelse table_index,
            .table_part_index = table.table_part_index,
            .page_index = table.page_index,
            .column_count = table.column_count,
            .x0 = table.bounds.x0,
            .width = table.bounds.x1 - table.bounds.x0,
            .header_hash = header_hash,
        };
    }

    fn continuesTo(self: PreviousTable, current: PreviousTable) bool {
        if (current.page_index <= self.page_index) return false;
        if (current.column_count == 0 or current.column_count != self.column_count) return false;
        if (current.header_hash != self.header_hash) return false;
        const width_delta = @abs(self.width - current.width);
        const left_delta = @abs(self.x0 - current.x0);
        return left_delta <= 18.0 and width_delta <= @max(24.0, @max(self.width, 1.0) * 0.08);
    }
};

fn tableHeaderHash(table: layout.TableGrid) ?u64 {
    for (table.rows) |row| {
        var header_cells: usize = 0;
        var text_cells: usize = 0;
        var hash: u64 = 14695981039346656037;
        for (row.cells) |cell| {
            if (cell.text.len == 0) continue;
            text_cells += 1;
            if (cell.role == .header) header_cells += 1;
            for (cell.text) |byte| {
                hash ^= std.ascii.toLower(byte);
                hash *%= 1099511628211;
            }
            hash ^= '|';
            hash *%= 1099511628211;
        }
        if (text_cells > 0 and header_cells * 2 >= text_cells) return hash;
    }
    return null;
}

fn pageBBox(page: anytype) layout.BBox {
    return .{
        .x0 = page.media_box[0],
        .y0 = page.media_box[1],
        .x1 = page.media_box[2],
        .y1 = page.media_box[3],
    };
}

fn routeTotals(result: anytype) schema.RouteTotals {
    var totals = schema.RouteTotals{
        .page_routes = result.page_routes.len,
        .region_routes = result.region_routes.len,
    };
    for (result.page_routes) |route| {
        if (route.route.native_fast_path) totals.native_pages += 1;
    }
    for (result.region_routes) |route| {
        if (route.route.needs_ocr) totals.ocr_regions += 1;
        if (route.route.needs_table_model) totals.table_regions += 1;
        if (route.route.needs_formula_model) totals.formula_regions += 1;
    }
    return totals;
}

fn addRouteTotals(total: *schema.RouteTotals, add: schema.RouteTotals) void {
    total.native_pages += add.native_pages;
    total.page_routes += add.page_routes;
    total.region_routes += add.region_routes;
    total.ocr_regions += add.ocr_regions;
    total.table_regions += add.table_regions;
    total.formula_regions += add.formula_regions;
}

test "streaming event enum includes lifecycle and artifact records" {
    try std.testing.expectEqual(StreamingEventType.document_manifest, StreamingEventType.document_manifest);
    try std.testing.expectEqual(StreamingEventType.document_finished, StreamingEventType.document_finished);
}
