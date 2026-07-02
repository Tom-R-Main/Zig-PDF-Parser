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

pub const StreamingEventType = enum {
    document_manifest,
    page_started,
    span,
    block,
    table,
    rag_chunk,
    route_trace,
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

        try schema.writePageStartedRecord(writer, manifest_options.document_id, page_index, page_bbox, event_index);
        event_index += 1;
        try writer.writeByte('\n');

        var page_options = options.adaptive_options;
        page_options.page_start = page_idx;
        page_options.page_end = page_idx + 1;

        var page_result = try adaptive.extractDocument(allocator, document, page_options);
        defer page_result.deinit();

        const page_counts = try writePageArtifacts(
            writer,
            manifest_options.document_id,
            page_index,
            &page_result,
            summary.artifact_counts,
            &event_index,
        );
        summary.artifact_counts.spans += page_counts.spans;
        summary.artifact_counts.blocks += page_counts.blocks;
        summary.artifact_counts.tables += page_counts.tables;
        summary.artifact_counts.route_traces += page_counts.route_traces;
        summary.artifact_counts.rag_chunks += page_counts.rag_chunks;

        const page_routes = routeTotals(&page_result);
        addRouteTotals(&summary.route_counts, page_routes);

        try schema.writePageFinishedRecord(
            writer,
            manifest_options.document_id,
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
        summary.artifact_counts.debug_assets += try schema.writeDebugAssetStreamRecords(writer, manifest_options.document_id, &event_index);
    }

    const elapsed_ns = runtime.nanoTimestamp() - started_ns;
    summary.elapsed_ms = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1_000_000)) else 0;
    try schema.writeDocumentFinishedRecord(
        writer,
        manifest_options.document_id,
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
    writer: anytype,
    document_id: []const u8,
    page_index: u32,
    result: anytype,
    global_counts: schema.StreamCounts,
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

    counts.route_traces = try schema.writeRouteTraceStreamRecords(writer, document_id, result, offsets, event_index);

    for (result.reconciled.spans, 0..) |span, local_index| {
        if (span.span.page_index != page_index) continue;
        try schema.writeSpanStreamRecord(writer, document_id, span, offsets.span_base + @as(u32, @intCast(local_index)), .{
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
        try schema.writeBlockStreamRecord(writer, document_id, block, offsets.block_base, .{
            .event_type = "block",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.blocks += 1;
        try writer.writeByte('\n');
    }

    for (result.tables, 0..) |table, local_index| {
        if (table.page_index != page_index) continue;
        try schema.writeTableStreamRecord(writer, document_id, result, table, offsets.table_base + @as(u32, @intCast(local_index)), offsets, .{
            .event_type = "table",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.tables += 1;
        try writer.writeByte('\n');
    }

    for (result.reconciled.chunks) |chunk| {
        if (chunk.page_start > page_index or chunk.page_end < page_index) continue;
        try schema.writeRagChunkStreamRecord(writer, document_id, chunk, offsets.chunk_base, offsets.block_base, .{
            .event_type = "rag_chunk",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.rag_chunks += 1;
        try writer.writeByte('\n');
    }

    return counts;
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
