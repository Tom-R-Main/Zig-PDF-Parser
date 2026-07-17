//! Public specialist request/response protocol for adaptive extraction.
//!
//! The Zig kernel remains deterministic: it emits explicit requests when a
//! page or region should be handled by an optional OCR/table/formula/layout
//! specialist. External tools can consume these JSONL records and return
//! provenance-bearing artifacts through the same public schema.

const std = @import("std");
const complexity = @import("complexity.zig");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");

pub const schema_version = "0.10.0";

pub const SpecialistKind = enum {
    ocr,
    table,
    formula,
    layout,
    entity,
};

pub const SpecialistStatus = enum {
    requested,
    not_invoked,
    completed,
    empty,
    failed,
    unavailable,
};

pub const SpecialistConfigEntry = struct {
    enabled: bool = false,
    executable: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    timeout_ms: u32 = 30_000,
};

pub const SpecialistConfig = struct {
    ocr: SpecialistConfigEntry = .{},
    table: SpecialistConfigEntry = .{},
    formula: SpecialistConfigEntry = .{},
    layout: SpecialistConfigEntry = .{},
    entity: SpecialistConfigEntry = .{},
};

pub const RenderContext = struct {
    document_id: []const u8 = "document",
    source_id: ?[]const u8 = null,
    input_sha256: ?[]const u8 = null,
};

pub const StreamMeta = struct {
    event_index: u64,
    page_index: u32,
};

pub const Counts = struct {
    requests: usize = 0,
    responses: usize = 0,
    results: usize = 0,
};

const IndexRange = struct {
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

const SpanPageLookup = struct {
    allocator: std.mem.Allocator,
    ranges: []IndexRange,

    fn init(allocator: std.mem.Allocator, result: anytype) !SpanPageLookup {
        const page_count = spanLookupPageCount(result);
        const ranges = try allocator.alloc(IndexRange, page_count);
        errdefer allocator.free(ranges);
        @memset(ranges, .{});

        for (result.reconciled.spans, 0..) |span, index| {
            const page_index = span.span.page_index;
            if (page_index < ranges.len) ranges[page_index].add(index);
        }

        return .{
            .allocator = allocator,
            .ranges = ranges,
        };
    }

    fn deinit(self: *SpanPageLookup) void {
        self.allocator.free(self.ranges);
        self.* = undefined;
    }

    fn spanRange(self: *const SpanPageLookup, page_index: u32) ?IndexRange {
        if (page_index >= self.ranges.len) return null;
        return self.ranges[page_index].slice();
    }
};

const BlockPageLookup = struct {
    allocator: std.mem.Allocator,
    ranges: []IndexRange,

    fn init(allocator: std.mem.Allocator, result: anytype) !BlockPageLookup {
        const page_count = blockLookupPageCount(result);
        const ranges = try allocator.alloc(IndexRange, page_count);
        errdefer allocator.free(ranges);
        @memset(ranges, .{});

        for (result.reconciled.blocks, 0..) |block, index| {
            const page_index = block.page_index;
            if (page_index < ranges.len) ranges[page_index].add(index);
        }

        return .{
            .allocator = allocator,
            .ranges = ranges,
        };
    }

    fn deinit(self: *BlockPageLookup) void {
        self.allocator.free(self.ranges);
        self.* = undefined;
    }

    fn blockRange(self: *const BlockPageLookup, page_index: u32) ?IndexRange {
        if (page_index >= self.ranges.len) return null;
        return self.ranges[page_index].slice();
    }
};

const SpanRange = struct {
    start: usize,
    end: usize,
};

fn spanLookupPageCount(result: anytype) usize {
    var page_count: usize = 0;
    for (result.reconciled.spans) |span| page_count = @max(page_count, @as(usize, @intCast(span.span.page_index)) + 1);
    return page_count;
}

fn blockLookupPageCount(result: anytype) usize {
    var page_count: usize = 0;
    for (result.reconciled.blocks) |block| page_count = @max(page_count, @as(usize, @intCast(block.page_index)) + 1);
    return page_count;
}

fn spanScanRange(result: anytype, page_index: u32, span_lookup: ?*const SpanPageLookup) SpanRange {
    if (span_lookup) |lookup| {
        if (lookup.spanRange(page_index)) |range| {
            return .{ .start = range.start, .end = range.end };
        }
        return .{ .start = 0, .end = 0 };
    }
    return .{ .start = 0, .end = result.reconciled.spans.len };
}

fn blockScanRange(result: anytype, page_index: u32, block_lookup: ?*const BlockPageLookup) SpanRange {
    if (block_lookup) |lookup| {
        if (lookup.blockRange(page_index)) |range| {
            return .{ .start = range.start, .end = range.end };
        }
        return .{ .start = 0, .end = 0 };
    }
    return .{ .start = 0, .end = result.reconciled.blocks.len };
}

pub fn countRequests(result: anytype) usize {
    var count: usize = 0;
    for (result.page_routes) |route| {
        if (routeNeedsKindOrReason(route.route, .ocr, route.reason_mask)) count += 1;
    }
    for (result.region_routes) |route| {
        count += requestKindCount(route.route, route.reason_mask);
    }
    for (result.trace_records) |record| {
        if (primaryRequestKind(record.route, record.reason_mask)) |kind| {
            if (requestAlreadyCovered(result, kind, record.page_index, record.region_index)) continue;
            count += 1;
        }
    }
    return count;
}

pub fn countResponses(result: anytype) usize {
    var count: usize = 0;
    for (result.page_routes) |route| {
        if (route.route.needs_ocr) count += 1;
    }
    return count;
}

pub fn countResults(result: anytype) usize {
    var count: usize = 0;
    for (result.page_routes) |route| {
        if (route.route.needs_ocr and countFreshOcrSpans(result, route.page_index, route.bbox, null) > 0) count += 1;
    }
    return count;
}

pub fn counts(result: anytype) Counts {
    return .{
        .requests = countRequests(result),
        .responses = countResponses(result),
        .results = countResults(result),
    };
}

pub fn writeRequestsArray(writer: anytype, result: anytype, context: RenderContext) !void {
    var wrote = false;
    try writeRequests(writer, result, context, null, false, null, &wrote, null, null);
}

pub fn writeResponsesArray(writer: anytype, result: anytype, context: RenderContext) !void {
    var wrote = false;
    try writeOcrResponses(writer, result, context, null, false, null, &wrote, null);
}

pub fn writeResultsArray(writer: anytype, result: anytype, context: RenderContext) !void {
    var wrote = false;
    try writeOcrResults(writer, result, context, null, false, null, &wrote, null);
}

pub fn writeArtifactJsonl(allocator: std.mem.Allocator, writer: anytype, result: anytype, context: RenderContext) !Counts {
    var span_lookup = try SpanPageLookup.init(allocator, result);
    defer span_lookup.deinit();
    var block_lookup = try BlockPageLookup.init(allocator, result);
    defer block_lookup.deinit();
    var wrote = false;
    try writeRequests(writer, result, context, null, true, null, &wrote, &span_lookup, &block_lookup);
    try writeOcrResponses(writer, result, context, null, true, null, &wrote, &span_lookup);
    try writeOcrResults(writer, result, context, null, true, null, &wrote, &span_lookup);
    if (wrote) try writer.writeByte('\n');
    return counts(result);
}

pub fn renderRequestsJsonl(allocator: std.mem.Allocator, result: anytype, context: RenderContext) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);
    var span_lookup = try SpanPageLookup.init(allocator, result);
    defer span_lookup.deinit();
    var block_lookup = try BlockPageLookup.init(allocator, result);
    defer block_lookup.deinit();
    var wrote = false;
    try writeRequests(writer, result, context, null, true, null, &wrote, &span_lookup, &block_lookup);
    if (wrote) try writer.writeByte('\n');
    return output.toOwnedSlice(allocator);
}

pub fn writePageRequestsJsonl(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_index: u32,
    event_index: *u64,
) !usize {
    const before = event_index.*;
    var wrote = false;
    try writeRequests(writer, result, context, page_index, true, event_index, &wrote, null, null);
    if (wrote) try writer.writeByte('\n');
    return @intCast(event_index.* - before);
}

pub fn writePageResponsesJsonl(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_index: u32,
    event_index: *u64,
) !usize {
    const before = event_index.*;
    var wrote = false;
    try writeOcrResponses(writer, result, context, page_index, true, event_index, &wrote, null);
    if (wrote) try writer.writeByte('\n');
    return @intCast(event_index.* - before);
}

pub fn writePageResultsJsonl(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_index: u32,
    event_index: *u64,
) !usize {
    const before = event_index.*;
    var wrote = false;
    try writeOcrResults(writer, result, context, page_index, true, event_index, &wrote, null);
    if (wrote) try writer.writeByte('\n');
    return @intCast(event_index.* - before);
}

pub fn writeRouteTraceSpecialistFields(writer: anytype, route: anytype, page_index: u32, region_index: ?u32) !void {
    try writeRouteTraceSpecialistFieldsWithReason(writer, route, 0, page_index, region_index);
}

pub fn writeRouteTraceSpecialistFieldsWithReason(writer: anytype, route: anytype, reason_mask: u32, page_index: u32, region_index: ?u32) !void {
    try writer.writeAll(",\"specialist_request_ids\":[");
    var first = true;
    if (routeNeedsKindOrReason(route, .ocr, reason_mask)) {
        try writeRequestIdValue(writer, .ocr, page_index, region_index, &first);
    }
    if (routeNeedsKindOrReason(route, .table, reason_mask)) {
        try writeRequestIdValue(writer, .table, page_index, region_index, &first);
    }
    if (routeNeedsKindOrReason(route, .formula, reason_mask)) {
        try writeRequestIdValue(writer, .formula, page_index, region_index, &first);
    }
    if (routeNeedsKindOrReason(route, .layout, reason_mask)) {
        try writeRequestIdValue(writer, .layout, page_index, region_index, &first);
    }
    try writer.writeAll("],\"specialist_status\":\"");
    try writer.writeAll(if (first) "none" else "requested");
    try writer.writeByte('"');
}

pub fn writeEntityRequestForBlock(
    writer: anytype,
    context: RenderContext,
    block: anytype,
    request_index: u32,
) !void {
    try writeRecordHeader(writer, "specialist_request");
    try writeDocumentFields(writer, context);
    try writer.print(",\"request_id\":\"specialist-request-entity-block-{d}\",\"request_index\":{}", .{ block.id, request_index });
    try writer.print(",\"page_index\":{},\"region_index\":null,\"bbox\":", .{block.page_index});
    try writeBBoxJson(writer, block.bbox);
    try writer.writeAll(",\"route\":\"entity_extract\",\"route_reasons\":[],\"signals\":null,\"requested_kind\":\"entity\",\"requested_outputs\":[\"entity\"]");
    try writer.writeAll(",\"span_ids\":[],\"spans\":[],\"block_ids\":[");
    try writer.print("\"block-{d}\"", .{block.id});
    try writer.writeAll("],\"blocks\":[");
    try writeBlockContext(writer, block, block.id);
    try writer.writeAll("],\"ruling_lines\":[],\"crop_image_path\":null,\"debug_asset_ids\":[]");
    try writeProvenance(writer, context, "specialist-request-entity", block.page_index, block.bbox, "lifecycle", 1.0);
    try writer.writeByte('}');
}

fn writeRequests(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_filter: ?u32,
    jsonl: bool,
    event_index: ?*u64,
    wrote: *bool,
    span_lookup: ?*const SpanPageLookup,
    block_lookup: ?*const BlockPageLookup,
) !void {
    var request_index: u32 = 0;
    for (result.page_routes) |route| {
        if (!matchesPage(page_filter, route.page_index)) continue;
        if (!routeNeedsKindOrReason(route.route, .ocr, route.reason_mask)) continue;
        try writeRecordSeparator(writer, jsonl, wrote);
        try writeRequestRecord(writer, result, context, .ocr, request_index, route.page_index, null, route.bbox, route.route, route.reason_mask, route.signals, event_index, span_lookup, block_lookup);
        request_index += 1;
    }
    for (result.region_routes) |route| {
        if (!matchesPage(page_filter, route.page_index)) continue;
        if (primaryRegionKind(route.route, route.reason_mask)) |kind| {
            try writeRecordSeparator(writer, jsonl, wrote);
            try writeRequestRecord(writer, result, context, kind, request_index, route.page_index, route.region_index, route.bbox, route.route, route.reason_mask, route.signals, event_index, span_lookup, block_lookup);
            request_index += 1;
        }
    }
    for (result.trace_records) |record| {
        if (!matchesPage(page_filter, record.page_index)) continue;
        if (primaryRequestKind(record.route, record.reason_mask)) |kind| {
            if (requestAlreadyCovered(result, kind, record.page_index, record.region_index)) continue;
            const bbox = traceBBox(result, record) orelse layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
            try writeRecordSeparator(writer, jsonl, wrote);
            try writeRequestRecord(writer, result, context, kind, request_index, record.page_index, record.region_index, bbox, record.route, record.reason_mask, zeroSignals(), event_index, span_lookup, block_lookup);
            request_index += 1;
        }
    }
}

fn writeOcrResponses(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_filter: ?u32,
    jsonl: bool,
    event_index: ?*u64,
    wrote: *bool,
    span_lookup: ?*const SpanPageLookup,
) !void {
    for (result.page_routes, 0..) |route, index| {
        if (!matchesPage(page_filter, route.page_index) or !route.route.needs_ocr) continue;
        try writeRecordSeparator(writer, jsonl, wrote);
        try writeOcrResponseRecord(writer, result, context, @intCast(index), route, event_index, span_lookup);
    }
}

fn writeOcrResults(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    page_filter: ?u32,
    jsonl: bool,
    event_index: ?*u64,
    wrote: *bool,
    span_lookup: ?*const SpanPageLookup,
) !void {
    for (result.page_routes, 0..) |route, index| {
        if (!matchesPage(page_filter, route.page_index) or !route.route.needs_ocr) continue;
        if (countFreshOcrSpans(result, route.page_index, route.bbox, span_lookup) == 0) continue;
        try writeRecordSeparator(writer, jsonl, wrote);
        try writeOcrResultRecord(writer, result, context, @intCast(index), route, event_index, span_lookup);
    }
}

fn writeRequestRecord(
    writer: anytype,
    result: anytype,
    context: RenderContext,
    kind: SpecialistKind,
    request_index: u32,
    page_index: u32,
    region_index: ?u32,
    bbox: layout.BBox,
    route: complexity.RouteDecision,
    reason_mask: u32,
    signals: complexity.SignalScores,
    event_index: ?*u64,
    span_lookup: ?*const SpanPageLookup,
    block_lookup: ?*const BlockPageLookup,
) !void {
    try writeRecordHeader(writer, "specialist_request");
    if (event_index) |index| {
        try writeStreamFields(writer, "specialist_request", index.*, page_index);
        index.* += 1;
    }
    try writeDocumentFields(writer, context);
    try writer.writeAll(",\"request_id\":");
    try writeRequestId(writer, kind, page_index, region_index);
    try writer.print(",\"request_index\":{},\"page_index\":{},\"region_index\":", .{ request_index, page_index });
    try writeOptionalU32(writer, region_index);
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, bbox);
    try writer.writeAll(",\"route\":\"");
    try writeJsonEscaped(writer, routeName(route, kind));
    try writer.writeAll("\",\"route_reasons\":");
    try writeReasonArray(writer, reason_mask);
    try writer.writeAll(",\"signals\":");
    try writeSignalsJson(writer, signals);
    try writer.writeAll(",\"requested_kind\":\"");
    try writer.writeAll(@tagName(kind));
    try writer.writeAll("\",\"requested_outputs\":");
    try writeRequestedOutputs(writer, kind);
    try writer.writeAll(",\"span_ids\":");
    try writeSpanIdArray(writer, result, page_index, bbox, .all, span_lookup);
    try writer.writeAll(",\"spans\":");
    try writeSpanContextArray(writer, result, page_index, bbox, .all, span_lookup);
    try writer.writeAll(",\"block_ids\":");
    try writeBlockIdArray(writer, result, page_index, bbox, block_lookup);
    try writer.writeAll(",\"blocks\":");
    try writeBlockContextArray(writer, result, page_index, bbox, block_lookup);
    try writer.writeAll(",\"ruling_lines\":[],\"crop_image_path\":null,\"debug_asset_ids\":");
    try writeDebugAssetIds(writer, page_index);
    try writeProvenance(writer, context, "specialist-request", page_index, bbox, "lifecycle", routeConfidence(route));
    try writer.writeByte('}');
}

fn writeOcrResponseRecord(writer: anytype, result: anytype, context: RenderContext, response_index: u32, route: anytype, event_index: ?*u64, span_lookup: ?*const SpanPageLookup) !void {
    const fresh_count = countFreshOcrSpans(result, route.page_index, route.bbox, span_lookup);
    const status = if (fresh_count > 0) "completed" else "empty";
    const confidence = averageFreshOcrConfidence(result, route.page_index, route.bbox, span_lookup);
    try writeRecordHeader(writer, "specialist_response");
    if (event_index) |index| {
        try writeStreamFields(writer, "specialist_response", index.*, route.page_index);
        index.* += 1;
    }
    try writeDocumentFields(writer, context);
    try writer.print(",\"page_index\":{}", .{route.page_index});
    try writer.writeAll(",\"response_id\":\"specialist-response-ocr-");
    try writer.print("{d}\",\"request_id\":", .{response_index});
    try writeRequestId(writer, .ocr, route.page_index, null);
    try writer.writeAll(",\"specialist_id\":\"tesseract\",\"specialist_kind\":\"ocr\",\"status\":\"");
    try writer.writeAll(status);
    try writer.print("\",\"confidence\":{d:.3},\"spans\":", .{confidence});
    try writeSpanContextArray(writer, result, route.page_index, route.bbox, .fresh_ocr, span_lookup);
    try writer.writeAll(",\"tables\":[],\"blocks\":[],\"formulas\":[],\"entities\":[],\"debug_assets\":[],\"warnings\":[],\"errors\":[]");
    try writeProvenance(writer, context, "specialist-response-ocr", route.page_index, route.bbox, "fresh_ocr", confidence);
    try writer.writeByte('}');
}

fn writeOcrResultRecord(writer: anytype, result: anytype, context: RenderContext, result_index: u32, route: anytype, event_index: ?*u64, span_lookup: ?*const SpanPageLookup) !void {
    const confidence = averageFreshOcrConfidence(result, route.page_index, route.bbox, span_lookup);
    try writeRecordHeader(writer, "specialist_result");
    if (event_index) |index| {
        try writeStreamFields(writer, "specialist_result", index.*, route.page_index);
        index.* += 1;
    }
    try writeDocumentFields(writer, context);
    try writer.print(",\"page_index\":{},\"specialist_result_id\":\"specialist-result-ocr-{d}\",\"request_id\":", .{ route.page_index, result_index });
    try writeRequestId(writer, .ocr, route.page_index, null);
    try writer.writeAll(",\"specialist_id\":\"tesseract\",\"specialist_kind\":\"ocr\",\"status\":\"completed\",\"source_kind\":\"fresh_ocr\"");
    try writer.print(",\"confidence\":{d:.3},\"artifact_counts\":{{\"spans\":{},\"tables\":0,\"blocks\":0,\"formulas\":0,\"entities\":0}}", .{ confidence, countFreshOcrSpans(result, route.page_index, route.bbox, span_lookup) });
    try writer.writeAll(",\"span_ids\":");
    try writeSpanIdArray(writer, result, route.page_index, route.bbox, .fresh_ocr, span_lookup);
    try writer.writeAll(",\"table_ids\":[],\"block_ids\":[],\"formula_ids\":[],\"entity_ids\":[]");
    try writeProvenance(writer, context, "specialist-result-ocr", route.page_index, route.bbox, "fresh_ocr", confidence);
    try writer.writeByte('}');
}

fn requestKindCount(route: complexity.RouteDecision, reason_mask: u32) usize {
    return if (primaryRegionKind(route, reason_mask) == null) 0 else 1;
}

fn primaryRequestKind(route: complexity.RouteDecision, reason_mask: u32) ?SpecialistKind {
    if (routeNeedsKindOrReason(route, .ocr, reason_mask)) return .ocr;
    return primaryRegionKind(route, reason_mask);
}

fn primaryRegionKind(route: complexity.RouteDecision, reason_mask: u32) ?SpecialistKind {
    if (routeNeedsKindOrReason(route, .table, reason_mask)) return .table;
    if (routeNeedsKindOrReason(route, .formula, reason_mask)) return .formula;
    if (routeNeedsKindOrReason(route, .layout, reason_mask)) return .layout;
    return null;
}

fn routeNeedsKind(route: complexity.RouteDecision, kind: SpecialistKind) bool {
    return switch (kind) {
        .ocr => route.needs_ocr,
        .table => route.needs_table_model,
        .formula => route.needs_formula_model,
        .layout => route.needs_layout_model,
        .entity => false,
    };
}

fn routeNeedsKindOrReason(route: complexity.RouteDecision, kind: SpecialistKind, reason_mask: u32) bool {
    if (routeNeedsKind(route, kind)) return true;
    return switch (kind) {
        .ocr => hasReason(reason_mask, 9) or hasReason(reason_mask, 2),
        .table => hasReason(reason_mask, 11) or hasReason(reason_mask, 7),
        .formula => hasReason(reason_mask, 12) or hasReason(reason_mask, 8),
        .layout => hasReason(reason_mask, 10) or hasReason(reason_mask, 6),
        .entity => false,
    };
}

fn hasReason(mask: u32, bit: u5) bool {
    return (mask & (@as(u32, 1) << bit)) != 0;
}

fn requestAlreadyCovered(result: anytype, kind: SpecialistKind, page_index: u32, region_index: ?u32) bool {
    if (region_index) |region| {
        const route_index: usize = @intCast(region);
        if (route_index < result.region_routes.len) {
            const route = result.region_routes[route_index];
            if (route.page_index == page_index and route.region_index == region) {
                return routeNeedsKindOrReason(route.route, kind, route.reason_mask);
            }
        }
        for (result.region_routes) |route| {
            if (route.page_index == page_index and route.region_index == region and routeNeedsKindOrReason(route.route, kind, route.reason_mask)) return true;
        }
        return false;
    }
    const route_index: usize = @intCast(page_index);
    if (route_index < result.page_routes.len) {
        const route = result.page_routes[route_index];
        if (route.page_index == page_index) {
            return routeNeedsKindOrReason(route.route, kind, route.reason_mask);
        }
    }
    for (result.page_routes) |route| {
        if (route.page_index == page_index and routeNeedsKindOrReason(route.route, kind, route.reason_mask)) return true;
    }
    return false;
}

fn traceBBox(result: anytype, record: anytype) ?layout.BBox {
    if (record.region_index) |region| {
        const route_index: usize = @intCast(region);
        if (route_index < result.region_routes.len) {
            const route = result.region_routes[route_index];
            if (route.page_index == record.page_index and route.region_index == region) return route.bbox;
        }
        for (result.region_routes) |route| {
            if (route.page_index == record.page_index and route.region_index == region) return route.bbox;
        }
    }
    const route_index: usize = @intCast(record.page_index);
    if (route_index < result.page_routes.len) {
        const route = result.page_routes[route_index];
        if (route.page_index == record.page_index) return route.bbox;
    }
    for (result.page_routes) |route| {
        if (route.page_index == record.page_index) return route.bbox;
    }
    return null;
}

fn zeroSignals() complexity.SignalScores {
    return .{};
}

fn writeRecordSeparator(writer: anytype, jsonl: bool, wrote: *bool) !void {
    if (wrote.*) {
        if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
    }
    wrote.* = true;
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

fn writeStreamFields(writer: anytype, event_type: []const u8, event_index: u64, page_index: u32) !void {
    _ = page_index;
    try writer.writeAll(",\"event_type\":\"");
    try writer.writeAll(event_type);
    try writer.print("\",\"event_index\":{},\"sequence_scope\":\"page\"", .{event_index});
}

fn writeDocumentFields(writer: anytype, context: RenderContext) !void {
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, context.document_id);
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, context.source_id);
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, context.input_sha256);
}

fn writeRequestId(writer: anytype, kind: SpecialistKind, page_index: u32, region_index: ?u32) !void {
    try writer.writeByte('"');
    if (region_index) |region| {
        try writer.print("specialist-request-{s}-region-{d}", .{ @tagName(kind), region });
    } else {
        try writer.print("specialist-request-{s}-page-{d}", .{ @tagName(kind), page_index });
    }
    try writer.writeByte('"');
}

fn writeRequestIdValue(writer: anytype, kind: SpecialistKind, page_index: u32, region_index: ?u32, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    try writeRequestId(writer, kind, page_index, region_index);
    first.* = false;
}

fn writeRequestedOutputs(writer: anytype, kind: SpecialistKind) !void {
    const outputs: []const []const u8 = switch (kind) {
        .ocr => &.{ "span", "hocr" },
        .table => &.{ "table", "span" },
        .formula => &.{ "formula", "span" },
        .layout => &.{ "block", "span" },
        .entity => &.{"entity"},
    };
    try writer.writeByte('[');
    for (outputs, 0..) |output, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writer.writeAll(output);
        try writer.writeByte('"');
    }
    try writer.writeByte(']');
}

const SpanFilter = enum { all, fresh_ocr };

fn writeSpanIdArray(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, filter: SpanFilter, span_lookup: ?*const SpanPageLookup) !void {
    try writer.writeByte('[');
    var first = true;
    const range = spanScanRange(result, page_index, span_lookup);
    for (result.reconciled.spans[range.start..range.end], range.start..) |span, index| {
        if (!includeSpan(span, page_index, bbox, filter)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("\"span-{d}\"", .{index});
        first = false;
    }
    try writer.writeByte(']');
}

fn writeSpanContextArray(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, filter: SpanFilter, span_lookup: ?*const SpanPageLookup) !void {
    try writer.writeByte('[');
    var first = true;
    const range = spanScanRange(result, page_index, span_lookup);
    for (result.reconciled.spans[range.start..range.end], range.start..) |span, index| {
        if (!includeSpan(span, page_index, bbox, filter)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("{{\"span_id\":\"span-{d}\",\"text\":\"", .{index});
        try writeJsonEscaped(writer, span.span.text);
        try writer.writeAll("\",\"bbox\":");
        try writeBBoxJson(writer, span.span.bbox);
        try writer.writeAll(",\"source_kind\":\"");
        try writer.writeAll(sourceKindName(span.chosen_source));
        try writer.print("\",\"confidence\":{d:.3}}}", .{span.confidence});
        first = false;
    }
    try writer.writeByte(']');
}

fn writeBlockIdArray(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, block_lookup: ?*const BlockPageLookup) !void {
    try writer.writeByte('[');
    var first = true;
    const range = blockScanRange(result, page_index, block_lookup);
    for (result.reconciled.blocks[range.start..range.end]) |block| {
        if (block.page_index != page_index or !boxesIntersect(block.bbox, bbox)) continue;
        if (!first) try writer.writeByte(',');
        try writer.print("\"block-{d}\"", .{block.id});
        first = false;
    }
    try writer.writeByte(']');
}

fn writeBlockContextArray(writer: anytype, result: anytype, page_index: u32, bbox: layout.BBox, block_lookup: ?*const BlockPageLookup) !void {
    try writer.writeByte('[');
    var first = true;
    const range = blockScanRange(result, page_index, block_lookup);
    for (result.reconciled.blocks[range.start..range.end]) |block| {
        if (block.page_index != page_index or !boxesIntersect(block.bbox, bbox)) continue;
        if (!first) try writer.writeByte(',');
        try writeBlockContext(writer, block, block.id);
        first = false;
    }
    try writer.writeByte(']');
}

fn writeBlockContext(writer: anytype, block: anytype, block_id: u32) !void {
    try writer.print("{{\"block_id\":\"block-{d}\",\"kind\":\"{s}\",\"text\":\"", .{ block_id, @tagName(block.kind) });
    try writeJsonEscaped(writer, block.text);
    try writer.writeAll("\",\"bbox\":");
    try writeBBoxJson(writer, block.bbox);
    try writer.print(",\"confidence\":{d:.3}}}", .{block.confidence});
}

fn writeDebugAssetIds(writer: anytype, page_index: u32) !void {
    const ids = [_][]const u8{
        "page_overlay_svg",
        "low_confidence_overlay_svg",
        "table_grid_overlay_svg",
        "ocr_route_overlay_svg",
        "span_block_id_overlay_svg",
    };
    try writer.writeByte('[');
    for (ids, 0..) |id, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"page-{d}-{s}\"", .{ page_index, id });
    }
    try writer.writeByte(']');
}

fn writeProvenance(writer: anytype, context: RenderContext, artifact_id: []const u8, page_index: ?u32, bbox: ?layout.BBox, source_kind: []const u8, confidence: f32) !void {
    try writer.writeAll(",\"provenance\":{\"document_id\":\"");
    try writeJsonEscaped(writer, context.document_id);
    try writer.writeAll("\",\"source_id\":");
    try writeOptionalString(writer, context.source_id);
    try writer.writeAll(",\"input_sha256\":");
    try writeOptionalString(writer, context.input_sha256);
    try writer.writeAll(",\"artifact_id\":\"");
    try writeJsonEscaped(writer, artifact_id);
    try writer.writeAll("\",\"page_index\":");
    try writeOptionalU32(writer, page_index);
    try writer.writeAll(",\"bbox\":");
    if (bbox) |box| try writeBBoxJson(writer, box) else try writer.writeAll("null");
    try writer.writeAll(",\"source_kind\":\"");
    try writer.writeAll(source_kind);
    try writer.print("\",\"confidence\":{d:.3},\"span_ids\":[],\"block_ids\":[],\"chunk_ids\":[],\"route_trace_ids\":[],\"route_reasons\":[]}}", .{confidence});
}

fn includeSpan(span: anytype, page_index: u32, bbox: layout.BBox, filter: SpanFilter) bool {
    if (span.span.page_index != page_index or !boxesIntersect(span.span.bbox, bbox)) return false;
    return switch (filter) {
        .all => true,
        .fresh_ocr => span.chosen_source == .fresh_ocr or span.span.source == .fresh_ocr,
    };
}

fn countFreshOcrSpans(result: anytype, page_index: u32, bbox: layout.BBox, span_lookup: ?*const SpanPageLookup) usize {
    var count: usize = 0;
    const range = spanScanRange(result, page_index, span_lookup);
    for (result.reconciled.spans[range.start..range.end]) |span| {
        if (includeSpan(span, page_index, bbox, .fresh_ocr)) count += 1;
    }
    return count;
}

fn averageFreshOcrConfidence(result: anytype, page_index: u32, bbox: layout.BBox, span_lookup: ?*const SpanPageLookup) f32 {
    var sum: f32 = 0;
    var count: usize = 0;
    const range = spanScanRange(result, page_index, span_lookup);
    for (result.reconciled.spans[range.start..range.end]) |span| {
        if (!includeSpan(span, page_index, bbox, .fresh_ocr)) continue;
        sum += span.confidence;
        count += 1;
    }
    if (count == 0) return 0.0;
    return sum / @as(f32, @floatFromInt(count));
}

fn matchesPage(page_filter: ?u32, page_index: u32) bool {
    return if (page_filter) |wanted| wanted == page_index else true;
}

fn routeName(route: complexity.RouteDecision, kind: SpecialistKind) []const u8 {
    _ = kind;
    if (route.native_fast_path) return "use_native";
    if (route.needs_ocr) return "queue_ocr";
    if (route.needs_table_model and route.needs_formula_model) return "candidate_table_formula";
    if (route.needs_table_model) return "candidate_table";
    if (route.needs_formula_model) return "candidate_formula";
    if (route.needs_layout_model) return "candidate_layout";
    return "review";
}

fn routeConfidence(route: complexity.RouteDecision) f32 {
    const signal = @max(0.0, @min(1.0, route.max_signal));
    if (route.native_fast_path) return 1.0 - signal;
    return signal;
}

fn sourceKindName(source: layout.SourceKind) []const u8 {
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

fn writeSignalsJson(writer: anytype, signals: complexity.SignalScores) !void {
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

fn writeBBoxJson(writer: anytype, box: layout.BBox) !void {
    try writer.print("{{\"x0\":{d:.3},\"y0\":{d:.3},\"x1\":{d:.3},\"y1\":{d:.3}}}", .{ box.x0, box.y0, box.x1, box.y1 });
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
    if (value) |number| try writer.print("{}", .{number}) else try writer.writeAll("null");
}

fn boxesIntersect(a: layout.BBox, b: layout.BBox) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
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

test "specialist route metadata records stable ids" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const writer = runtime.arrayListWriter(&output, std.testing.allocator);
    try writeRouteTraceSpecialistFields(writer, complexity.RouteDecision{
        .needs_table_model = true,
        .needs_formula_model = true,
    }, 2, 7);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "specialist-request-table-region-7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "specialist-request-formula-region-7") != null);
}

test "entity request writer exposes entity protocol shape" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const writer = runtime.arrayListWriter(&output, std.testing.allocator);
    try writeEntityRequestForBlock(writer, .{ .document_id = "doc", .source_id = "source", .input_sha256 = "hash" }, .{
        .id = 4,
        .page_index = 1,
        .bbox = layout.BBox{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
        .kind = .paragraph,
        .text = "Acme Corp",
        .span_start = 0,
        .span_count = 1,
        .source_mask = 1,
        .confidence = 0.9,
    }, 0);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"requested_kind\":\"entity\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"record_type\":\"specialist_request\"") != null);
}

test "region routing consolidates table formula and layout to one request" {
    const route = complexity.RouteDecision{
        .needs_table_model = true,
        .needs_formula_model = true,
        .needs_layout_model = true,
    };
    try std.testing.expectEqual(@as(usize, 1), requestKindCount(route, 0));
    try std.testing.expectEqual(SpecialistKind.table, primaryRegionKind(route, 0).?);
}

test "page specialist request writer scopes requests and spans to page" {
    const PageRoute = struct {
        page_index: u32,
        bbox: layout.BBox,
        route: complexity.RouteDecision,
        reason_mask: u32 = 0,
        signals: complexity.SignalScores = .{},
    };
    const RegionRoute = struct {
        page_index: u32,
        region_index: u32,
        bbox: layout.BBox,
        route: complexity.RouteDecision,
        reason_mask: u32 = 0,
        signals: complexity.SignalScores = .{},
    };
    const TraceRecord = struct {
        page_index: u32,
        region_index: ?u32 = null,
        route: complexity.RouteDecision,
        reason_mask: u32 = 0,
    };
    const SpanRecord = struct {
        span: layout.TextSpan,
        source_mask: u32 = 1,
        source_count: u8 = 1,
        duplicate_count: u32 = 0,
        chosen_source: layout.SourceKind = .native_pdf,
        confidence: f32 = 1.0,
    };
    const BlockRecord = struct {
        id: u32,
        page_index: u32,
        bbox: layout.BBox,
        kind: layout.BlockKind,
        text: []const u8,
        span_start: u32,
        span_count: u32,
        source_mask: u32,
        confidence: f32,
    };
    const Reconciled = struct {
        spans: []const SpanRecord,
        blocks: []const BlockRecord,
    };
    const Result = struct {
        page_routes: []const PageRoute,
        region_routes: []const RegionRoute,
        trace_records: []const TraceRecord,
        reconciled: Reconciled,
    };

    const page_bbox = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const routes = [_]PageRoute{
        .{
            .page_index = 0,
            .bbox = page_bbox,
            .route = .{ .needs_ocr = true },
        },
        .{
            .page_index = 1,
            .bbox = page_bbox,
            .route = .{ .needs_ocr = true },
        },
    };
    const spans = [_]SpanRecord{
        .{
            .span = layout.TextSpan.init(.{
                .page_index = 0,
                .bbox = layout.BBox{ .x0 = 1, .y0 = 1, .x1 = 10, .y1 = 10 },
                .text = "wrong page",
            }),
        },
        .{
            .span = layout.TextSpan.init(.{
                .page_index = 1,
                .bbox = layout.BBox{ .x0 = 1, .y0 = 1, .x1 = 10, .y1 = 10 },
                .text = "right page",
            }),
        },
    };
    const blocks = [_]BlockRecord{
        .{
            .id = 10,
            .page_index = 0,
            .bbox = layout.BBox{ .x0 = 1, .y0 = 1, .x1 = 10, .y1 = 10 },
            .kind = .paragraph,
            .text = "wrong block",
            .span_start = 0,
            .span_count = 1,
            .source_mask = 1,
            .confidence = 1.0,
        },
        .{
            .id = 11,
            .page_index = 1,
            .bbox = layout.BBox{ .x0 = 1, .y0 = 1, .x1 = 10, .y1 = 10 },
            .kind = .paragraph,
            .text = "right block",
            .span_start = 1,
            .span_count = 1,
            .source_mask = 1,
            .confidence = 1.0,
        },
    };
    const result = Result{
        .page_routes = &routes,
        .region_routes = &.{},
        .trace_records = &.{},
        .reconciled = .{
            .spans = &spans,
            .blocks = &blocks,
        },
    };

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const writer = runtime.arrayListWriter(&output, std.testing.allocator);
    var event_index: u64 = 0;

    const written = try writePageRequestsJsonl(writer, &result, .{ .document_id = "doc" }, 1, &event_index);
    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "specialist-request-ocr-page-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "specialist-request-ocr-page-0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"span_id\":\"span-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"span_id\":\"span-0\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"block_id\":\"block-11\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"block_id\":\"block-10\"") == null);
}
