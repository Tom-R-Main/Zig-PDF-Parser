//! Adaptive extraction orchestration types.
//!
//! Sprint 2 keeps OCR/table/formula specialists behind traceable route stubs:
//! the native parser produces spans, layout and complexity score those spans,
//! and the reconciler produces the output model.

const std = @import("std");
const layout = @import("layout.zig");
const complexity = @import("complexity.zig");
const reconcile = @import("reconcile.zig");
const runtime = @import("runtime.zig");
const specialists = @import("specialists.zig");

pub const BBox = layout.BBox;
pub const BlockKind = layout.BlockKind;
pub const ReconciledDocument = reconcile.ReconciledDocument;
pub const ReconcileOptions = reconcile.ReconcileOptions;
pub const RouteDecision = complexity.RouteDecision;
pub const SignalScores = complexity.SignalScores;

pub const ExtractOptions = struct {
    page_start: ?usize = null,
    page_end: ?usize = null,
    reconcile_options: ReconcileOptions = .{},
};

pub const OutputFormat = enum {
    text,
    markdown,
    json,
    jsonl,
    rag_jsonl,
    hocr,
    alto,
    debug_svg,
};

pub const RouteReason = enum(u5) {
    native_fast_path,
    sparse_text,
    image_dominance,
    bad_unicode,
    missing_tounicode,
    hidden_ocr,
    low_reading_order_confidence,
    table_alignment,
    formula_density,
    ocr_route_stub,
    layout_route_stub,
    table_route_stub,
    formula_route_stub,
};

pub const RouteReasonMask = u32;

pub const TraceStage = enum {
    native_spans,
    layout_blocks,
    complexity_score,
    route_decision,
    ocr_route_stub,
    table_route_stub,
    formula_route_stub,
    reconcile,
    output_ready,
};

pub const TraceRecord = struct {
    page_index: u32,
    region_index: ?u32 = null,
    stage: TraceStage,
    route: RouteDecision = .{},
    reason_mask: RouteReasonMask = 0,
    span_count: usize = 0,
    block_count: usize = 0,
};

pub const PageRoute = struct {
    page_index: u32,
    bbox: BBox,
    span_count: usize,
    image_count: usize,
    char_count: usize,
    signals: SignalScores,
    route: RouteDecision,
    reason_mask: RouteReasonMask,

    pub fn fromScore(score: complexity.PageScore) PageRoute {
        return .{
            .page_index = score.page_index,
            .bbox = score.page_bbox,
            .span_count = score.score.span_count,
            .image_count = score.score.image_count,
            .char_count = score.score.char_count,
            .signals = score.score.signals,
            .route = score.score.route,
            .reason_mask = reasonMask(score.score, null),
        };
    }
};

pub const LayoutBlockSummary = struct {
    page_index: u32,
    block_index: u32,
    bbox: BBox,
    kind: BlockKind,
    confidence: f32,
    removed: bool,
    line_count: usize,
};

pub const RegionRoute = struct {
    page_index: u32,
    region_index: u32,
    layout_block_index: ?u32 = null,
    bbox: BBox,
    block_kind: ?BlockKind = null,
    span_count: usize,
    image_count: usize,
    char_count: usize,
    signals: SignalScores,
    table: ?specialists.TableScore = null,
    formula: ?specialists.FormulaScore = null,
    route: RouteDecision,
    reason_mask: RouteReasonMask,

    pub fn fromScore(args: struct {
        region_index: u32,
        layout_block_index: ?u32 = null,
        block_kind: ?BlockKind = null,
        score: complexity.RegionScore,
        specialist: ?specialists.AnalysisResult = null,
    }) RegionRoute {
        const table = if (args.specialist) |analysis| analysis.table else null;
        const formula = if (args.specialist) |analysis| analysis.formula else null;
        return .{
            .page_index = args.score.page_index,
            .region_index = args.region_index,
            .layout_block_index = args.layout_block_index,
            .bbox = args.score.bbox,
            .block_kind = args.block_kind,
            .span_count = args.score.span_count,
            .image_count = args.score.image_count,
            .char_count = args.score.char_count,
            .signals = args.score.signals,
            .table = table,
            .formula = formula,
            .route = args.score.route,
            .reason_mask = reasonMask(args.score, args.specialist),
        };
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    reconciled: ReconciledDocument,
    layout_blocks: []LayoutBlockSummary,
    page_routes: []PageRoute,
    region_routes: []RegionRoute,
    trace_records: []TraceRecord,

    pub fn deinit(self: *Result) void {
        self.reconciled.deinit();
        self.allocator.free(self.layout_blocks);
        self.allocator.free(self.page_routes);
        self.allocator.free(self.region_routes);
        self.allocator.free(self.trace_records);
    }

    pub fn render(self: *const Result, allocator: std.mem.Allocator, format: OutputFormat) ![]u8 {
        return renderOutput(allocator, &self.reconciled, format);
    }
};

pub fn extractDocument(
    allocator: std.mem.Allocator,
    document: anytype,
    options: ExtractOptions,
) !Result {
    const page_start = options.page_start orelse 0;
    const page_end = options.page_end orelse document.pages.items.len;
    if (page_start > page_end or page_end > document.pages.items.len) return error.InvalidPageRange;

    var native_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (native_pages.items) |spans| freeTextSpans(allocator, spans);
        native_pages.deinit(allocator);
    }

    var layers: std.ArrayList(reconcile.SpanLayer) = .empty;
    defer layers.deinit(allocator);

    var layout_blocks: std.ArrayList(LayoutBlockSummary) = .empty;
    defer layout_blocks.deinit(allocator);

    var page_routes: std.ArrayList(PageRoute) = .empty;
    defer page_routes.deinit(allocator);

    var region_routes: std.ArrayList(RegionRoute) = .empty;
    defer region_routes.deinit(allocator);

    var trace_records: std.ArrayList(TraceRecord) = .empty;
    defer trace_records.deinit(allocator);

    const has_structure_tree = document.hasStructureTree();
    var region_index: u32 = 0;

    for (page_start..page_end) |page_idx| {
        const page = document.pages.items[page_idx];
        const page_index: u32 = @intCast(page_idx);
        const page_bbox = BBox{
            .x0 = page.media_box[0],
            .y0 = page.media_box[1],
            .x1 = page.media_box[2],
            .y1 = page.media_box[3],
        };

        const spans = try document.extractTextWithBounds(page_idx, allocator);
        try native_pages.append(allocator, spans);
        try layers.append(allocator, .{
            .source = .native_pdf,
            .spans = spans,
            .trust = 1.0,
        });
        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .native_spans,
            .span_count = spans.len,
        });

        const images = try document.getPageImages(page_idx, allocator);
        defer allocator.free(images);

        const image_boxes = try allocator.alloc(complexity.ImageBox, images.len);
        defer allocator.free(image_boxes);
        for (images, 0..) |image, image_index| {
            image_boxes[image_index] = .{
                .bbox = .{
                    .x0 = image.rect[0],
                    .y0 = image.rect[1],
                    .x1 = image.rect[2],
                    .y1 = image.rect[3],
                },
                .pixel_width = image.width,
                .pixel_height = image.height,
            };
        }

        const page_input = complexity.PageInput{
            .page_index = page_index,
            .bbox = page_bbox,
            .spans = spans,
            .images = image_boxes,
            .has_structure_tree = has_structure_tree,
        };

        const page_score = complexity.scorePage(page_input);
        const page_route = PageRoute.fromScore(page_score);
        try page_routes.append(allocator, page_route);
        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .complexity_score,
            .route = page_route.route,
            .reason_mask = page_route.reason_mask,
            .span_count = page_route.span_count,
        });
        try appendRouteTraces(
            allocator,
            &trace_records,
            page_index,
            null,
            page_route.route,
            page_route.reason_mask,
            page_route.span_count,
            0,
        );

        const page_width = page.media_box[2] - page.media_box[0];
        var page_layout = try layout.analyzeLayout(allocator, spans, page_width);
        defer page_layout.deinit();

        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .layout_blocks,
            .span_count = spans.len,
            .block_count = page_layout.blocks.len,
        });

        const ruling_lines = try document.getPageRulingLines(page_idx, allocator);
        defer allocator.free(ruling_lines);

        if (page_layout.blocks.len == 0) {
            const score = complexity.scoreRegion(page_input, page_bbox);
            const specialist = specialists.analyzeRegion(.{
                .page_index = page_index,
                .bbox = page_bbox,
                .spans = spans,
                .ruling_lines = ruling_lines,
            });
            const route = RegionRoute.fromScore(.{
                .region_index = region_index,
                .score = score,
                .specialist = specialist,
            });
            try region_routes.append(allocator, route);
            try appendRouteTraces(
                allocator,
                &trace_records,
                page_index,
                region_index,
                route.route,
                route.reason_mask,
                route.span_count,
                0,
            );
            region_index += 1;
            continue;
        }

        for (page_layout.blocks, 0..) |block, block_index| {
            const block_index_u32: u32 = @intCast(block_index);
            try layout_blocks.append(allocator, layoutBlockSummary(page_index, block_index_u32, block));

            const score = complexity.scoreRegion(page_input, block.bounds.bbox);
            const specialist = specialists.analyzeRegion(.{
                .page_index = page_index,
                .bbox = block.bounds.bbox,
                .spans = spans,
                .ruling_lines = ruling_lines,
            });
            const route = RegionRoute.fromScore(.{
                .region_index = region_index,
                .layout_block_index = block_index_u32,
                .block_kind = block.kind,
                .score = score,
                .specialist = specialist,
            });
            try region_routes.append(allocator, route);
            try appendRouteTraces(
                allocator,
                &trace_records,
                page_index,
                region_index,
                route.route,
                route.reason_mask,
                route.span_count,
                1,
            );
            region_index += 1;
        }
    }

    var reconciled = try reconcile.reconcile(allocator, layers.items, options.reconcile_options);
    errdefer reconciled.deinit();
    try trace_records.append(allocator, .{
        .page_index = @intCast(page_start),
        .stage = .reconcile,
        .span_count = reconciled.spans.len,
        .block_count = reconciled.blocks.len,
    });
    try trace_records.append(allocator, .{
        .page_index = @intCast(page_start),
        .stage = .output_ready,
        .span_count = reconciled.spans.len,
        .block_count = reconciled.chunks.len,
    });

    const owned_layout_blocks = try layout_blocks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_layout_blocks);
    const owned_page_routes = try page_routes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_page_routes);
    const owned_region_routes = try region_routes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_region_routes);
    const owned_trace_records = try trace_records.toOwnedSlice(allocator);
    errdefer allocator.free(owned_trace_records);

    return .{
        .allocator = allocator,
        .reconciled = reconciled,
        .layout_blocks = owned_layout_blocks,
        .page_routes = owned_page_routes,
        .region_routes = owned_region_routes,
        .trace_records = owned_trace_records,
    };
}

pub fn reasonBit(reason: RouteReason) RouteReasonMask {
    return @as(RouteReasonMask, 1) << @intFromEnum(reason);
}

pub fn hasReason(mask: RouteReasonMask, reason: RouteReason) bool {
    return (mask & reasonBit(reason)) != 0;
}

pub fn reasonMask(score: complexity.RegionScore, specialist: ?specialists.AnalysisResult) RouteReasonMask {
    var mask: RouteReasonMask = 0;
    const route = score.route;
    const signals = score.signals;

    if (route.native_fast_path) mask |= reasonBit(.native_fast_path);
    if (signals.sparse_text >= 0.50) mask |= reasonBit(.sparse_text);
    if (signals.image_dominance >= 0.20) mask |= reasonBit(.image_dominance);
    if (signals.bad_unicode >= 0.20) mask |= reasonBit(.bad_unicode);
    if (signals.missing_tounicode >= 0.20) mask |= reasonBit(.missing_tounicode);
    if (signals.hidden_ocr >= 0.20) mask |= reasonBit(.hidden_ocr);
    if (signals.low_reading_order_confidence >= 0.20) mask |= reasonBit(.low_reading_order_confidence);
    if (signals.table_alignment >= 0.20) mask |= reasonBit(.table_alignment);
    if (signals.formula_density >= 0.20) mask |= reasonBit(.formula_density);

    if (route.needs_ocr) mask |= reasonBit(.ocr_route_stub);
    if (route.needs_layout_model) mask |= reasonBit(.layout_route_stub);
    if (route.needs_table_model) mask |= reasonBit(.table_route_stub);
    if (route.needs_formula_model) mask |= reasonBit(.formula_route_stub);

    if (specialist) |analysis| {
        if (analysis.table.needsSpecialist()) mask |= reasonBit(.table_route_stub);
        if (analysis.formula.needsSpecialist()) mask |= reasonBit(.formula_route_stub);
    }

    return mask;
}

pub fn layoutBlockSummary(page_index: u32, block_index: u32, block: layout.LayoutBlock) LayoutBlockSummary {
    return .{
        .page_index = page_index,
        .block_index = block_index,
        .bbox = block.bounds.bbox,
        .kind = block.kind,
        .confidence = block.confidence,
        .removed = block.removed,
        .line_count = block.lines.len,
    };
}

pub fn appendRouteTraces(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(TraceRecord),
    page_index: u32,
    region_index: ?u32,
    route: RouteDecision,
    reason_mask: RouteReasonMask,
    span_count: usize,
    block_count: usize,
) !void {
    try traces.append(allocator, .{
        .page_index = page_index,
        .region_index = region_index,
        .stage = .route_decision,
        .route = route,
        .reason_mask = reason_mask,
        .span_count = span_count,
        .block_count = block_count,
    });
    if (route.needs_ocr) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .ocr_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
    if (route.needs_table_model or hasReason(reason_mask, .table_route_stub)) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .table_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
    if (route.needs_formula_model or hasReason(reason_mask, .formula_route_stub)) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .formula_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
}

pub fn renderOutput(
    allocator: std.mem.Allocator,
    doc: *const ReconciledDocument,
    format: OutputFormat,
) ![]u8 {
    return switch (format) {
        .text => renderText(allocator, doc),
        .markdown => reconcile.renderMarkdown(allocator, doc),
        .json => reconcile.renderJson(allocator, doc),
        .jsonl => reconcile.renderJsonl(allocator, doc, .spans),
        .rag_jsonl => reconcile.renderRagJsonl(allocator, doc),
        .hocr => reconcile.renderHocr(allocator, doc),
        .alto => reconcile.renderAlto(allocator, doc),
        .debug_svg => reconcile.renderDebugSvg(allocator, doc),
    };
}

fn renderText(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    var previous_page: ?u32 = null;
    for (doc.blocks, 0..) |block, index| {
        if (block.kind == .header or block.kind == .footer) continue;
        if (previous_page) |page| {
            if (page != block.page_index) try writer.writeByte('\x0c');
        }
        previous_page = block.page_index;

        if (index > 0 and output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
            try writer.writeAll("\n\n");
        }
        try writer.writeAll(block.text);
    }

    return output.toOwnedSlice(allocator);
}

fn freeTextSpans(allocator: std.mem.Allocator, spans: []layout.TextSpan) void {
    if (spans.len == 0) return;
    for (spans) |span| {
        if (span.text.len > 0) allocator.free(@constCast(span.text));
    }
    allocator.free(spans);
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) layout.TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = y1 - y0, .has_to_unicode = true },
    });
}

test "page route records native fast path for clean native text" {
    const spans = [_]layout.TextSpan{
        testSpan("Native text extraction keeps this paragraph readable", 72, 700, 360, 712),
        testSpan("without OCR or specialist escalation for this route", 72, 684, 350, 696),
        testSpan("because the text density and Unicode signals are healthy", 72, 668, 380, 680),
        testSpan("and reading order is backed by document structure", 72, 652, 340, 664),
    };
    const score = complexity.scorePage(.{
        .page_index = 0,
        .bbox = .{ .x0 = 60, .y0 = 640, .x1 = 400, .y1 = 720 },
        .spans = &spans,
        .has_structure_tree = true,
    });
    const route = PageRoute.fromScore(score);

    try std.testing.expect(route.route.native_fast_path);
    try std.testing.expect(hasReason(route.reason_mask, .native_fast_path));
    try std.testing.expect(!hasReason(route.reason_mask, .ocr_route_stub));
}

test "route traces emit OCR stub when route needs OCR" {
    var traces: std.ArrayList(TraceRecord) = .empty;
    defer traces.deinit(std.testing.allocator);

    const route = RouteDecision{
        .native_fast_path = false,
        .needs_ocr = true,
        .max_signal = 1,
    };
    const mask = reasonBit(.ocr_route_stub);
    try appendRouteTraces(std.testing.allocator, &traces, 2, null, route, mask, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), traces.items.len);
    try std.testing.expectEqual(TraceStage.route_decision, traces.items[0].stage);
    try std.testing.expectEqual(TraceStage.ocr_route_stub, traces.items[1].stage);
}
