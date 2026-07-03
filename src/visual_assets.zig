//! Visual review asset renderers and sidecar materialization.
//!
//! The schema module owns JSON shapes. This module owns debug asset payloads:
//! SVG overlays plus coordinate/trace sidecars that host applications can
//! persist as review evidence.

const std = @import("std");
const layout = @import("layout.zig");
const reconcile = @import("reconcile.zig");
const runtime = @import("runtime.zig");

pub const AssetKind = enum {
    page_overlay_svg,
    low_confidence_overlay_svg,
    table_grid_overlay_svg,
    ocr_route_overlay_svg,
    span_block_id_overlay_svg,
    hocr,
    alto,
    route_trace_json,
    glyph_trace_jsonl,
};

pub const AssetRecord = struct {
    debug_asset_id: []const u8,
    asset_kind: []const u8,
    kind: []const u8,
    media_type: []const u8,
    output_format: []const u8,
    uri: ?[]const u8 = null,
    path: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    byte_length: ?usize = null,
    page_index: ?u32 = null,
    region_index: ?u32 = null,
    layers: []const []const u8 = &.{},
    stage: []const u8 = "output_ready",

    pub fn deinit(self: AssetRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.debug_asset_id);
        if (self.path) |path| allocator.free(path);
        if (self.sha256) |hash| allocator.free(hash);
    }
};

const PageAssetSpec = struct {
    asset_kind: AssetKind,
    suffix: []const u8,
    layers: []const []const u8,
};

const page_asset_specs = [_]PageAssetSpec{
    .{ .asset_kind = .page_overlay_svg, .suffix = "page-overlay.svg", .layers = &.{ "page-overlay", "native-spans", "layout-blocks", "route-regions" } },
    .{ .asset_kind = .low_confidence_overlay_svg, .suffix = "low-confidence.svg", .layers = &.{ "low-confidence-regions", "low-confidence-spans", "low-confidence-blocks" } },
    .{ .asset_kind = .table_grid_overlay_svg, .suffix = "table-grid.svg", .layers = &.{ "table-grid", "table-grid-cells", "table-grid-labels" } },
    .{ .asset_kind = .ocr_route_overlay_svg, .suffix = "ocr-routes.svg", .layers = &.{ "ocr-route-overlay", "ocr-route-regions", "ocr-route-traces" } },
    .{ .asset_kind = .span_block_id_overlay_svg, .suffix = "span-block-ids.svg", .layers = &.{ "span-block-id-overlay", "span-id-labels", "block-id-labels" } },
    .{ .asset_kind = .glyph_trace_jsonl, .suffix = "glyph-trace.jsonl", .layers = &.{"glyph-trace"} },
};

const DocumentAssetSpec = struct {
    id: []const u8,
    asset_kind: AssetKind,
    kind: []const u8,
    media_type: []const u8,
    output_format: []const u8,
    filename: []const u8,
    layers: []const []const u8,
};

const document_asset_specs = [_]DocumentAssetSpec{
    .{ .id = "debug-svg", .asset_kind = .page_overlay_svg, .kind = "debug_overlay", .media_type = "image/svg+xml", .output_format = "debug-svg", .filename = "document.debug.svg", .layers = &.{ "page-overlay", "native-spans", "layout-blocks", "route-regions" } },
    .{ .id = "route-trace", .asset_kind = .route_trace_json, .kind = "route_trace", .media_type = "application/json", .output_format = "trace-json", .filename = "document.route-trace.json", .layers = &.{} },
    .{ .id = "hocr", .asset_kind = .hocr, .kind = "coordinate_text", .media_type = "text/html", .output_format = "hocr", .filename = "document.hocr.html", .layers = &.{"hocr"} },
    .{ .id = "alto", .asset_kind = .alto, .kind = "coordinate_text", .media_type = "application/xml", .output_format = "alto", .filename = "document.alto.xml", .layers = &.{"alto"} },
};

pub fn assetCount(result: anytype, include_debug_asset_refs: bool) usize {
    if (!include_debug_asset_refs) return 0;
    return document_asset_specs.len + pageCount(result) * page_asset_specs.len;
}

pub fn collectBatch(
    allocator: std.mem.Allocator,
    result: anytype,
    debug_assets_dir: ?[]const u8,
    include_debug_asset_refs: bool,
) ![]AssetRecord {
    if (!include_debug_asset_refs) return &.{};
    var records: std.ArrayList(AssetRecord) = .empty;
    errdefer deinitRecords(allocator, records.items);

    for (document_asset_specs) |spec| {
        var record = try documentRecord(allocator, spec);
        errdefer record.deinit(allocator);
        if (debug_assets_dir) |dir| try materializeDocumentAsset(allocator, result, dir, spec, &record);
        try records.append(allocator, record);
    }

    for (0..pageCount(result)) |page_usize| {
        const page_index: u32 = @intCast(page_usize);
        for (page_asset_specs) |spec| {
            var record = try pageRecord(allocator, page_index, spec);
            errdefer record.deinit(allocator);
            if (debug_assets_dir) |dir| try materializePageAsset(allocator, result, dir, page_index, spec, &record);
            try records.append(allocator, record);
        }
    }

    return records.toOwnedSlice(allocator);
}

pub fn collectPageMaterialized(
    allocator: std.mem.Allocator,
    result: anytype,
    debug_assets_dir: ?[]const u8,
    page_index: u32,
) ![]AssetRecord {
    const dir = debug_assets_dir orelse return &.{};
    var records: std.ArrayList(AssetRecord) = .empty;
    errdefer deinitRecords(allocator, records.items);

    for (page_asset_specs) |spec| {
        var record = try pageRecord(allocator, page_index, spec);
        errdefer record.deinit(allocator);
        try materializePageAsset(allocator, result, dir, page_index, spec, &record);
        try records.append(allocator, record);
    }

    return records.toOwnedSlice(allocator);
}

pub fn collectDocumentRefs(
    allocator: std.mem.Allocator,
    debug_assets_dir: ?[]const u8,
) ![]AssetRecord {
    _ = debug_assets_dir;
    var records: std.ArrayList(AssetRecord) = .empty;
    errdefer deinitRecords(allocator, records.items);
    for (document_asset_specs) |spec| {
        var record = try documentRecord(allocator, spec);
        errdefer record.deinit(allocator);
        try records.append(allocator, record);
    }
    return records.toOwnedSlice(allocator);
}

pub fn deinitRecords(allocator: std.mem.Allocator, records: []const AssetRecord) void {
    if (records.len == 0) return;
    for (records) |record| record.deinit(allocator);
    allocator.free(records);
}

pub fn assetKindName(kind: AssetKind) []const u8 {
    return switch (kind) {
        .page_overlay_svg => "page_overlay_svg",
        .low_confidence_overlay_svg => "low_confidence_overlay_svg",
        .table_grid_overlay_svg => "table_grid_overlay_svg",
        .ocr_route_overlay_svg => "ocr_route_overlay_svg",
        .span_block_id_overlay_svg => "span_block_id_overlay_svg",
        .hocr => "hocr",
        .alto => "alto",
        .route_trace_json => "route_trace_json",
        .glyph_trace_jsonl => "glyph_trace_jsonl",
    };
}

fn documentRecord(allocator: std.mem.Allocator, spec: DocumentAssetSpec) !AssetRecord {
    return .{
        .debug_asset_id = try allocator.dupe(u8, spec.id),
        .asset_kind = assetKindName(spec.asset_kind),
        .kind = spec.kind,
        .media_type = spec.media_type,
        .output_format = spec.output_format,
        .layers = spec.layers,
    };
}

fn pageRecord(allocator: std.mem.Allocator, page_index: u32, spec: PageAssetSpec) !AssetRecord {
    return .{
        .debug_asset_id = try std.fmt.allocPrint(allocator, "page-{d}-{s}", .{ page_index, assetKindName(spec.asset_kind) }),
        .asset_kind = assetKindName(spec.asset_kind),
        .kind = if (spec.asset_kind == .glyph_trace_jsonl) "glyph_trace" else "debug_overlay",
        .media_type = if (spec.asset_kind == .glyph_trace_jsonl) "application/x-ndjson" else "image/svg+xml",
        .output_format = spec.suffix,
        .page_index = page_index,
        .layers = spec.layers,
    };
}

fn materializeDocumentAsset(allocator: std.mem.Allocator, result: anytype, dir: []const u8, spec: DocumentAssetSpec, record: *AssetRecord) !void {
    const bytes = switch (spec.asset_kind) {
        .page_overlay_svg => try renderAggregateSvg(allocator, result),
        .hocr => try reconcile.renderHocr(allocator, &result.reconciled),
        .alto => try reconcile.renderAlto(allocator, &result.reconciled),
        .route_trace_json => try renderRouteTraceJson(allocator, result),
        else => try renderAggregateSvg(allocator, result),
    };
    defer allocator.free(bytes);
    try writeMaterialized(allocator, dir, spec.filename, bytes, record);
}

fn materializePageAsset(allocator: std.mem.Allocator, result: anytype, dir: []const u8, page_index: u32, spec: PageAssetSpec, record: *AssetRecord) !void {
    const bytes = switch (spec.asset_kind) {
        .glyph_trace_jsonl => try renderGlyphTraceJsonl(allocator, result, page_index),
        else => try renderPageSvg(allocator, result, page_index, spec.asset_kind),
    };
    defer allocator.free(bytes);

    const filename = try std.fmt.allocPrint(allocator, "page-{d:0>4}.{s}", .{ page_index + 1, spec.suffix });
    defer allocator.free(filename);
    try writeMaterialized(allocator, dir, filename, bytes, record);
}

fn writeMaterialized(allocator: std.mem.Allocator, dir: []const u8, filename: []const u8, bytes: []const u8, record: *AssetRecord) !void {
    try runtime.createDirPathCwd(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, filename });
    errdefer allocator.free(path);

    const file = try runtime.createFileCwd(path);
    try runtime.writeAllFile(file, bytes);
    runtime.closeFile(file);

    record.path = path;
    record.sha256 = try sha256Hex(allocator, bytes);
    record.byte_length = bytes.len;
}

fn renderAggregateSvg(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeSvgOpen(writer, documentBox(result), "aggregate page overlay");
    try writePageOverlayLayers(writer, result, null);
    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice(allocator);
}

fn renderPageSvg(allocator: std.mem.Allocator, result: anytype, page_index: u32, kind: AssetKind) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writeSvgOpen(writer, pageBox(result, page_index), assetKindName(kind));
    switch (kind) {
        .page_overlay_svg => try writePageOverlayLayers(writer, result, page_index),
        .low_confidence_overlay_svg => try writeLowConfidenceLayers(writer, result, page_index),
        .table_grid_overlay_svg => try writeTableGridLayers(writer, result, page_index),
        .ocr_route_overlay_svg => try writeOcrRouteLayers(writer, result, page_index),
        .span_block_id_overlay_svg => try writeSpanBlockIdLayers(writer, result, page_index),
        .glyph_trace_jsonl => {},
        else => try writePageOverlayLayers(writer, result, page_index),
    }
    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice(allocator);
}

fn renderGlyphTraceJsonl(allocator: std.mem.Allocator, result: anytype, page_index: u32) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    var char_index: usize = 0;
    for (result.reconciled.spans, 0..) |span_record, span_index| {
        const span = span_record.span;
        if (span.page_index != page_index) continue;

        const estimated_chars = @max(1, utf8ScalarCount(span.text));
        const char_width = width(span.bbox) / @as(f64, @floatFromInt(estimated_chars));
        var byte_index: usize = 0;
        var local_char_index: usize = 0;
        while (byte_index < span.text.len) {
            const len = std.unicode.utf8ByteSequenceLength(span.text[byte_index]) catch 1;
            const end = @min(span.text.len, byte_index + len);
            const x0 = span.bbox.x0 + char_width * @as(f64, @floatFromInt(local_char_index));
            const bbox = layout.BBox{
                .x0 = x0,
                .y0 = span.bbox.y0,
                .x1 = if (local_char_index + 1 == estimated_chars) span.bbox.x1 else x0 + char_width,
                .y1 = span.bbox.y1,
            };
            try writer.print(
                "{{\"record_type\":\"glyph_trace\",\"page_index\":{},\"span_id\":\"span-{}\",\"glyph_index\":{},\"char_index\":{},\"bbox\":{{\"x0\":{d:.3},\"y0\":{d:.3},\"x1\":{d:.3},\"y1\":{d:.3}}},\"source_code\":null,\"source_bytes\":null,\"text\":\"",
                .{ page_index, span_index, char_index, char_index, bbox.x0, bbox.y0, bbox.x1, bbox.y1 },
            );
            try writeJsonEscaped(writer, span.text[byte_index..end]);
            try writer.print(
                "\",\"font_name\":",
                .{},
            );
            try writeOptionalJsonString(writer, span.font.name);
            try writer.print(
                ",\"font_size\":{d:.3},\"writing_mode\":0,\"generated\":false,\"hyphen\":{},\"unicode_map_error\":{},\"actual_text\":{},\"mcid\":",
                .{ span.font_size, isHyphenText(span.text[byte_index..end]), span.unicode_map_error, span.actual_text },
            );
            if (span.mcid) |mcid| {
                try writer.print("{}", .{mcid});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('\n');

            char_index += 1;
            local_char_index += 1;
            byte_index = end;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn writeSvgOpen(writer: anytype, box: layout.BBox, label: []const u8) !void {
    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\" data-debug-asset=\"{s}\">\n",
        .{ box.x0, box.y0, @max(1, width(box)), @max(1, height(box)), label },
    );
    try writer.writeAll("<style>");
    try writer.writeAll(".page{fill:#fff;stroke:#111827;stroke-width:1.2}.native-span{fill:#2563eb;fill-opacity:.16;stroke:#2563eb;stroke-width:.55}.layout-block{fill:none;stroke:#16a34a;stroke-width:1.2;stroke-dasharray:5 3}.table-candidate{fill:#f59e0b;fill-opacity:.14;stroke:#b45309;stroke-width:1.8}.formula-candidate{fill:#ec4899;fill-opacity:.14;stroke:#be185d;stroke-width:1.8}.ocr-needed{fill:#ef4444;fill-opacity:.11;stroke:#dc2626;stroke-width:2.1;stroke-dasharray:8 4}.low-confidence{fill:#f97316;fill-opacity:.11;stroke:#ea580c;stroke-width:1.6;stroke-dasharray:3 3}.table-grid-cell{fill:#0ea5e9;fill-opacity:.10;stroke:#0369a1;stroke-width:1}.label{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:8px;paint-order:stroke;stroke:white;stroke-width:2px;stroke-linejoin:round}");
    try writer.writeAll("</style>\n<rect class=\"page\" width=\"100%\" height=\"100%\"/>\n");
}

fn writePageOverlayLayers(writer: anytype, result: anytype, page_filter: ?u32) !void {
    try writer.writeAll("<g id=\"page-overlay\">\n");
    try writer.writeAll("<g id=\"native-spans\">\n");
    for (result.reconciled.spans, 0..) |span, index| {
        if (!matchesPage(page_filter, span.span.page_index)) continue;
        try writer.print(
            "<rect class=\"native-span\" data-layer=\"native-spans\" data-span-id=\"span-{d}\" data-page=\"{d}\" data-source=\"{s}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"><title>",
            .{ index, span.span.page_index, @tagName(span.chosen_source), span.span.bbox.x0, span.span.bbox.y0, width(span.span.bbox), height(span.span.bbox) },
        );
        try writeXmlEscaped(writer, span.span.text);
        try writer.writeAll("</title></rect>\n");
    }
    try writer.writeAll("</g>\n<g id=\"layout-blocks\">\n");
    for (result.layout_blocks) |block| {
        if (!matchesPage(page_filter, block.page_index)) continue;
        try writer.print(
            "<rect class=\"layout-block\" data-layer=\"layout-blocks\" data-block-id=\"block-{d}\" data-page=\"{d}\" data-kind=\"{s}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{ block.block_index, block.page_index, @tagName(block.kind), block.confidence, block.bbox.x0, block.bbox.y0, width(block.bbox), height(block.bbox) },
        );
    }
    try writer.writeAll("</g>\n<g id=\"route-regions\">\n");
    try writeRouteRegions(writer, result, page_filter, .all);
    try writer.writeAll("</g>\n</g>\n");
}

fn writeLowConfidenceLayers(writer: anytype, result: anytype, page_index: u32) !void {
    try writer.writeAll("<g id=\"low-confidence-regions\">\n<g id=\"low-confidence-spans\">\n");
    for (result.reconciled.spans, 0..) |span, index| {
        if (span.span.page_index != page_index or span.confidence >= 0.75) continue;
        try writer.print(
            "<rect class=\"low-confidence\" data-layer=\"low-confidence-spans\" data-span-id=\"span-{d}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{ index, span.confidence, span.span.bbox.x0, span.span.bbox.y0, width(span.span.bbox), height(span.span.bbox) },
        );
    }
    try writer.writeAll("</g>\n<g id=\"low-confidence-blocks\">\n");
    for (result.layout_blocks) |block| {
        if (block.page_index != page_index or block.confidence >= 0.75) continue;
        try writer.print(
            "<rect class=\"low-confidence\" data-layer=\"low-confidence-blocks\" data-block-id=\"block-{d}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{ block.block_index, block.confidence, block.bbox.x0, block.bbox.y0, width(block.bbox), height(block.bbox) },
        );
    }
    try writer.writeAll("</g>\n");
    try writeRouteRegions(writer, result, page_index, .low_confidence);
    try writer.writeAll("</g>\n");
}

fn writeTableGridLayers(writer: anytype, result: anytype, page_index: u32) !void {
    try writer.writeAll("<g id=\"table-grid\">\n<g id=\"table-grid-cells\">\n");
    for (result.tables, 0..) |table, table_index| {
        if (table.page_index != page_index) continue;
        for (table.rows) |row| {
            for (row.cells) |cell| {
                try writer.print(
                    "<rect class=\"table-grid-cell\" data-layer=\"table-grid-cells\" data-table-id=\"table-{d}\" data-row=\"{d}\" data-column=\"{d}\" data-rowspan=\"{d}\" data-colspan=\"{d}\" data-role=\"{s}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"><title>",
                    .{ table_index, cell.row_index, cell.column_index, cell.rowspan, cell.colspan, @tagName(cell.role), cell.confidence, cell.bounds.bbox.x0, cell.bounds.bbox.y0, width(cell.bounds.bbox), height(cell.bounds.bbox) },
                );
                try writeXmlEscaped(writer, cell.text);
                try writer.writeAll("</title></rect>\n");
            }
        }
    }
    try writer.writeAll("</g>\n<g id=\"table-grid-labels\">\n");
    for (result.tables, 0..) |table, table_index| {
        if (table.page_index != page_index) continue;
        try writer.print(
            "<text class=\"label\" data-layer=\"table-grid-labels\" x=\"{d:.2}\" y=\"{d:.2}\">table-{d}</text>\n",
            .{ table.bounds.bbox.x0, table.bounds.bbox.y0 - 3, table_index },
        );
    }
    try writer.writeAll("</g>\n</g>\n");
}

fn writeOcrRouteLayers(writer: anytype, result: anytype, page_index: u32) !void {
    try writer.writeAll("<g id=\"ocr-route-overlay\">\n<g id=\"ocr-route-regions\">\n");
    try writeRouteRegions(writer, result, page_index, .ocr);
    try writer.writeAll("</g>\n<g id=\"ocr-route-traces\">\n");
    for (result.trace_records, 0..) |record, index| {
        if (record.page_index != page_index or !record.route.needs_ocr) continue;
        const box = traceBox(result, record) orelse pageBox(result, page_index);
        try writer.print(
            "<rect class=\"ocr-needed\" data-layer=\"ocr-route-traces\" data-route-trace-id=\"trace-{d}\" data-stage=\"{s}\" data-route=\"{s}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{ index, @tagName(record.stage), routeName(record.route), box.x0, box.y0, width(box), height(box) },
        );
    }
    try writer.writeAll("</g>\n</g>\n");
}

fn writeSpanBlockIdLayers(writer: anytype, result: anytype, page_index: u32) !void {
    try writer.writeAll("<g id=\"span-block-id-overlay\">\n<g id=\"span-id-labels\">\n");
    for (result.reconciled.spans, 0..) |span, index| {
        if (span.span.page_index != page_index) continue;
        try writer.print(
            "<text class=\"label\" data-layer=\"span-id-labels\" data-span-id=\"span-{d}\" x=\"{d:.2}\" y=\"{d:.2}\">span-{d}</text>\n",
            .{ index, span.span.bbox.x0, span.span.bbox.y0 - 2, index },
        );
    }
    try writer.writeAll("</g>\n<g id=\"block-id-labels\">\n");
    for (result.layout_blocks) |block| {
        if (block.page_index != page_index) continue;
        try writer.print(
            "<text class=\"label\" data-layer=\"block-id-labels\" data-block-id=\"block-{d}\" x=\"{d:.2}\" y=\"{d:.2}\">block-{d}</text>\n",
            .{ block.block_index, block.bbox.x0, block.bbox.y0 + 9, block.block_index },
        );
    }
    try writer.writeAll("</g>\n</g>\n");
}

const RouteFilter = enum { all, low_confidence, ocr };

fn writeRouteRegions(writer: anytype, result: anytype, page_filter: anytype, filter: RouteFilter) !void {
    for (result.page_routes, 0..) |route, index| {
        if (!matchesPage(page_filter, route.page_index) or !includeRoute(route.route, filter)) continue;
        try writeRouteRect(writer, index, "page", route.page_index, null, route.bbox, route.route);
    }
    for (result.region_routes, 0..) |route, index| {
        if (!matchesPage(page_filter, route.page_index) or !includeRoute(route.route, filter)) continue;
        try writeRouteRect(writer, index, "region", route.page_index, route.region_index, route.bbox, route.route);
    }
}

fn writeRouteRect(writer: anytype, index: usize, scope: []const u8, page_index: u32, region_index: ?u32, box: layout.BBox, route: anytype) !void {
    const class = if (route.needs_ocr) "ocr-needed" else if (routeConfidence(route) < 0.45) "low-confidence" else if (route.needs_table_model) "table-candidate" else if (route.needs_formula_model) "formula-candidate" else "layout-block";
    try writer.print(
        "<rect class=\"{s}\" data-layer=\"route-regions\" data-route-id=\"{s}-{d}\" data-page=\"{d}\" ",
        .{ class, scope, index, page_index },
    );
    if (region_index) |region| try writer.print("data-region=\"{d}\" ", .{region});
    try writer.print(
        "data-route=\"{s}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
        .{ routeName(route), routeConfidence(route), box.x0, box.y0, width(box), height(box) },
    );
}

fn includeRoute(route: anytype, filter: RouteFilter) bool {
    return switch (filter) {
        .all => route.needs_ocr or route.needs_table_model or route.needs_formula_model or routeConfidence(route) < 0.45,
        .low_confidence => routeConfidence(route) < 0.45,
        .ocr => route.needs_ocr,
    };
}

fn renderRouteTraceJson(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);
    try writer.writeAll("{\"record_type\":\"route_trace_debug\",\"routes\":[");
    var wrote = false;
    for (result.page_routes) |route| {
        if (wrote) try writer.writeByte(',');
        try writer.print("{{\"trace_kind\":\"page_route\",\"page_index\":{},\"route\":\"{s}\",\"confidence\":{d:.3}}}", .{ route.page_index, routeName(route.route), routeConfidence(route.route) });
        wrote = true;
    }
    for (result.region_routes) |route| {
        if (wrote) try writer.writeByte(',');
        try writer.print("{{\"trace_kind\":\"region_route\",\"page_index\":{},\"region_index\":{},\"route\":\"{s}\",\"confidence\":{d:.3}}}", .{ route.page_index, route.region_index, routeName(route.route), routeConfidence(route.route) });
        wrote = true;
    }
    for (result.trace_records) |record| {
        if (wrote) try writer.writeByte(',');
        try writer.print("{{\"trace_kind\":\"stage\",\"page_index\":{},\"stage\":\"{s}\",\"route\":\"{s}\",\"confidence\":{d:.3}}}", .{ record.page_index, @tagName(record.stage), routeName(record.route), routeConfidence(record.route) });
        wrote = true;
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice(allocator);
}

fn pageCount(result: anytype) usize {
    if (result.page_routes.len > 0) return result.page_routes.len;
    var max_page: usize = 0;
    for (result.reconciled.spans) |span| max_page = @max(max_page, span.span.page_index + 1);
    for (result.layout_blocks) |block| max_page = @max(max_page, block.page_index + 1);
    for (result.tables) |table| max_page = @max(max_page, table.page_index + 1);
    return @max(max_page, 1);
}

fn pageBox(result: anytype, page_index: u32) layout.BBox {
    for (result.page_routes) |route| {
        if (route.page_index == page_index) return route.bbox;
    }
    var maybe_box: ?layout.BBox = null;
    for (result.reconciled.spans) |span| {
        if (span.span.page_index == page_index) maybe_box = unionMaybeBox(maybe_box, span.span.bbox);
    }
    for (result.layout_blocks) |block| {
        if (block.page_index == page_index) maybe_box = unionMaybeBox(maybe_box, block.bbox);
    }
    for (result.tables) |table| {
        if (table.page_index == page_index) maybe_box = unionMaybeBox(maybe_box, table.bounds.bbox);
    }
    return maybe_box orelse .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
}

fn documentBox(result: anytype) layout.BBox {
    var maybe_box: ?layout.BBox = null;
    for (result.page_routes) |route| maybe_box = unionMaybeBox(maybe_box, route.bbox);
    for (result.layout_blocks) |block| maybe_box = unionMaybeBox(maybe_box, block.bbox);
    for (result.reconciled.spans) |span| maybe_box = unionMaybeBox(maybe_box, span.span.bbox);
    for (result.tables) |table| maybe_box = unionMaybeBox(maybe_box, table.bounds.bbox);
    return maybe_box orelse .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
}

fn traceBox(result: anytype, record: anytype) ?layout.BBox {
    if (record.region_index) |region_index| {
        for (result.region_routes) |route| {
            if (route.page_index == record.page_index and route.region_index == region_index) return route.bbox;
        }
    }
    for (result.page_routes) |route| {
        if (route.page_index == record.page_index) return route.bbox;
    }
    return null;
}

fn unionMaybeBox(existing: ?layout.BBox, next: layout.BBox) layout.BBox {
    if (existing) |box| {
        return .{
            .x0 = @min(box.x0, next.x0),
            .y0 = @min(box.y0, next.y0),
            .x1 = @max(box.x1, next.x1),
            .y1 = @max(box.y1, next.y1),
        };
    }
    return next;
}

fn matchesPage(page_filter: anytype, page_index: u32) bool {
    return switch (@TypeOf(page_filter)) {
        ?u32 => if (page_filter) |wanted| wanted == page_index else true,
        u32 => page_filter == page_index,
        else => true,
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

fn width(box: layout.BBox) f64 {
    return @max(0, box.x1 - box.x0);
}

fn height(box: layout.BBox) f64 {
    return @max(0, box.y1 - box.y0);
}

fn writeXmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') {
            try writer.print("\\u{x:0>4}", .{byte});
            continue;
        }
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
}

fn writeOptionalJsonString(writer: anytype, maybe_text: ?[]const u8) !void {
    if (maybe_text) |text| {
        try writer.writeByte('"');
        try writeJsonEscaped(writer, text);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
}

fn utf8ScalarCount(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @max(@as(usize, 1), @min(len, text.len - i));
        count += 1;
    }
    return count;
}

fn isHyphenText(text: []const u8) bool {
    return std.mem.eql(u8, text, "-") or
        std.mem.eql(u8, text, "\xC2\xAD") or
        std.mem.eql(u8, text, "\xE2\x80\x90") or
        std.mem.eql(u8, text, "\xE2\x80\x91") or
        std.mem.eql(u8, text, "\xE2\x88\x92");
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const out = try allocator.alloc(u8, digest.len * 2);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &encoded);
    return out;
}

test "visual asset kind names are stable" {
    try std.testing.expectEqualStrings("page_overlay_svg", assetKindName(.page_overlay_svg));
    try std.testing.expectEqualStrings("table_grid_overlay_svg", assetKindName(.table_grid_overlay_svg));
    try std.testing.expectEqualStrings("route_trace_json", assetKindName(.route_trace_json));
    try std.testing.expectEqualStrings("glyph_trace_jsonl", assetKindName(.glyph_trace_jsonl));
}
