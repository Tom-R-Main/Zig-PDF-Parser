//! Versioned adaptive output schema and artifact renderers.
//!
//! This module is the public JSON/JSONL contract. Internal extraction structs
//! may change, but records emitted here carry a semver-like schema version.

const std = @import("std");
const complexity = @import("complexity.zig");
const encryption = @import("encryption.zig");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");
const specialist_protocol = @import("specialist_protocol.zig");
const visual_assets = @import("visual_assets.zig");

pub const schema_version = specialist_protocol.schema_version;
pub const parser_version = "0.1.0-alpha";

pub const RenderOptions = struct {
    document_id: []const u8 = "document",
    source_id: ?[]const u8 = null,
    input_sha256: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    page_count: ?usize = null,
    encrypted: ?bool = null,
    encryption_info: ?encryption.Info = null,
    corrupt: ?bool = null,
    warnings: []const ManifestDiagnostic = &.{},
    errors: []const ManifestDiagnostic = &.{},
    include_debug_asset_refs: bool = true,
    debug_assets_dir: ?[]const u8 = null,
    specialist_config_path: ?[]const u8 = null,
};

pub const ManifestDiagnostic = struct {
    code: []const u8,
    message: []const u8,
    offset: ?u64 = null,
};

pub fn collectEncryptionWarnings(
    storage: []ManifestDiagnostic,
    info: encryption.Info,
    respect_permissions: bool,
) []const ManifestDiagnostic {
    var count: usize = 0;
    if (info.encrypted and info.authenticated and info.weak_crypto and count < storage.len) {
        storage[count] = .{
            .code = "weak_pdf_encryption",
            .message = "PDF uses weak legacy encryption; extraction continued because weak crypto reading is enabled",
        };
        count += 1;
    }
    if (info.encrypted and info.authenticated and !info.permissions.extract and !respect_permissions and count < storage.len) {
        storage[count] = .{
            .code = "permissions_not_enforced",
            .message = "PDF permissions disallow text extraction; extraction continued because respect_permissions is false",
        };
        count += 1;
    }
    return storage[0..count];
}

pub const StreamCounts = struct {
    spans: usize = 0,
    blocks: usize = 0,
    tables: usize = 0,
    route_traces: usize = 0,
    specialist_requests: usize = 0,
    specialist_attempts: usize = 0,
    specialist_responses: usize = 0,
    specialist_results: usize = 0,
    rag_chunks: usize = 0,
    debug_assets: usize = 0,
};

pub const IndexRange = struct {
    start: usize = std.math.maxInt(usize),
    end: usize = 0,

    fn add(self: *IndexRange, index: usize) void {
        self.start = @min(self.start, index);
        self.end = @max(self.end, index + 1);
    }

    fn slice(self: IndexRange) ?IndexRange {
        if (self.start == std.math.maxInt(usize)) return null;
        return self;
    }
};

pub const RouteLookup = struct {
    allocator: std.mem.Allocator,
    page_route_indices: []?usize,
    region_ranges: []IndexRange,
    trace_ranges: []IndexRange,

    fn init(allocator: std.mem.Allocator, result: anytype) !RouteLookup {
        const page_count = routeLookupPageCount(result);
        const page_route_indices = try allocator.alloc(?usize, page_count);
        errdefer allocator.free(page_route_indices);
        @memset(page_route_indices, null);

        const region_ranges = try allocator.alloc(IndexRange, page_count);
        errdefer allocator.free(region_ranges);
        @memset(region_ranges, .{});

        const trace_ranges = try allocator.alloc(IndexRange, page_count);
        errdefer allocator.free(trace_ranges);
        @memset(trace_ranges, .{});

        for (result.page_routes, 0..) |route, index| {
            if (route.page_index < page_route_indices.len and page_route_indices[route.page_index] == null) {
                page_route_indices[route.page_index] = index;
            }
        }
        for (result.region_routes, 0..) |route, index| {
            if (route.page_index < region_ranges.len) region_ranges[route.page_index].add(index);
        }
        for (result.trace_records, 0..) |record, index| {
            if (record.page_index < trace_ranges.len) trace_ranges[record.page_index].add(index);
        }

        return .{
            .allocator = allocator,
            .page_route_indices = page_route_indices,
            .region_ranges = region_ranges,
            .trace_ranges = trace_ranges,
        };
    }

    fn deinit(self: *RouteLookup) void {
        self.allocator.free(self.page_route_indices);
        self.allocator.free(self.region_ranges);
        self.allocator.free(self.trace_ranges);
        self.* = undefined;
    }

    fn pageRouteIndex(self: *const RouteLookup, page_index: u32) ?usize {
        if (page_index >= self.page_route_indices.len) return null;
        return self.page_route_indices[page_index];
    }

    fn regionRange(self: *const RouteLookup, page_index: u32) ?IndexRange {
        if (page_index >= self.region_ranges.len) return null;
        return self.region_ranges[page_index].slice();
    }

    fn traceRange(self: *const RouteLookup, page_index: u32) ?IndexRange {
        if (page_index >= self.trace_ranges.len) return null;
        return self.trace_ranges[page_index].slice();
    }
};

pub const SpanLookup = struct {
    allocator: std.mem.Allocator,
    span_ranges: []IndexRange,

    fn init(allocator: std.mem.Allocator, result: anytype) !SpanLookup {
        const page_count = spanLookupPageCount(result);
        const span_ranges = try allocator.alloc(IndexRange, page_count);
        errdefer allocator.free(span_ranges);
        @memset(span_ranges, .{});

        for (result.reconciled.spans, 0..) |span, index| {
            const page_index = span.span.page_index;
            if (page_index < span_ranges.len) span_ranges[page_index].add(index);
        }

        return .{
            .allocator = allocator,
            .span_ranges = span_ranges,
        };
    }

    fn deinit(self: *SpanLookup) void {
        self.allocator.free(self.span_ranges);
        self.* = undefined;
    }

    fn spanRange(self: *const SpanLookup, page_index: u32) ?IndexRange {
        if (page_index >= self.span_ranges.len) return null;
        return self.span_ranges[page_index].slice();
    }
};

fn routeLookupPageCount(result: anytype) usize {
    var page_count: usize = 0;
    for (result.page_routes) |route| page_count = @max(page_count, @as(usize, @intCast(route.page_index)) + 1);
    for (result.region_routes) |route| page_count = @max(page_count, @as(usize, @intCast(route.page_index)) + 1);
    for (result.trace_records) |record| page_count = @max(page_count, @as(usize, @intCast(record.page_index)) + 1);
    return page_count;
}

fn spanLookupPageCount(result: anytype) usize {
    var page_count: usize = 0;
    for (result.reconciled.spans) |span| page_count = @max(page_count, @as(usize, @intCast(span.span.page_index)) + 1);
    return page_count;
}

pub const RecordOffsets = struct {
    span_base: u32 = 0,
    block_base: u32 = 0,
    table_base: u32 = 0,
    chunk_base: u32 = 0,
    route_base: u32 = 0,
    route_lookup: ?*const RouteLookup = null,
    span_lookup: ?*const SpanLookup = null,
};

pub const RouteTotals = struct {
    native_pages: usize = 0,
    page_routes: usize = 0,
    region_routes: usize = 0,
    ocr_regions: usize = 0,
    table_regions: usize = 0,
    formula_regions: usize = 0,
};

pub const StreamRecordMeta = struct {
    event_type: []const u8,
    event_index: u64,
    page_index: ?u32 = null,
    sequence_scope: []const u8 = "document",
};

pub const TableRenderScratch = struct {
    cell_span_ids: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *TableRenderScratch, allocator: std.mem.Allocator) void {
        self.cell_span_ids.deinit(allocator);
        self.* = .{};
    }
};

pub fn renderArtifactJson(allocator: std.mem.Allocator, result: anytype, options: RenderOptions) ![]u8 {
    const debug_assets = try visual_assets.collectBatch(allocator, result, options.debug_assets_dir, options.include_debug_asset_refs);
    defer visual_assets.deinitRecords(allocator, debug_assets);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeDocumentManifestOpen(writer, result, options);
    try writer.writeAll(",\"spans\":[");
    for (result.reconciled.spans, 0..) |span, index| {
        if (index > 0) try writer.writeByte(',');
        try writeSpanRecord(writer, result, options.document_id, options.source_id, options.input_sha256, span, @intCast(index), .{}, null);
    }
    try writer.writeAll("],\"blocks\":[");
    for (result.reconciled.blocks, 0..) |block, index| {
        if (index > 0) try writer.writeByte(',');
        try writeBlockRecord(writer, result, options.document_id, options.source_id, options.input_sha256, block, 0, .{}, null);
    }
    try writer.writeAll("],\"tables\":[");
    var table_scratch: TableRenderScratch = .{};
    defer table_scratch.deinit(allocator);
    for (result.tables, 0..) |table, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTableRecord(allocator, writer, options.document_id, options.source_id, options.input_sha256, result, table, @intCast(index), .{}, null, &table_scratch);
    }
    try writer.writeAll("],\"form_fields\":[");
    for (result.form_fields, 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try writeFormFieldRecord(writer, options.document_id, options.source_id, options.input_sha256, result, field, @intCast(index));
    }
    try writer.writeAll("],\"route_traces\":[");
    try writeRouteTraceRecords(writer, options.document_id, options.source_id, options.input_sha256, result, false, .{}, null);
    try writer.writeAll("],\"specialist_requests\":[");
    try specialist_protocol.writeRequestsArray(writer, result, specialistContext(options));
    try writer.writeAll("],\"specialist_attempts\":[");
    try specialist_protocol.writeAttemptsArray(writer, result, specialistContext(options));
    try writer.writeAll("],\"specialist_responses\":[");
    try specialist_protocol.writeResponsesArray(writer, result, specialistContext(options));
    try writer.writeAll("],\"specialist_results\":[");
    try specialist_protocol.writeResultsArray(writer, result, specialistContext(options));
    try writer.writeAll("],\"rag_chunks\":[");
    for (result.reconciled.chunks, 0..) |chunk, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRagChunkRecord(writer, result, options.document_id, options.source_id, options.input_sha256, chunk, 0, 0, .{}, null);
    }
    try writer.writeAll("],\"debug_assets\":[");
    try writeDebugAssetRecords(writer, options.document_id, options.source_id, options.input_sha256, debug_assets, false, null);
    try writer.writeAll("]}");

    return output.toOwnedSlice(allocator);
}

pub fn renderArtifactJsonl(allocator: std.mem.Allocator, result: anytype, options: RenderOptions) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeArtifactJsonl(allocator, writer, result, options);

    return output.toOwnedSlice(allocator);
}

pub fn writeArtifactJsonl(allocator: std.mem.Allocator, writer: anytype, result: anytype, options: RenderOptions) !void {
    const debug_assets = try visual_assets.collectBatch(allocator, result, options.debug_assets_dir, options.include_debug_asset_refs);
    defer visual_assets.deinitRecords(allocator, debug_assets);
    var route_lookup = try RouteLookup.init(allocator, result);
    defer route_lookup.deinit();
    var span_lookup = try SpanLookup.init(allocator, result);
    defer span_lookup.deinit();
    const offsets = RecordOffsets{ .route_lookup = &route_lookup, .span_lookup = &span_lookup };

    try writeDocumentManifestRecord(writer, result, options);
    try writer.writeByte('\n');
    for (result.reconciled.spans, 0..) |span, index| {
        try writeSpanRecord(writer, result, options.document_id, options.source_id, options.input_sha256, span, @intCast(index), offsets, null);
        try writer.writeByte('\n');
    }
    for (result.reconciled.blocks) |block| {
        try writeBlockRecord(writer, result, options.document_id, options.source_id, options.input_sha256, block, 0, offsets, null);
        try writer.writeByte('\n');
    }
    var table_scratch: TableRenderScratch = .{};
    defer table_scratch.deinit(allocator);
    for (result.tables, 0..) |table, index| {
        try writeTableRecord(allocator, writer, options.document_id, options.source_id, options.input_sha256, result, table, @intCast(index), offsets, null, &table_scratch);
        try writer.writeByte('\n');
    }
    for (result.form_fields, 0..) |field, index| {
        try writeFormFieldRecord(writer, options.document_id, options.source_id, options.input_sha256, result, field, @intCast(index));
        try writer.writeByte('\n');
    }
    // Indexed route matching pays off on large trace streams but can add noise on
    // small/table-heavy outputs where the linear scan is already tiny.
    const route_trace_offsets = if (routeTraceCount(result) > 10_000) offsets else RecordOffsets{};
    try writeRouteTraceRecords(writer, options.document_id, options.source_id, options.input_sha256, result, true, route_trace_offsets, null);
    _ = try specialist_protocol.writeArtifactJsonl(allocator, writer, result, specialistContext(options));
    for (result.reconciled.chunks) |chunk| {
        try writeRagChunkRecord(writer, result, options.document_id, options.source_id, options.input_sha256, chunk, 0, 0, offsets, null);
        try writer.writeByte('\n');
    }
    try writeDebugAssetRecords(writer, options.document_id, options.source_id, options.input_sha256, debug_assets, true, null);
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
        try writePageRouteRecord(writer, document_id, null, null, route, @intCast(index), null);
    }
    try writer.writeAll("],\"regions\":[");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRegionRouteRecord(writer, document_id, null, null, route, @intCast(result.page_routes.len + index), null);
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice(allocator);
}

pub fn renderTraceJson(allocator: std.mem.Allocator, result: anytype, document_id: []const u8) ![]u8 {
    return renderTraceJsonWithOptions(allocator, result, .{ .document_id = document_id });
}

pub fn renderTraceJsonWithOptions(allocator: std.mem.Allocator, result: anytype, options: RenderOptions) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\"schema_version\":\"");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"document_id\":\"");
    try writeJsonEscaped(writer, options.document_id);
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, options.source_id);
    try writer.writeAll(",\"pages\":[");
    for (result.page_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writePageRouteRecord(writer, options.document_id, options.source_id, options.input_sha256, route, @intCast(index), null);
    }
    try writer.writeAll("],\"regions\":[");
    for (result.region_routes, 0..) |route, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRegionRouteRecord(writer, options.document_id, options.source_id, options.input_sha256, route, @intCast(result.page_routes.len + index), null);
    }
    try writer.writeAll("],\"trace\":[");
    for (result.trace_records, 0..) |record, index| {
        if (index > 0) try writer.writeByte(',');
        try writeTraceRecord(writer, options.document_id, options.source_id, options.input_sha256, result, record, @intCast(result.page_routes.len + result.region_routes.len + index), null, .{});
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
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, options.source_id);
    try writer.writeAll(",\"parser_version\":\"");
    try writer.writeAll(parser_version);
    try writer.writeAll("\",\"page_count\":");
    try writer.print("{}", .{options.page_count orelse result.page_routes.len});
    try writer.writeAll(",\"encrypted\":");
    if (options.encrypted) |encrypted| {
        try writer.print("{}", .{encrypted});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"encryption\":");
    try writeEncryptionInfo(writer, options.encryption_info);
    try writer.writeAll(",\"corrupt\":");
    try writer.print("{}", .{options.corrupt orelse (options.errors.len > 0)});
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, options.input_sha256);
    try writer.writeAll(",\"source_path\":");
    try writeOptionalString(writer, options.source_path);
    try writer.writeAll(",\"extraction_options\":{\"adaptive\":true,\"specialist_config\":");
    try writer.print("{}", .{options.specialist_config_path != null});
    try writer.writeByte('}');
    try writer.writeAll(",\"route_counts\":");
    try writeRouteCounts(writer, result);
    try writer.writeAll(",\"artifact_counts\":");
    try writeArtifactCounts(writer, result, options);
    try writer.writeAll(",\"has_specialist_failures\":");
    try writer.print("{}", .{hasSpecialistFailures(result)});
    try writer.writeAll(",\"extraction_counts\":");
    try writeExtractionCounts(writer, result);
    try writer.writeAll(",\"output_artifacts\":");
    try writeBatchOutputArtifacts(writer, result, options);
    try writer.writeAll(",\"capability_coverage\":");
    try writeCapabilityCoverage(writer, false, options.include_debug_asset_refs);
    try writer.writeAll(",\"warnings\":");
    try writeDiagnostics(writer, options.warnings);
    try writer.writeAll(",\"errors\":");
    try writeDiagnostics(writer, options.errors);
    try writer.writeAll(",\"available_outputs\":[\"json\",\"artifact-jsonl\",\"stream-jsonl\",\"jsonl\",\"rag-jsonl\",\"hocr\",\"alto\",\"debug-svg\"]");
    try writeProvenance(writer, .{
        .document_id = options.document_id,
        .source_id = options.source_id,
        .input_sha256 = options.input_sha256,
        .artifact_id = "document_manifest",
        .source_kind = "lifecycle",
        .confidence = 1.0,
    });
}

fn hasSpecialistFailures(result: anytype) bool {
    for (result.ocr_attempts) |attempt| {
        switch (attempt.status) {
            .unavailable, .failed, .timeout, .invalid_output => return true,
            else => {},
        }
    }
    return false;
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

fn writeEncryptionInfo(writer: anytype, info: ?encryption.Info) !void {
    const value = info orelse encryption.Info{};

    try writer.writeAll("{\"encrypted\":");
    try writer.print("{}", .{value.encrypted});
    try writer.writeAll(",\"requires_password\":");
    try writer.print("{}", .{value.requires_password});
    try writer.writeAll(",\"authenticated\":");
    try writer.print("{}", .{value.authenticated});
    try writer.writeAll(",\"auth_type\":\"");
    try writer.writeAll(@tagName(value.auth_type));
    try writer.writeAll("\",\"encryption_version\":");
    try writer.print("{}", .{value.encryption_version});
    try writer.writeAll(",\"security_revision\":");
    try writer.print("{}", .{value.security_revision});
    try writer.writeAll(",\"key_bits\":");
    try writer.print("{}", .{value.key_bits});
    try writer.writeAll(",\"stream_method\":\"");
    try writer.writeAll(@tagName(value.stream_method));
    try writer.writeAll("\",\"string_method\":\"");
    try writer.writeAll(@tagName(value.string_method));
    try writer.writeAll("\",\"encrypt_metadata\":");
    try writer.print("{}", .{value.encrypt_metadata});
    try writer.writeAll(",\"weak_crypto\":");
    try writer.print("{}", .{value.weak_crypto});
    try writer.writeAll(",\"permissions\":");
    try writePermissions(writer, value.permissions);
    try writer.writeByte('}');
}

fn writePermissions(writer: anytype, permissions: encryption.Permissions) !void {
    try writer.writeAll("{\"raw\":");
    try writer.print("{}", .{permissions.raw});
    try writer.writeAll(",\"print_low_resolution\":");
    try writer.print("{}", .{permissions.print_low_resolution});
    try writer.writeAll(",\"modify\":");
    try writer.print("{}", .{permissions.modify});
    try writer.writeAll(",\"extract\":");
    try writer.print("{}", .{permissions.extract});
    try writer.writeAll(",\"annotate\":");
    try writer.print("{}", .{permissions.annotate});
    try writer.writeAll(",\"fill_forms\":");
    try writer.print("{}", .{permissions.fill_forms});
    try writer.writeAll(",\"accessibility\":");
    try writer.print("{}", .{permissions.accessibility});
    try writer.writeAll(",\"assemble\":");
    try writer.print("{}", .{permissions.assemble});
    try writer.writeAll(",\"print_high_resolution\":");
    try writer.print("{}", .{permissions.print_high_resolution});
    try writer.writeByte('}');
}

fn writeArtifactCounts(writer: anytype, result: anytype, options: RenderOptions) !void {
    const specialist_counts = specialist_protocol.counts(result);
    try writer.print(
        "{{\"spans\":{},\"blocks\":{},\"tables\":{},\"form_fields\":{},\"route_traces\":{},\"specialist_requests\":{},\"specialist_attempts\":{},\"specialist_responses\":{},\"specialist_results\":{},\"rag_chunks\":{},\"debug_assets\":{}}}",
        .{
            result.reconciled.spans.len,
            result.reconciled.blocks.len,
            result.tables.len,
            result.form_fields.len,
            routeTraceCount(result),
            specialist_counts.requests,
            specialist_counts.attempts,
            specialist_counts.responses,
            specialist_counts.results,
            result.reconciled.chunks.len,
            visual_assets.assetCount(result, options.include_debug_asset_refs),
        },
    );
}

fn writeExtractionCounts(writer: anytype, result: anytype) !void {
    var ocr_spans: usize = 0;
    var table_spans: usize = 0;
    var formula_spans: usize = 0;
    for (result.reconciled.spans) |span| {
        if (span.chosen_source == .fresh_ocr or span.chosen_source == .embedded_ocr or
            span.span.source == .fresh_ocr or span.span.source == .embedded_ocr)
        {
            ocr_spans += 1;
        }
        if (span.chosen_source == .table_model or span.span.source == .table_model) table_spans += 1;
        if (span.chosen_source == .formula_model or span.span.source == .formula_model) formula_spans += 1;
    }

    var table_cells: usize = 0;
    for (result.tables) |table| {
        for (table.rows) |row| table_cells += row.cells.len;
    }

    const routes = routeTotalsFromResult(result);
    try writer.print(
        "{{\"ocr_spans\":{},\"ocr_regions\":{},\"tables\":{},\"table_cells\":{},\"table_spans\":{},\"form_fields\":{},\"formula_regions\":{},\"formula_spans\":{}}}",
        .{
            ocr_spans,
            routes.ocr_regions,
            result.tables.len,
            table_cells,
            table_spans,
            result.form_fields.len,
            routes.formula_regions,
            formula_spans,
        },
    );
}

fn writeStreamExtractionCounts(writer: anytype, counts: StreamCounts, routes: RouteTotals) !void {
    try writer.print(
        "{{\"ocr_spans\":null,\"ocr_regions\":{},\"tables\":{},\"table_cells\":null,\"table_spans\":null,\"form_fields\":0,\"formula_regions\":{},\"formula_spans\":null}}",
        .{
            routes.ocr_regions,
            counts.tables,
            routes.formula_regions,
        },
    );
}

fn routeTotalsFromResult(result: anytype) RouteTotals {
    var totals = RouteTotals{
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

const ArtifactHashKind = enum {
    spans,
    blocks,
    tables,
    form_fields,
    route_traces,
    specialist_requests,
    specialist_attempts,
    specialist_responses,
    specialist_results,
    rag_chunks,
    debug_assets,
};

const OutputArtifactSpec = struct {
    name: []const u8,
    record_type: []const u8,
    kind: ArtifactHashKind,
};

const output_artifact_specs = [_]OutputArtifactSpec{
    .{ .name = "spans", .record_type = "span", .kind = .spans },
    .{ .name = "blocks", .record_type = "block", .kind = .blocks },
    .{ .name = "tables", .record_type = "table", .kind = .tables },
    .{ .name = "form_fields", .record_type = "form_field", .kind = .form_fields },
    .{ .name = "route_traces", .record_type = "route_trace", .kind = .route_traces },
    .{ .name = "specialist_requests", .record_type = "specialist_request", .kind = .specialist_requests },
    .{ .name = "specialist_attempts", .record_type = "specialist_attempt", .kind = .specialist_attempts },
    .{ .name = "specialist_responses", .record_type = "specialist_response", .kind = .specialist_responses },
    .{ .name = "specialist_results", .record_type = "specialist_result", .kind = .specialist_results },
    .{ .name = "rag_chunks", .record_type = "rag_chunk", .kind = .rag_chunks },
    .{ .name = "debug_assets", .record_type = "debug_asset", .kind = .debug_assets },
};

fn writeBatchOutputArtifacts(writer: anytype, result: anytype, options: RenderOptions) !void {
    try writer.writeByte('[');
    for (output_artifact_specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        try writeOutputArtifactOpen(writer, spec.name, spec.record_type);
        const count = outputArtifactCount(result, spec.kind, options);
        try writer.print(",\"count\":{},\"hash_scope\":\"record_payloads\",\"sha256\":\"", .{count});
        const digest = artifactDigest(result, spec.kind, options);
        try writer.writeAll(&digest);
        try writer.writeAll("\"}");
    }
    try writer.writeByte(']');
}

fn writeStreamingOutputArtifacts(writer: anytype, counts: ?StreamCounts) !void {
    try writer.writeByte('[');
    for (output_artifact_specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        try writeOutputArtifactOpen(writer, spec.name, spec.record_type);
        try writer.writeAll(",\"count\":");
        if (counts) |stream_counts| {
            try writer.print("{}", .{streamOutputArtifactCount(stream_counts, spec.kind)});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"hash_scope\":\"stream_payloads\",\"sha256\":null}");
    }
    try writer.writeByte(']');
}

fn writeOutputArtifactOpen(writer: anytype, name: []const u8, record_type: []const u8) !void {
    try writer.writeAll("{\"artifact_name\":\"");
    try writeJsonEscaped(writer, name);
    try writer.writeAll("\",\"record_type\":\"");
    try writeJsonEscaped(writer, record_type);
    try writer.writeByte('"');
}

fn outputArtifactCount(result: anytype, kind: ArtifactHashKind, options: RenderOptions) usize {
    return switch (kind) {
        .spans => result.reconciled.spans.len,
        .blocks => result.reconciled.blocks.len,
        .tables => result.tables.len,
        .form_fields => result.form_fields.len,
        .route_traces => routeTraceCount(result),
        .specialist_requests => specialist_protocol.countRequests(result),
        .specialist_attempts => specialist_protocol.countAttempts(result),
        .specialist_responses => specialist_protocol.countResponses(result),
        .specialist_results => specialist_protocol.countResults(result),
        .rag_chunks => result.reconciled.chunks.len,
        .debug_assets => visual_assets.assetCount(result, options.include_debug_asset_refs),
    };
}

fn streamOutputArtifactCount(counts: StreamCounts, kind: ArtifactHashKind) usize {
    return switch (kind) {
        .spans => counts.spans,
        .blocks => counts.blocks,
        .tables => counts.tables,
        .form_fields => 0,
        .route_traces => counts.route_traces,
        .specialist_requests => counts.specialist_requests,
        .specialist_attempts => counts.specialist_attempts,
        .specialist_responses => counts.specialist_responses,
        .specialist_results => counts.specialist_results,
        .rag_chunks => counts.rag_chunks,
        .debug_assets => counts.debug_assets,
    };
}

fn artifactDigest(result: anytype, kind: ArtifactHashKind, options: RenderOptions) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(schema_version);
    hashText(&hasher, @tagName(kind));
    switch (kind) {
        .spans => hashSpans(&hasher, result),
        .blocks => hashBlocks(&hasher, result),
        .tables => hashTables(&hasher, result),
        .form_fields => hashFormFields(&hasher, result),
        .route_traces => hashRouteTraces(&hasher, result),
        .specialist_requests => hashSpecialistProtocol(&hasher, result, .requests),
        .specialist_attempts => hashOcrAttempts(&hasher, result),
        .specialist_responses => hashSpecialistProtocol(&hasher, result, .responses),
        .specialist_results => hashSpecialistProtocol(&hasher, result, .results),
        .rag_chunks => hashRagChunks(&hasher, result),
        .debug_assets => hashDebugAssets(&hasher, options.include_debug_asset_refs),
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn hashSpans(hasher: anytype, result: anytype) void {
    for (result.reconciled.spans) |span| {
        hashPrint(hasher, "{d}|{d:.2}|{d:.2}|{d:.2}|{d:.2}|", .{
            span.span.page_index,
            span.span.bbox.x0,
            span.span.bbox.y0,
            span.span.bbox.x1,
            span.span.bbox.y1,
        });
        hashText(hasher, span.span.text);
        hashPrint(hasher, "{s}|{s}|{d:.3};", .{ sourceKindName(span.span.source), sourceKindName(span.chosen_source), span.confidence });
    }
}

fn hashBlocks(hasher: anytype, result: anytype) void {
    for (result.reconciled.blocks) |block| {
        hashPrint(hasher, "{d}|{d}|{s}|", .{
            block.page_index,
            block.id,
            blockKindName(block.kind),
        });
        hashText(hasher, block.text);
        hashPrint(hasher, "{d:.3}|{d}|{d};", .{
            block.confidence,
            block.span_start,
            block.span_count,
        });
    }
}

fn hashTables(hasher: anytype, result: anytype) void {
    for (result.tables) |table| {
        hashPrint(hasher, "{d}|{d}|{d}|{d:.3};", .{ table.page_index, table.block_index, table.rows.len, table.confidence });
        for (table.rows) |row| {
            hashPrint(hasher, "r{d}|", .{row.row_index});
            for (row.cells) |cell| {
                hashPrint(hasher, "c{d},{d},{d},{d},{s},", .{
                    cell.row_index,
                    cell.column_index,
                    cell.rowspan,
                    cell.colspan,
                    tableCellRoleName(cell.role),
                });
                hashText(hasher, cell.text);
            }
        }
    }
}

fn hashFormFields(hasher: anytype, result: anytype) void {
    for (result.form_fields) |field| {
        hashText(hasher, field.name);
        hashText(hasher, field.field_type);
        if (field.value) |value| hashText(hasher, value);
        if (field.rect) |rect| hashPrint(hasher, "{d:.2},{d:.2},{d:.2},{d:.2};", .{ rect[0], rect[1], rect[2], rect[3] });
    }
}

fn hashRouteTraces(hasher: anytype, result: anytype) void {
    for (result.page_routes) |route| hashRoute(hasher, "page", route.page_index, null, route.route, route.reason_mask);
    for (result.region_routes) |route| hashRoute(hasher, "region", route.page_index, route.region_index, route.route, route.reason_mask);
    for (result.trace_records) |record| hashRoute(hasher, @tagName(record.stage), record.page_index, record.region_index, record.route, record.reason_mask);
}

fn hashRoute(hasher: anytype, kind: []const u8, page_index: u32, region_index: ?u32, route: anytype, reason_mask: u32) void {
    hashPrint(hasher, "{s}|{d}|", .{ kind, page_index });
    if (region_index) |region| hashPrint(hasher, "{d}|", .{region}) else hashText(hasher, "null|");
    hashPrint(hasher, "{s}|{d};", .{ routeName(route), reason_mask });
}

const SpecialistHashKind = enum { requests, responses, results };

fn hashSpecialistProtocol(hasher: anytype, result: anytype, kind: SpecialistHashKind) void {
    switch (kind) {
        .requests => {
            for (result.page_routes) |route| {
                if (route.route.needs_ocr) hashPrint(hasher, "ocr|{d}|{d};", .{ route.page_index, route.reason_mask });
            }
            for (result.region_routes) |route| {
                if (route.route.needs_table_model) hashPrint(hasher, "table|{d}|{d}|{d};", .{ route.page_index, route.region_index, route.reason_mask });
                if (route.route.needs_formula_model) hashPrint(hasher, "formula|{d}|{d}|{d};", .{ route.page_index, route.region_index, route.reason_mask });
                if (route.route.needs_layout_model) hashPrint(hasher, "layout|{d}|{d}|{d};", .{ route.page_index, route.region_index, route.reason_mask });
            }
        },
        .responses => {
            for (result.page_routes) |route| {
                if (route.route.needs_ocr) hashPrint(hasher, "ocr-response|{d};", .{route.page_index});
            }
        },
        .results => {
            for (result.reconciled.spans) |span| {
                if (span.chosen_source == .fresh_ocr or span.span.source == .fresh_ocr) {
                    hashPrint(hasher, "ocr-result|{d}|", .{span.span.page_index});
                    hashText(hasher, span.span.text);
                }
            }
        },
    }
}

fn hashOcrAttempts(hasher: anytype, result: anytype) void {
    for (result.ocr_attempts) |attempt| {
        hashPrint(hasher, "{d}|{d}|{s}|{s}|{d}|{d}|{d}|{d}|{d:.3}|{d:.6}|{};", .{
            attempt.page_index,
            attempt.attempt_index,
            @tagName(attempt.status),
            @tagName(attempt.backend),
            attempt.dpi,
            attempt.psm.tesseractNumber(),
            attempt.span_count,
            attempt.character_count,
            attempt.mean_confidence,
            attempt.text_coverage,
            attempt.selected,
        });
        if (attempt.diagnostic_code) |code| hashText(hasher, @tagName(code));
    }
}

fn hashRagChunks(hasher: anytype, result: anytype) void {
    for (result.reconciled.chunks) |chunk| {
        hashPrint(hasher, "{d}|{d}|{d}|{d}|", .{
            chunk.chunk_index,
            chunk.block_start,
            chunk.block_count,
            chunk.page_start,
        });
        hashText(hasher, chunk.content);
    }
}

fn hashDebugAssets(hasher: anytype, include_debug_asset_refs: bool) void {
    if (!include_debug_asset_refs) return;
    hashText(hasher, "visual-review-assets-v1");
    hashPrint(hasher, "{};", .{include_debug_asset_refs});
}

fn hashText(hasher: anytype, text: []const u8) void {
    hasher.update(text);
    hasher.update("\x1f");
}

fn hashPrint(hasher: anytype, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch unreachable;
    hasher.update(text);
}

fn writeCapabilityCoverage(writer: anytype, streaming: bool, include_debug_asset_refs: bool) !void {
    try writer.print(
        "{{\"native_text\":true,\"span_model\":true,\"layout_reconstruction\":true,\"complexity_routing\":true,\"reconciliation\":true,\"table_reconstruction\":true,\"form_fields\":true,\"ocr_adapter\":true,\"specialist_protocol\":true,\"formula_routing\":true,\"formula_recognition\":false,\"debug_assets\":{},\"streaming\":{}}}",
        .{ include_debug_asset_refs, streaming },
    );
}

fn writeDiagnostics(writer: anytype, diagnostics: []const ManifestDiagnostic) !void {
    try writer.writeByte('[');
    for (diagnostics, 0..) |diagnostic, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"code\":\"");
        try writeJsonEscaped(writer, diagnostic.code);
        try writer.writeAll("\",\"message\":\"");
        try writeJsonEscaped(writer, diagnostic.message);
        try writer.writeAll("\",\"offset\":");
        if (diagnostic.offset) |offset| {
            try writer.print("{}", .{offset});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

pub fn writeStreamManifestRecord(writer: anytype, options: RenderOptions, event_index: u64) !void {
    try writeRecordHeader(writer, "document_manifest");
    try writeStreamMeta(writer, .{
        .event_type = "document_manifest",
        .event_index = event_index,
        .sequence_scope = "document",
    });
    try writeDocumentId(writer, options.document_id);
    try writeSourceId(writer, options.source_id);
    try writer.writeAll(",\"parser_version\":\"");
    try writer.writeAll(parser_version);
    try writer.writeAll("\",\"streaming\":true,\"page_count\":");
    if (options.page_count) |page_count| {
        try writer.print("{}", .{page_count});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"encrypted\":");
    if (options.encrypted) |encrypted| {
        try writer.print("{}", .{encrypted});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"encryption\":");
    try writeEncryptionInfo(writer, options.encryption_info);
    try writer.writeAll(",\"corrupt\":");
    try writer.print("{}", .{options.corrupt orelse (options.errors.len > 0)});
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, options.input_sha256);
    try writer.writeAll(",\"source_path\":");
    try writeOptionalString(writer, options.source_path);
    try writer.writeAll(",\"extraction_options\":{\"adaptive\":true,\"streaming\":true,\"specialist_config\":");
    try writer.print("{}", .{options.specialist_config_path != null});
    try writer.writeByte('}');
    try writer.writeAll(",\"route_counts\":null,\"artifact_counts\":null,\"extraction_counts\":null");
    try writer.writeAll(",\"output_artifacts\":");
    try writeStreamingOutputArtifacts(writer, null);
    try writer.writeAll(",\"capability_coverage\":");
    try writeCapabilityCoverage(writer, true, options.include_debug_asset_refs);
    try writer.writeAll(",\"warnings\":");
    try writeDiagnostics(writer, options.warnings);
    try writer.writeAll(",\"errors\":");
    try writeDiagnostics(writer, options.errors);
    try writer.writeAll(",\"available_outputs\":[\"stream-jsonl\",\"json\",\"artifact-jsonl\",\"jsonl\",\"rag-jsonl\",\"hocr\",\"alto\",\"debug-svg\"]");
    try writeProvenance(writer, .{
        .document_id = options.document_id,
        .source_id = options.source_id,
        .input_sha256 = options.input_sha256,
        .artifact_id = "document_manifest",
        .source_kind = "lifecycle",
        .confidence = 1.0,
    });
    try writer.writeByte('}');
}

pub fn writePageStartedRecord(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, page_index: u32, bbox: layout.BBox, event_index: u64) !void {
    try writeRecordHeader(writer, "page_started");
    try writeStreamMeta(writer, .{
        .event_type = "page_started",
        .event_index = event_index,
        .page_index = page_index,
        .sequence_scope = "page",
    });
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    try writer.print(",\"page_index\":{},\"bbox\":", .{page_index});
    try writeBBoxJson(writer, bbox);
    try writer.writeAll(",\"status\":\"running\"");
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "page-started",
        .artifact_index = page_index,
        .page_index = page_index,
        .bbox = bbox,
        .source_kind = "lifecycle",
        .confidence = 1.0,
    });
    try writer.writeAll("[],\"block_ids\":[],\"chunk_ids\":[]");
    try writeEmptyRouteProvenance(writer);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

pub fn writePageFinishedRecord(
    writer: anytype,
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    page_index: u32,
    bbox: layout.BBox,
    counts: StreamCounts,
    routes: RouteTotals,
    event_index: u64,
) !void {
    try writeRecordHeader(writer, "page_finished");
    try writeStreamMeta(writer, .{
        .event_type = "page_finished",
        .event_index = event_index,
        .page_index = page_index,
        .sequence_scope = "page",
    });
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    try writer.print(",\"page_index\":{},\"bbox\":", .{page_index});
    try writeBBoxJson(writer, bbox);
    try writer.writeAll(",\"status\":\"completed\",\"artifact_counts\":");
    try writeStreamCounts(writer, counts);
    try writer.writeAll(",\"route_counts\":");
    try writeRouteTotals(writer, routes);
    try writer.writeAll(",\"warnings\":[]");
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "page-finished",
        .artifact_index = page_index,
        .page_index = page_index,
        .bbox = bbox,
        .source_kind = "lifecycle",
        .confidence = 1.0,
    });
    try writer.writeAll("[],\"block_ids\":[],\"chunk_ids\":[]");
    try writeEmptyRouteProvenance(writer);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

pub fn writeDocumentFinishedRecord(
    writer: anytype,
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    counts: StreamCounts,
    routes: RouteTotals,
    elapsed_ms: u64,
    event_index: u64,
) !void {
    try writeRecordHeader(writer, "document_finished");
    try writeStreamMeta(writer, .{
        .event_type = "document_finished",
        .event_index = event_index,
        .sequence_scope = "document",
    });
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    try writer.writeAll(",\"status\":\"completed\",\"artifact_counts\":");
    try writeStreamCounts(writer, counts);
    try writer.writeAll(",\"route_counts\":");
    try writeRouteTotals(writer, routes);
    try writer.writeAll(",\"extraction_counts\":");
    try writeStreamExtractionCounts(writer, counts, routes);
    try writer.writeAll(",\"output_artifacts\":");
    try writeStreamingOutputArtifacts(writer, counts);
    try writer.print(",\"elapsed_ms\":{},\"warnings\":[],\"errors\":[]", .{elapsed_ms});
    try writeProvenance(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id = "document_finished",
        .source_kind = "lifecycle",
        .confidence = 1.0,
    });
    try writer.writeByte('}');
}

pub fn writeSpanStreamRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, span: anytype, span_index: u32, offsets: RecordOffsets, meta: StreamRecordMeta) !void {
    try writeSpanRecord(writer, result, document_id, source_id, input_sha256, span, span_index, offsets, meta);
}

pub fn writeBlockStreamRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, block: anytype, offsets: RecordOffsets, meta: StreamRecordMeta) !void {
    try writeBlockRecord(writer, result, document_id, source_id, input_sha256, block, offsets.block_base, offsets, meta);
}

pub fn writeTableStreamRecord(allocator: std.mem.Allocator, writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, table: anytype, table_index: u32, offsets: RecordOffsets, meta: StreamRecordMeta, scratch: *TableRenderScratch) !void {
    try writeTableRecord(allocator, writer, document_id, source_id, input_sha256, result, table, table_index, offsets, meta, scratch);
}

pub fn writeRouteTraceStreamRecords(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, offsets: RecordOffsets, event_index: *u64) !usize {
    const before = event_index.*;
    try writeRouteTraceRecords(writer, document_id, source_id, input_sha256, result, true, offsets, event_index);
    return @intCast(event_index.* - before);
}

pub fn writeRagChunkStreamRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, chunk: anytype, offsets: RecordOffsets, meta: StreamRecordMeta) !void {
    try writeRagChunkRecord(writer, result, document_id, source_id, input_sha256, chunk, offsets.chunk_base, offsets.block_base, offsets, meta);
}

pub fn writeDebugAssetStreamRecords(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, records: []const visual_assets.AssetRecord, event_index: *u64) !usize {
    const before = event_index.*;
    try writeDebugAssetRecords(writer, document_id, source_id, input_sha256, records, true, event_index);
    return @intCast(event_index.* - before);
}

fn writeSpanRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, span: anytype, span_index: u32, offsets: RecordOffsets, stream_meta: ?StreamRecordMeta) !void {
    try writeRecordHeader(writer, "span");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
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
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "span",
        .artifact_index = span_index,
        .page_index = span.span.page_index,
        .bbox = span.span.bbox,
        .source_kind = provenanceSourceKind(span.chosen_source),
        .confidence = span.confidence,
    });
    try writeSingleId(writer, "span", span_index);
    try writer.writeAll(",\"block_ids\":");
    if (span.span.block_id) |block_id| {
        try writeSingleId(writer, "block", block_id);
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"chunk_ids\":[]");
    try writeMatchedRouteProvenance(writer, result, span.span.page_index, span.span.bbox, offsets, stream_meta != null);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeBlockRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, block: anytype, block_base: u32, offsets: RecordOffsets, stream_meta: ?StreamRecordMeta) !void {
    try writeRecordHeader(writer, "block");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    try writer.print(",\"block_id\":\"block-{d}\",\"block_index\":{},\"page_index\":{},\"kind\":\"{s}\"", .{
        block_base + block.id,
        block_base + block.id,
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
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "block",
        .artifact_index = block_base + block.id,
        .page_index = block.page_index,
        .bbox = block.bbox,
        .source_kind = provenanceSourceKindFromMask(block.source_mask),
        .confidence = block.confidence,
    });
    try writeIdRange(writer, "span", block.span_start, block.span_count);
    try writer.writeAll(",\"block_ids\":");
    try writeSingleId(writer, "block", block_base + block.id);
    try writer.writeAll(",\"chunk_ids\":[]");
    try writeMatchedRouteProvenance(writer, result, block.page_index, block.bbox, offsets, stream_meta != null);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeTableRecord(allocator: std.mem.Allocator, writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, table: anytype, table_index: u32, offsets: RecordOffsets, stream_meta: ?StreamRecordMeta, scratch: *TableRenderScratch) !void {
    try writeRecordHeader(writer, "table");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    const logical_index = table.logical_table_index orelse table_index;
    try writer.print(
        ",\"table_id\":\"table-{d}\",\"logical_table_id\":\"logical-table-{d}\",\"table_index\":{},\"table_part_index\":{},\"continued_from_table_id\":",
        .{ table_index, logical_index, table_index, table.table_part_index },
    );
    try writeOptionalTableId(writer, table.continued_from_table_index);
    try writer.writeAll(",\"continued_to_table_id\":");
    try writeOptionalTableId(writer, table.continued_to_table_index);
    try writer.print(
        ",\"page_index\":{},\"block_index\":{},\"block_count\":{},\"column_count\":{},\"confidence\":{d:.3}",
        .{ table.page_index, table.block_index, table.block_count, table.column_count, table.confidence },
    );
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, table.bounds.bbox);
    try writer.writeAll(",\"source_span_ids\":");
    try writeSpanIdsInBBox(writer, result, table.page_index, table.bounds.bbox, offsets);
    try writer.writeAll(",\"rows\":[");
    for (table.rows, 0..) |row, row_index| {
        if (row_index > 0) try writer.writeByte(',');
        try writer.print("{{\"row_index\":{},\"bbox\":", .{row.row_index});
        try writeBBoxJson(writer, row.bounds.bbox);
        try writer.writeAll(",\"cells\":[");
        for (row.cells, 0..) |cell, cell_index| {
            if (cell_index > 0) try writer.writeByte(',');
            try writeCellJson(allocator, writer, document_id, source_id, input_sha256, result, table_index, cell, offsets, &scratch.cell_span_ids, stream_meta != null);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]");
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "table",
        .artifact_index = table_index,
        .page_index = table.page_index,
        .bbox = table.bounds.bbox,
        .source_kind = "table_model",
        .confidence = table.confidence,
    });
    try writer.writeAll("[]");
    try writer.writeAll(",\"block_ids\":");
    try writeIdRange(writer, "block", offsets.block_base + table.block_index, @intCast(table.block_count));
    try writer.writeAll(",\"chunk_ids\":[]");
    try writeMatchedRouteProvenance(writer, result, table.page_index, table.bounds.bbox, offsets, stream_meta != null);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeCellJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    result: anytype,
    table_index: u32,
    cell: layout.TableCell,
    offsets: RecordOffsets,
    cell_span_ids: *std.ArrayList(u32),
    stream: bool,
) !void {
    try collectCellSpanIds(allocator, cell_span_ids, result, cell, offsets);

    try writer.writeAll("{\"schema_name\":\"table_cell\",\"schema_version\":\"");
    try writer.writeAll(schema_version);
    try writer.writeAll("\",\"record_type\":\"table_cell\"");
    try writer.print(
        ",\"cell_id\":\"table-{d}-cell-{d}-{d}\",\"page_index\":{},\"row\":{},\"column\":{},\"rowspan\":{},\"colspan\":{},\"role\":\"{s}\",\"confidence\":{d:.3},\"source_id\":",
        .{
            table_index,
            cell.row_index,
            cell.column_index,
            cell.bounds.page_index,
            cell.row_index,
            cell.column_index,
            cell.rowspan,
            cell.colspan,
            tableCellRoleName(cell.role),
            cell.confidence,
        },
    );
    try writeOptionalString(writer, source_id);
    try writer.writeAll(",\"text\":\"");
    try writeJsonEscaped(writer, cell.text);
    try writer.writeAll("\",\"raw_text\":\"");
    try writeJsonEscaped(writer, cell.text);
    try writer.writeAll("\",\"normalized_text\":\"");
    try writeNormalizedJsonEscaped(writer, cell.text);
    try writer.writeAll("\",\"numeric\":");
    try writeNumericHint(writer, cell.text);
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, cell.bounds.bbox);
    try writer.writeAll(",\"source_span_ids\":");
    try writeSpanIdArray(writer, cell_span_ids.items);
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "table-cell",
        .artifact_index = table_index * 1_000_000 + cell.row_index * 1000 + cell.column_index,
        .page_index = cell.bounds.page_index,
        .bbox = cell.bounds.bbox,
        .source_kind = "table_model",
        .confidence = cell.confidence,
    });
    try writeSpanIdArray(writer, cell_span_ids.items);
    try writer.writeAll(",\"block_ids\":[]");
    try writer.writeAll(",\"chunk_ids\":[]");
    try writeMatchedRouteProvenance(writer, result, cell.bounds.page_index, cell.bounds.bbox, offsets, stream);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeFormFieldRecord(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, field: anytype, field_index: u32) !void {
    try writeRecordHeader(writer, "form_field");
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
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
    try writer.writeAll(",\"visible_value_mismatch\":false,\"missing_appearance\":false");
    const field_bbox = if (field.rect) |rect| rectToBBox(rect) else null;
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "form-field",
        .artifact_index = field_index,
        .page_index = if (field.rect == null) null else 0,
        .bbox = field_bbox,
        .source_kind = "form",
        .confidence = 1.0,
    });
    if (findManualSpanForField(result, field)) |span_index| {
        try writeSingleId(writer, "span", @intCast(span_index));
    } else {
        try writer.writeAll("[]");
    }
    try writer.writeAll(",\"block_ids\":[]");
    try writer.writeAll(",\"chunk_ids\":[]");
    if (field_bbox) |box| {
        try writeMatchedRouteProvenance(writer, result, 0, box, .{}, false);
    } else {
        try writeEmptyRouteProvenance(writer);
    }
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeRouteTraceRecords(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, jsonl: bool, offsets: RecordOffsets, stream_event_index: ?*u64) !void {
    var wrote = false;
    for (result.page_routes, 0..) |route, local_index| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        const stream_meta = nextRouteStreamMeta(stream_event_index, route.page_index);
        try writePageRouteRecord(writer, document_id, source_id, input_sha256, route, offsets.route_base + @as(u32, @intCast(local_index)), stream_meta);
        wrote = true;
    }
    const region_base = offsets.route_base + @as(u32, @intCast(result.page_routes.len));
    for (result.region_routes, 0..) |route, local_index| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        const stream_meta = nextRouteStreamMeta(stream_event_index, route.page_index);
        try writeRegionRouteRecord(writer, document_id, source_id, input_sha256, route, region_base + @as(u32, @intCast(local_index)), stream_meta);
        wrote = true;
    }
    const trace_base = region_base + @as(u32, @intCast(result.region_routes.len));
    for (result.trace_records, 0..) |record, index| {
        if (wrote) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        const stream_meta = nextRouteStreamMeta(stream_event_index, record.page_index);
        try writeTraceRecord(writer, document_id, source_id, input_sha256, result, record, trace_base + @as(u32, @intCast(index)), stream_meta, offsets);
        wrote = true;
    }
    if (jsonl and wrote) try writer.writeByte('\n');
}

fn writePageRouteRecord(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, route: anytype, route_index: u32, stream_meta: ?StreamRecordMeta) !void {
    try writeRecordHeader(writer, "route_trace");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    if (stream_meta != null) {
        try writer.print(",\"route_trace_id\":\"route-{d}\"", .{route_index});
    } else {
        try writer.print(",\"route_trace_id\":\"route-page-{d}\"", .{route.page_index});
    }
    try writer.print(",\"trace_kind\":\"page_route\",\"page_index\":{},\"region_index\":null,\"stage\":\"route_decision\"", .{route.page_index});
    try writeRouteFields(writer, route.route, route.reason_mask, route.span_count, 0, route.image_count, route.char_count, route.signals, route.bbox);
    try specialist_protocol.writeRouteTraceSpecialistFieldsWithReason(writer, route.route, route.reason_mask, route.page_index, null);
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = if (stream_meta != null) "route" else "route-page",
        .artifact_index = if (stream_meta != null) route_index else route.page_index,
        .page_index = route.page_index,
        .bbox = route.bbox,
        .source_kind = "lifecycle",
        .confidence = routeConfidence(route.route),
    });
    try writer.writeAll("[]");
    try writer.writeAll(",\"block_ids\":[]");
    try writer.writeAll(",\"chunk_ids\":[]");
    try writer.writeAll(",\"route_trace_ids\":");
    if (stream_meta != null) try writeSingleId(writer, "route", route_index) else try writeSingleId(writer, "route-page", route.page_index);
    try writer.writeAll(",\"route_reasons\":");
    try writeReasonArray(writer, route.reason_mask);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeRegionRouteRecord(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, route: anytype, route_index: u32, stream_meta: ?StreamRecordMeta) !void {
    try writeRecordHeader(writer, "route_trace");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    if (stream_meta != null) {
        try writer.print(",\"route_trace_id\":\"route-{d}\"", .{route_index});
    } else {
        try writer.print(",\"route_trace_id\":\"route-region-{d}\"", .{route.region_index});
    }
    try writer.print(",\"trace_kind\":\"region_route\",\"page_index\":{},\"region_index\":{},\"stage\":\"route_decision\"", .{ route.page_index, route.region_index });
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
    try specialist_protocol.writeRouteTraceSpecialistFieldsWithReason(writer, route.route, route.reason_mask, route.page_index, route.region_index);
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = if (stream_meta != null) "route" else "route-region",
        .artifact_index = if (stream_meta != null) route_index else route.region_index,
        .page_index = route.page_index,
        .bbox = route.bbox,
        .source_kind = "lifecycle",
        .confidence = routeConfidence(route.route),
    });
    try writer.writeAll("[]");
    try writer.writeAll(",\"block_ids\":[]");
    try writer.writeAll(",\"chunk_ids\":[]");
    try writer.writeAll(",\"route_trace_ids\":");
    if (stream_meta != null) try writeSingleId(writer, "route", route_index) else try writeSingleId(writer, "route-region", route.region_index);
    try writer.writeAll(",\"route_reasons\":");
    try writeReasonArray(writer, route.reason_mask);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

fn writeTraceRecord(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, result: anytype, record: anytype, trace_index: u32, stream_meta: ?StreamRecordMeta, offsets: RecordOffsets) !void {
    try writeRecordHeader(writer, "route_trace");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writeSourceId(writer, source_id);
    if (stream_meta != null) {
        try writer.print(",\"route_trace_id\":\"route-{d}\"", .{trace_index});
    } else {
        try writer.print(",\"route_trace_id\":\"trace-{d}\"", .{trace_index});
    }
    try writer.print(",\"trace_kind\":\"stage\",\"page_index\":{},\"region_index\":", .{record.page_index});
    try writeOptionalU32(writer, record.region_index);
    try writer.writeAll(",\"stage\":\"");
    try writer.writeAll(@tagName(record.stage));
    try writer.writeByte('"');
    const bbox = traceBBox(result, record, offsets);
    try writeRouteFields(writer, record.route, record.reason_mask, record.span_count, record.block_count, 0, 0, null, bbox);
    try specialist_protocol.writeRouteTraceSpecialistFieldsWithReason(writer, record.route, record.reason_mask, record.page_index, record.region_index);
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = if (stream_meta != null) "route" else "trace",
        .artifact_index = trace_index,
        .page_index = record.page_index,
        .bbox = bbox,
        .source_kind = "lifecycle",
        .confidence = routeConfidence(record.route),
    });
    try writer.writeAll("[]");
    try writer.writeAll(",\"block_ids\":[]");
    try writer.writeAll(",\"chunk_ids\":[]");
    try writer.writeAll(",\"route_trace_ids\":");
    if (stream_meta != null) try writeSingleId(writer, "route", trace_index) else try writeSingleId(writer, "trace", trace_index);
    try writer.writeAll(",\"route_reasons\":");
    try writeReasonArray(writer, record.reason_mask);
    try writer.writeByte('}');
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

fn writeRagChunkRecord(writer: anytype, result: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, chunk: anytype, chunk_base: u32, block_base: u32, offsets: RecordOffsets, stream_meta: ?StreamRecordMeta) !void {
    try writeRecordHeader(writer, "rag_chunk");
    if (stream_meta) |meta| try writeStreamMeta(writer, meta);
    try writeDocumentId(writer, document_id);
    try writer.print(",\"chunk_id\":\"chunk-{d}\",\"chunk_index\":{},\"source_id\":\"", .{ chunk_base + chunk.chunk_index, chunk_base + chunk.chunk_index });
    try writeJsonEscaped(writer, source_id orelse chunk.source_id);
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
        try writer.print("\"block-{d}\"", .{block_base + chunk.block_start + @as(u32, @intCast(offset))});
    }
    try writer.writeAll("],\"source_span_ids\":[]");
    try writeProvenancePrefix(writer, .{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .artifact_id_prefix = "chunk",
        .artifact_index = chunk_base + chunk.chunk_index,
        .page_index = chunk.page_start,
        .bbox = chunk.bbox,
        .source_kind = provenanceSourceKindFromMask(chunk.source_mask),
        .confidence = chunk.confidence,
    });
    try writer.writeAll("[]");
    try writer.writeAll(",\"block_ids\":");
    try writeIdRange(writer, "block", block_base + chunk.block_start, chunk.block_count);
    try writer.writeAll(",\"chunk_ids\":");
    try writeSingleId(writer, "chunk", chunk_base + chunk.chunk_index);
    try writeMatchedRouteProvenance(writer, result, chunk.page_start, chunk.bbox, offsets, stream_meta != null);
    try writer.writeByte('}');
    try writer.writeByte('}');
}

pub fn writeDebugAssetRecords(writer: anytype, document_id: []const u8, source_id: ?[]const u8, input_sha256: ?[]const u8, records: []const visual_assets.AssetRecord, jsonl: bool, stream_event_index: ?*u64) !void {
    for (records, 0..) |asset, index| {
        if (index > 0) {
            if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
        }
        try writeRecordHeader(writer, "debug_asset");
        if (stream_event_index) |event_index| {
            try writeStreamMeta(writer, .{
                .event_type = "debug_asset",
                .event_index = event_index.*,
                .sequence_scope = "document",
            });
            event_index.* += 1;
        }
        try writeDocumentId(writer, document_id);
        try writeSourceId(writer, source_id);
        try writer.writeAll(",\"debug_asset_id\":\"");
        try writeJsonEscaped(writer, asset.debug_asset_id);
        try writer.writeAll("\",\"asset_kind\":\"");
        try writeJsonEscaped(writer, asset.asset_kind);
        try writer.writeAll("\",\"kind\":\"");
        try writeJsonEscaped(writer, asset.kind);
        try writer.writeAll("\",\"media_type\":\"");
        try writeJsonEscaped(writer, asset.media_type);
        try writer.writeAll("\",\"output_format\":\"");
        try writeJsonEscaped(writer, asset.output_format);
        try writer.writeAll("\",\"uri\":");
        try writeOptionalString(writer, asset.uri);
        try writer.writeAll(",\"path\":");
        try writeOptionalString(writer, asset.path);
        try writer.writeAll(",\"sha256\":");
        try writeOptionalString(writer, asset.sha256);
        try writer.writeAll(",\"byte_length\":");
        if (asset.byte_length) |byte_length| {
            try writer.print("{}", .{byte_length});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"page_index\":");
        try writeOptionalU32(writer, asset.page_index);
        try writer.writeAll(",\"region_index\":");
        try writeOptionalU32(writer, asset.region_index);
        try writer.writeAll(",\"layers\":[");
        for (asset.layers, 0..) |layer, layer_index| {
            if (layer_index > 0) try writer.writeByte(',');
            try writer.writeByte('"');
            try writeJsonEscaped(writer, layer);
            try writer.writeByte('"');
        }
        try writer.writeAll("],\"stage\":\"");
        try writeJsonEscaped(writer, asset.stage);
        try writer.writeByte('"');
        try writeProvenance(writer, .{
            .document_id = document_id,
            .source_id = source_id,
            .input_sha256 = input_sha256,
            .artifact_id = asset.debug_asset_id,
            .page_index = asset.page_index,
            .source_kind = "debug",
            .confidence = 1.0,
        });
        try writer.writeByte('}');
    }
    if (jsonl and records.len > 0) try writer.writeByte('\n');
}

const ProvenanceArgs = struct {
    document_id: []const u8,
    source_id: ?[]const u8 = null,
    input_sha256: ?[]const u8 = null,
    artifact_id: []const u8,
    page_index: ?u32 = null,
    bbox: ?layout.BBox = null,
    source_kind: []const u8,
    confidence: ?f32 = null,
};

const ProvenancePrefixArgs = struct {
    document_id: []const u8,
    source_id: ?[]const u8 = null,
    input_sha256: ?[]const u8 = null,
    artifact_id_prefix: []const u8,
    artifact_index: u32,
    page_index: ?u32 = null,
    bbox: ?layout.BBox = null,
    source_kind: []const u8,
    confidence: ?f32 = null,
};

const MatchedRoute = struct {
    id_prefix: []const u8,
    id_index: u32,
    reason_mask: u32,
};

fn writeProvenance(writer: anytype, args: ProvenanceArgs) !void {
    try writer.writeAll(",\"provenance\":");
    try writeProvenanceBodyStart(writer, .{
        .document_id = args.document_id,
        .source_id = args.source_id,
        .input_sha256 = args.input_sha256,
        .artifact_id = args.artifact_id,
        .page_index = args.page_index,
        .bbox = args.bbox,
        .source_kind = args.source_kind,
        .confidence = args.confidence,
    });
    try writer.writeAll(",\"span_ids\":[],\"block_ids\":[],\"chunk_ids\":[],\"route_trace_ids\":[],\"route_reasons\":[]}");
}

fn writeProvenancePrefix(writer: anytype, args: ProvenancePrefixArgs) !void {
    try writer.writeAll(",\"provenance\":");
    try writer.writeAll("{\"document_id\":\"");
    try writeJsonEscaped(writer, args.document_id);
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, args.source_id);
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, args.input_sha256);
    try writer.writeAll(",\"artifact_id\":\"");
    try writeJsonEscaped(writer, args.artifact_id_prefix);
    try writer.print("-{d}\",\"page_index\":", .{args.artifact_index});
    try writeOptionalU32(writer, args.page_index);
    try writer.writeAll(",\"bbox\":");
    try writeOptionalBBoxJson(writer, args.bbox);
    try writer.writeAll(",\"source_kind\":\"");
    try writeJsonEscaped(writer, args.source_kind);
    try writer.writeAll("\",\"confidence\":");
    try writeOptionalF32(writer, args.confidence);
    try writer.writeAll(",\"span_ids\":");
}

fn writeProvenanceBodyStart(writer: anytype, args: struct {
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    artifact_id: []const u8,
    page_index: ?u32,
    bbox: ?layout.BBox,
    source_kind: []const u8,
    confidence: ?f32,
}) !void {
    try writer.writeAll("{\"document_id\":\"");
    try writeJsonEscaped(writer, args.document_id);
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, args.source_id);
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, args.input_sha256);
    try writer.writeAll(",\"artifact_id\":\"");
    try writeJsonEscaped(writer, args.artifact_id);
    try writer.writeAll("\",\"page_index\":");
    try writeOptionalU32(writer, args.page_index);
    try writer.writeAll(",\"bbox\":");
    try writeOptionalBBoxJson(writer, args.bbox);
    try writer.writeAll(",\"source_kind\":\"");
    try writeJsonEscaped(writer, args.source_kind);
    try writer.writeAll("\",\"confidence\":");
    try writeOptionalF32(writer, args.confidence);
}

fn writeSingleId(writer: anytype, prefix: []const u8, index: u32) !void {
    try writer.writeByte('[');
    try writer.writeByte('"');
    try writeJsonEscaped(writer, prefix);
    try writer.print("-{d}\"]", .{index});
}

fn writeIdRange(writer: anytype, prefix: []const u8, start: u32, count: u32) !void {
    try writer.writeByte('[');
    for (0..count) |offset| {
        if (offset > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeJsonEscaped(writer, prefix);
        try writer.print("-{d}\"", .{start + @as(u32, @intCast(offset))});
    }
    try writer.writeByte(']');
}

fn writeOptionalTableId(writer: anytype, table_index: ?u32) !void {
    if (table_index) |index| {
        try writer.print("\"table-{d}\"", .{index});
    } else {
        try writer.writeAll("null");
    }
}

fn writeSpanIdsInBBox(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, offsets: RecordOffsets) !void {
    try writer.writeByte('[');
    var first = true;
    if (offsets.span_lookup) |lookup| {
        if (lookup.spanRange(page_index)) |range| {
            for (result.reconciled.spans[range.start..range.end], range.start..) |span, span_index| {
                if (span.span.page_index != page_index) continue;
                if (!centerInside(span.span.bbox, bbox)) continue;
                if (!first) try writer.writeByte(',');
                try writer.print("\"span-{d}\"", .{offsets.span_base + @as(u32, @intCast(span_index))});
                first = false;
            }
        }
        try writer.writeByte(']');
        return;
    }
    for (result.reconciled.spans, 0..) |span, span_index| {
        if (span.span.page_index != page_index) continue;
        if (!centerInside(span.span.bbox, bbox)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("\"span-{d}\"", .{offsets.span_base + @as(u32, @intCast(span_index))});
        first = false;
    }
    try writer.writeByte(']');
}

fn collectCellSpanIds(allocator: std.mem.Allocator, span_ids: *std.ArrayList(u32), result: anytype, cell: layout.TableCell, offsets: RecordOffsets) !void {
    span_ids.clearRetainingCapacity();
    if (offsets.span_lookup) |lookup| {
        if (lookup.spanRange(cell.bounds.page_index)) |range| {
            try collectSpanIdsInRange(allocator, span_ids, result.reconciled.spans[range.start..range.end], range.start, cell.bounds.page_index, cell.bounds.bbox, offsets.span_base);
        }
        return;
    }
    try collectSpanIdsInRange(allocator, span_ids, result.reconciled.spans, 0, cell.bounds.page_index, cell.bounds.bbox, offsets.span_base);
}

fn collectSpanIdsInRange(allocator: std.mem.Allocator, span_ids: *std.ArrayList(u32), spans: anytype, start_index: usize, page_index: u32, bbox: layout.BBox, span_base: u32) !void {
    for (spans, start_index..) |span, span_index| {
        if (span.span.page_index != page_index) continue;
        if (!centerInside(span.span.bbox, bbox)) continue;
        try span_ids.append(allocator, span_base + @as(u32, @intCast(span_index)));
    }
}

fn writeSpanIdArray(writer: anytype, span_ids: []const u32) !void {
    try writer.writeByte('[');
    for (span_ids, 0..) |span_id, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"span-{d}\"", .{span_id});
    }
    try writer.writeByte(']');
}

fn writeNormalizedJsonEscaped(writer: anytype, text: []const u8) !void {
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try writer.writeByte(' ');
                previous_space = true;
            }
        } else {
            try writeJsonEscapedByte(writer, byte);
            previous_space = false;
        }
    }
}

fn writeNumericHint(writer: anytype, text: []const u8) !void {
    const parsed = parseNumericCell(text);
    if (parsed) |numeric| {
        try writer.print(
            "{{\"is_numeric\":true,\"value\":{d:.6},\"negative\":{},\"format\":\"{s}\"}}",
            .{ numeric.value, numeric.negative, numeric.format },
        );
    } else {
        try writer.writeAll("{\"is_numeric\":false,\"value\":null,\"negative\":false,\"format\":null}");
    }
}

const NumericCell = struct {
    value: f64,
    negative: bool,
    format: []const u8,
};

fn parseNumericCell(text: []const u8) ?NumericCell {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 96) return null;

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var saw_digit = false;
    var negative = false;
    var paren_negative = false;
    var minus_negative = false;

    for (trimmed, 0..) |byte, index| {
        switch (byte) {
            '0'...'9' => {
                saw_digit = true;
                buf[len] = byte;
                len += 1;
            },
            '.' => {
                buf[len] = byte;
                len += 1;
            },
            ',', ' ', '\t', '$', '%' => {},
            '(' => {
                if (index != 0) return null;
                negative = true;
                paren_negative = true;
            },
            ')' => {
                if (!paren_negative or index + 1 != trimmed.len) return null;
            },
            '-' => {
                if (len != 0) return null;
                negative = true;
                minus_negative = true;
            },
            '+' => {
                if (len != 0) return null;
            },
            else => return null,
        }
        if (len >= buf.len) return null;
    }
    if (!saw_digit or len == 0) return null;
    const value = std.fmt.parseFloat(f64, buf[0..len]) catch return null;
    return .{
        .value = if (negative) -value else value,
        .negative = negative,
        .format = if (paren_negative) "parentheses" else if (minus_negative) "minus" else "plain",
    };
}

fn writeMatchedRouteProvenance(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, offsets: RecordOffsets, stream: bool) !void {
    if (findMatchedRoute(result, page_index, bbox, offsets, stream)) |route| {
        try writer.writeAll(",\"route_trace_ids\":");
        try writeSingleId(writer, route.id_prefix, route.id_index);
        try writer.writeAll(",\"route_reasons\":");
        try writeReasonArray(writer, route.reason_mask);
    } else {
        try writeEmptyRouteProvenance(writer);
    }
}

fn writeEmptyRouteProvenance(writer: anytype) !void {
    try writer.writeAll(",\"route_trace_ids\":[],\"route_reasons\":[]");
}

fn findMatchedRoute(result: anytype, page_index: u32, bbox: layout.BBox, offsets: RecordOffsets, stream: bool) ?MatchedRoute {
    if (offsets.route_lookup) |lookup| {
        if (findMatchedRouteIndexed(result, page_index, bbox, offsets, stream, lookup)) |route| return route;
    }

    const region_base = offsets.route_base + @as(u32, @intCast(result.page_routes.len));
    var best_region: ?MatchedRoute = null;
    var best_area = std.math.inf(f64);
    for (result.region_routes, 0..) |route, index| {
        if (route.page_index != page_index) continue;
        if (!boxesIntersect(route.bbox, bbox)) continue;
        const area = boxArea(route.bbox);
        if (area >= best_area) continue;
        best_area = area;
        best_region = .{
            .id_prefix = if (stream) "route" else "route-region",
            .id_index = if (stream) region_base + @as(u32, @intCast(index)) else route.region_index,
            .reason_mask = route.reason_mask,
        };
    }
    if (best_region) |route| return route;

    for (result.page_routes, 0..) |route, index| {
        if (route.page_index != page_index) continue;
        return .{
            .id_prefix = if (stream) "route" else "route-page",
            .id_index = if (stream) offsets.route_base + @as(u32, @intCast(index)) else route.page_index,
            .reason_mask = route.reason_mask,
        };
    }

    const trace_base = region_base + @as(u32, @intCast(result.region_routes.len));
    for (result.trace_records, 0..) |record, index| {
        if (record.page_index != page_index) continue;
        if (traceBBox(result, record, offsets)) |box| {
            if (!boxesIntersect(box, bbox)) continue;
        }
        return .{
            .id_prefix = if (stream) "route" else "trace",
            .id_index = trace_base + @as(u32, @intCast(index)),
            .reason_mask = record.reason_mask,
        };
    }
    return null;
}

fn findMatchedRouteIndexed(result: anytype, page_index: u32, bbox: layout.BBox, offsets: RecordOffsets, stream: bool, lookup: *const RouteLookup) ?MatchedRoute {
    const region_base = offsets.route_base + @as(u32, @intCast(result.page_routes.len));
    var best_region: ?MatchedRoute = null;
    var best_area = std.math.inf(f64);
    if (lookup.regionRange(page_index)) |range| {
        for (result.region_routes[range.start..range.end], range.start..) |route, index| {
            if (!boxesIntersect(route.bbox, bbox)) continue;
            const area = boxArea(route.bbox);
            if (area >= best_area) continue;
            best_area = area;
            best_region = .{
                .id_prefix = if (stream) "route" else "route-region",
                .id_index = if (stream) region_base + @as(u32, @intCast(index)) else route.region_index,
                .reason_mask = route.reason_mask,
            };
        }
    }
    if (best_region) |route| return route;

    if (lookup.pageRouteIndex(page_index)) |index| {
        const route = result.page_routes[index];
        return .{
            .id_prefix = if (stream) "route" else "route-page",
            .id_index = if (stream) offsets.route_base + @as(u32, @intCast(index)) else route.page_index,
            .reason_mask = route.reason_mask,
        };
    }

    const trace_base = region_base + @as(u32, @intCast(result.region_routes.len));
    if (lookup.traceRange(page_index)) |range| {
        for (result.trace_records[range.start..range.end], range.start..) |record, index| {
            if (traceBBox(result, record, offsets)) |box| {
                if (!boxesIntersect(box, bbox)) continue;
            }
            return .{
                .id_prefix = if (stream) "route" else "trace",
                .id_index = trace_base + @as(u32, @intCast(index)),
                .reason_mask = record.reason_mask,
            };
        }
    }
    return null;
}

fn provenanceSourceKind(source: layout.SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula",
        .manual => "form",
        .poppler_text => "external_text",
    };
}

fn provenanceSourceKindFromMask(mask: u32) []const u8 {
    if (mask == 0) return "unknown";
    if (countSourceBits(mask) != 1) return "mixed";
    if (hasSource(mask, .native_pdf)) return provenanceSourceKind(.native_pdf);
    if (hasSource(mask, .embedded_ocr)) return provenanceSourceKind(.embedded_ocr);
    if (hasSource(mask, .fresh_ocr)) return provenanceSourceKind(.fresh_ocr);
    if (hasSource(mask, .table_model)) return provenanceSourceKind(.table_model);
    if (hasSource(mask, .formula_model)) return provenanceSourceKind(.formula_model);
    if (hasSource(mask, .manual)) return provenanceSourceKind(.manual);
    if (hasSource(mask, .poppler_text)) return provenanceSourceKind(.poppler_text);
    return "unknown";
}

fn writeOptionalBBoxJson(writer: anytype, bbox: ?layout.BBox) !void {
    if (bbox) |box| {
        try writeBBoxJson(writer, box);
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalF32(writer: anytype, value: ?f32) !void {
    if (value) |number| {
        try writer.print("{d:.3}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn rectToBBox(rect: [4]f64) layout.BBox {
    return .{ .x0 = rect[0], .y0 = rect[1], .x1 = rect[2], .y1 = rect[3] };
}

fn boxesIntersect(a: layout.BBox, b: layout.BBox) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
}

fn boxArea(box: layout.BBox) f64 {
    return @max(0.0, box.x1 - box.x0) * @max(0.0, box.y1 - box.y0);
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

fn writeStreamMeta(writer: anytype, meta: StreamRecordMeta) !void {
    try writer.writeAll(",\"event_type\":\"");
    try writeJsonEscaped(writer, meta.event_type);
    try writer.print("\",\"event_index\":{}", .{meta.event_index});
    try writer.writeAll(",\"sequence_scope\":\"");
    try writeJsonEscaped(writer, meta.sequence_scope);
    try writer.writeByte('"');
}

fn nextRouteStreamMeta(stream_event_index: ?*u64, page_index: u32) ?StreamRecordMeta {
    if (stream_event_index) |event_index| {
        const meta = StreamRecordMeta{
            .event_type = "route_trace",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        };
        event_index.* += 1;
        return meta;
    }
    return null;
}

fn writeStreamCounts(writer: anytype, counts: StreamCounts) !void {
    try writer.print(
        "{{\"spans\":{},\"blocks\":{},\"tables\":{},\"route_traces\":{},\"specialist_requests\":{},\"specialist_attempts\":{},\"specialist_responses\":{},\"specialist_results\":{},\"rag_chunks\":{},\"debug_assets\":{}}}",
        .{
            counts.spans,
            counts.blocks,
            counts.tables,
            counts.route_traces,
            counts.specialist_requests,
            counts.specialist_attempts,
            counts.specialist_responses,
            counts.specialist_results,
            counts.rag_chunks,
            counts.debug_assets,
        },
    );
}

fn specialistContext(options: RenderOptions) specialist_protocol.RenderContext {
    return .{
        .document_id = options.document_id,
        .source_id = options.source_id,
        .input_sha256 = options.input_sha256,
    };
}

fn writeRouteTotals(writer: anytype, routes: RouteTotals) !void {
    try writer.print(
        "{{\"native_pages\":{},\"page_routes\":{},\"region_routes\":{},\"ocr_regions\":{},\"table_regions\":{},\"formula_regions\":{}}}",
        .{
            routes.native_pages,
            routes.page_routes,
            routes.region_routes,
            routes.ocr_regions,
            routes.table_regions,
            routes.formula_regions,
        },
    );
}

fn writeDocumentId(writer: anytype, document_id: []const u8) !void {
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeByte('"');
}

fn writeSourceId(writer: anytype, source_id: ?[]const u8) !void {
    try writer.writeAll(",\"source_id\":");
    try writeOptionalString(writer, source_id);
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
    var clean_start: usize = 0;
    for (text, 0..) |byte, index| {
        if (!jsonNeedsEscape(byte)) continue;
        if (index > clean_start) try writer.writeAll(text[clean_start..index]);
        try writeJsonEscapedByte(writer, byte);
        clean_start = index + 1;
    }
    if (clean_start < text.len) try writer.writeAll(text[clean_start..]);
}

fn jsonNeedsEscape(byte: u8) bool {
    return byte < 0x20 or byte == '"' or byte == '\\';
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
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

fn sourceKindName(source: layout.SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native_pdf",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula_model",
        .manual => "manual",
        .poppler_text => "poppler_text",
    };
}

fn sourceMaskName(mask: u32) []const u8 {
    if (hasSource(mask, .manual)) return "manual";
    if (hasSource(mask, .poppler_text) and countSourceBits(mask) == 1) return "poppler_text";
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
        .footer => "footer",
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

fn traceBBox(result: anytype, record: anytype, offsets: RecordOffsets) ?layout.BBox {
    if (offsets.route_lookup) |lookup| {
        if (record.region_index) |region_index| {
            if (lookup.regionRange(record.page_index)) |range| {
                for (result.region_routes[range.start..range.end]) |route| {
                    if (route.region_index == region_index) return route.bbox;
                }
            }
        }
        if (lookup.pageRouteIndex(record.page_index)) |index| {
            return result.page_routes[index].bbox;
        }
    }

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
