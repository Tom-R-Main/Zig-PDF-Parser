//! Adaptive extraction orchestration types.
//!
//! Adaptive extraction orchestration: native spans, layout, complexity routing,
//! optional specialist span producers, reconciliation, and output rendering.

const std = @import("std");
const layout = @import("layout.zig");
const complexity = @import("complexity.zig");
const ocr = @import("ocr.zig");
const reconcile = @import("reconcile.zig");
const runtime = @import("runtime.zig");
const schema = @import("schema.zig");
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
    enable_ocr: bool = true,
    ocr_config: ocr.OcrConfig = .{},
    preserve_layout_order: bool = true,
    reconcile_options: ReconcileOptions = .{},
};

pub const OutputFormat = enum {
    text,
    markdown,
    json,
    jsonl,
    rag_jsonl,
    artifact_jsonl,
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
    ocr_recognize,
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
    column_index: u32,
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
        var route = args.score.route;
        var mask = reasonMask(args.score, args.specialist);
        if (args.block_kind) |kind| {
            switch (kind) {
                .table_candidate => {
                    route.needs_table_model = true;
                    route.max_signal = @max(route.max_signal, if (table) |score| score.confidence else 0.72);
                    mask |= reasonBit(.table_route_stub);
                },
                .formula_candidate => {
                    route.needs_formula_model = true;
                    route.max_signal = @max(route.max_signal, if (formula) |score| score.confidence else 0.76);
                    mask |= reasonBit(.formula_route_stub);
                },
                else => {},
            }
        }
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
            .route = route,
            .reason_mask = mask,
        };
    }
};

pub const FormField = struct {
    name: []u8,
    value: ?[]u8,
    field_type: []u8,
    rect: ?[4]f64,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    reconciled: ReconciledDocument,
    layout_blocks: []LayoutBlockSummary,
    page_routes: []PageRoute,
    region_routes: []RegionRoute,
    trace_records: []TraceRecord,
    form_fields: []FormField,
    tables: []layout.TableGrid,

    pub fn deinit(self: *Result) void {
        self.reconciled.deinit();
        self.allocator.free(self.layout_blocks);
        self.allocator.free(self.page_routes);
        self.allocator.free(self.region_routes);
        self.allocator.free(self.trace_records);
        freeFormFields(self.allocator, self.form_fields);
        freeOwnedTables(self.allocator, self.tables);
    }

    pub fn render(self: *const Result, allocator: std.mem.Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .debug_svg => renderDebugSvg(allocator, self),
            .json => schema.renderArtifactJson(allocator, self, .{}),
            .artifact_jsonl => schema.renderArtifactJsonl(allocator, self, .{}),
            else => renderOutput(allocator, &self.reconciled, format),
        };
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

    var ocr_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (ocr_pages.items) |spans| ocr.freeSpans(allocator, spans);
        ocr_pages.deinit(allocator);
    }

    var layout_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (layout_pages.items) |spans| freeTextSpans(allocator, spans);
        layout_pages.deinit(allocator);
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

    var tables: std.ArrayList(layout.TableGrid) = .empty;
    defer tables.deinit(allocator);
    errdefer freeOwnedTables(allocator, tables.items);

    const form_fields = try collectFormFields(allocator, document);
    errdefer freeFormFields(allocator, form_fields);

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

        var page_ocr_spans: ?[]layout.TextSpan = null;
        if (options.enable_ocr and page_route.route.needs_ocr) {
            const maybe_ocr_input = document.rasterizePageForOcr(allocator, page_idx, options.ocr_config) catch |err| switch (err) {
                error.OcrRasterizerUnavailable,
                error.OcrRasterizerFailed,
                error.InvalidRasterImage,
                => null,
                else => return err,
            };
            if (maybe_ocr_input) |ocr_input| {
                defer {
                    runtime.deleteFileCwd(ocr_input.image_path);
                    allocator.free(@constCast(ocr_input.image_path));
                }

                const raw_ocr_spans = ocr.recognizeRegion(allocator, ocr_input, options.ocr_config) catch |err| switch (err) {
                    error.TesseractUnavailable,
                    error.TesseractFailed,
                    error.TesseractCBackendDisabled,
                    => try allocator.alloc(layout.TextSpan, 0),
                    else => return err,
                };
                const ocr_spans = try filterOcrSpansForPage(allocator, raw_ocr_spans, spans, image_boxes);
                try ocr_pages.append(allocator, ocr_spans);
                page_ocr_spans = ocr_spans;
                try trace_records.append(allocator, .{
                    .page_index = page_index,
                    .stage = .ocr_recognize,
                    .route = page_route.route,
                    .reason_mask = page_route.reason_mask,
                    .span_count = ocr_spans.len,
                });
            } else {
                try trace_records.append(allocator, .{
                    .page_index = page_index,
                    .stage = .ocr_recognize,
                    .route = page_route.route,
                    .reason_mask = page_route.reason_mask,
                    .span_count = 0,
                });
            }
        }

        const ruling_lines = try document.getPageRulingLines(page_idx, allocator);
        defer allocator.free(ruling_lines);

        const page_width = page.media_box[2] - page.media_box[0];
        var page_layout = try layout.analyzeLayoutWithRulings(allocator, spans, page_width, ruling_lines);
        defer page_layout.deinit();
        reorderSpansToLayoutOrder(spans, page_layout.spans);

        for (page_layout.tables) |table| {
            try tables.append(allocator, try copyTableGrid(allocator, table));
        }

        if (page_layout.tables.len > 0) {
            const layout_spans = try buildLayoutLayerSpans(allocator, &page_layout);
            if (layout_spans.len > 0) {
                try layout_pages.append(allocator, layout_spans);
                try layers.append(allocator, .{
                    .spans = layout_spans,
                    .trust = 1.0,
                });
            } else {
                freeTextSpans(allocator, layout_spans);
                try layers.append(allocator, .{
                    .source = .native_pdf,
                    .spans = spans,
                    .trust = 1.0,
                });
            }
        } else {
            try layers.append(allocator, .{
                .source = .native_pdf,
                .spans = spans,
                .trust = 1.0,
            });
        }

        if (page_ocr_spans) |ocr_spans| {
            if (ocr_spans.len > 0) {
                try layers.append(allocator, .{
                    .source = .fresh_ocr,
                    .spans = ocr_spans,
                    .trust = 0.82,
                });
            }
        }

        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .layout_blocks,
            .span_count = spans.len,
            .block_count = page_layout.blocks.len,
        });

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

    const form_spans = try formFieldsToSpans(allocator, form_fields);
    defer freeTextSpans(allocator, form_spans);
    if (form_spans.len > 0) {
        try layers.append(allocator, .{
            .source = .manual,
            .spans = form_spans,
            .trust = 1.0,
        });
    }

    var reconcile_options = options.reconcile_options;
    if (options.preserve_layout_order) reconcile_options.preserve_input_order = true;
    var reconciled = try reconcile.reconcile(allocator, layers.items, reconcile_options);
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
    const owned_tables = try tables.toOwnedSlice(allocator);
    errdefer freeOwnedTables(allocator, owned_tables);

    return .{
        .allocator = allocator,
        .reconciled = reconciled,
        .layout_blocks = owned_layout_blocks,
        .page_routes = owned_page_routes,
        .region_routes = owned_region_routes,
        .trace_records = owned_trace_records,
        .form_fields = form_fields,
        .tables = owned_tables,
    };
}

fn collectFormFields(allocator: std.mem.Allocator, document: anytype) ![]FormField {
    const DocumentPtr = @TypeOf(document);
    const document_info = @typeInfo(DocumentPtr);
    if (document_info != .pointer) return allocator.alloc(FormField, 0);
    const DocumentType = document_info.pointer.child;
    if (!@hasDecl(DocumentType, "getFormFields") or !@hasDecl(DocumentType, "freeFormFields")) {
        return allocator.alloc(FormField, 0);
    }

    const source_fields = try document.getFormFields(allocator);
    defer DocumentType.freeFormFields(allocator, source_fields);

    var fields: std.ArrayList(FormField) = .empty;
    errdefer {
        for (fields.items) |field| freeFormField(allocator, field);
        fields.deinit(allocator);
    }

    for (source_fields) |field| {
        const copied_name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(copied_name);

        const copied_value = if (field.value) |value| try allocator.dupe(u8, value) else null;
        errdefer if (copied_value) |value| allocator.free(value);

        const copied_type = try allocator.dupe(u8, @tagName(field.field_type));
        errdefer allocator.free(copied_type);

        try fields.append(allocator, .{
            .name = copied_name,
            .value = copied_value,
            .field_type = copied_type,
            .rect = field.rect,
        });
    }

    return fields.toOwnedSlice(allocator);
}

fn freeFormFields(allocator: std.mem.Allocator, fields: []FormField) void {
    for (fields) |field| freeFormField(allocator, field);
    allocator.free(fields);
}

fn freeFormField(allocator: std.mem.Allocator, field: FormField) void {
    allocator.free(field.name);
    if (field.value) |value| allocator.free(value);
    allocator.free(field.field_type);
}

fn copyTableGrid(allocator: std.mem.Allocator, source: layout.TableGrid) !layout.TableGrid {
    const rows = try allocator.alloc(layout.TableRow, source.rows.len);
    var completed_rows: usize = 0;
    errdefer {
        for (rows[0..completed_rows]) |row| {
            for (row.cells) |cell| allocator.free(@constCast(cell.text));
            allocator.free(row.cells);
        }
        allocator.free(rows);
    }

    for (source.rows, 0..) |row, row_index| {
        rows[row_index] = try copyTableRow(allocator, row);
        completed_rows += 1;
    }

    var copied_table = source;
    copied_table.rows = rows;
    return copied_table;
}

fn copyTableRow(allocator: std.mem.Allocator, source: layout.TableRow) !layout.TableRow {
    const cells = try allocator.alloc(layout.TableCell, source.cells.len);
    var completed_cells: usize = 0;
    errdefer {
        for (cells[0..completed_cells]) |cell| allocator.free(@constCast(cell.text));
        allocator.free(cells);
    }

    for (source.cells, 0..) |cell, cell_index| {
        var copied = cell;
        copied.text = try allocator.dupe(u8, cell.text);
        cells[cell_index] = copied;
        completed_cells += 1;
    }

    var copied_row = source;
    copied_row.cells = cells;
    return copied_row;
}

fn freeOwnedTables(allocator: std.mem.Allocator, tables: []layout.TableGrid) void {
    for (tables) |table| {
        for (table.rows) |row| {
            for (row.cells) |cell| allocator.free(@constCast(cell.text));
            allocator.free(row.cells);
        }
        allocator.free(table.rows);
    }
    allocator.free(tables);
}

fn formFieldsToSpans(allocator: std.mem.Allocator, fields: []const FormField) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| freeOwnedTextSpan(allocator, span);
        spans.deinit(allocator);
    }

    for (fields) |field| {
        const value = field.value orelse continue;
        if (field.name.len == 0 or value.len == 0) continue;

        var text = try std.ArrayList(u8).initCapacity(allocator, field.name.len + 1 + value.len);
        errdefer text.deinit(allocator);
        try text.appendSlice(allocator, field.name);
        try text.append(allocator, ' ');
        try text.appendSlice(allocator, value);
        const owned_text = try text.toOwnedSlice(allocator);
        errdefer allocator.free(owned_text);

        const bbox = if (field.rect) |rect|
            BBox{ .x0 = rect[0], .y0 = rect[1], .x1 = rect[2], .y1 = rect[3] }
        else
            BBox{ .x0 = 36, .y0 = 36, .x1 = 576, .y1 = 50 };

        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = bbox,
            .text = owned_text,
            .source = .manual,
            .confidence = 1.0,
            .font = .{ .size = 10 },
        }));
    }

    return spans.toOwnedSlice(allocator);
}

fn filterOcrSpansForPage(
    allocator: std.mem.Allocator,
    ocr_spans: []layout.TextSpan,
    native_spans: []const layout.TextSpan,
    images: []const complexity.ImageBox,
) ![]layout.TextSpan {
    if (ocr_spans.len == 0 or native_spans.len == 0 or images.len == 0) return ocr_spans;

    var kept = try std.ArrayList(layout.TextSpan).initCapacity(allocator, ocr_spans.len);
    errdefer {
        for (kept.items) |span| allocator.free(@constCast(span.text));
        kept.deinit(allocator);
    }

    for (ocr_spans) |span| {
        if (spanOverlapsAnyImage(span, images)) {
            try kept.append(allocator, span);
        } else {
            allocator.free(@constCast(span.text));
        }
    }
    allocator.free(ocr_spans);
    return kept.toOwnedSlice(allocator);
}

fn spanOverlapsAnyImage(span: layout.TextSpan, images: []const complexity.ImageBox) bool {
    const span_area = width(span.bbox) * height(span.bbox);
    if (span_area <= 0) return false;
    for (images) |image| {
        const overlap = overlapArea(span.bbox, image.bbox);
        if (overlap / span_area >= 0.50) return true;
    }
    return false;
}

fn overlapArea(a: BBox, b: BBox) f64 {
    const x0 = @max(a.x0, b.x0);
    const y0 = @max(a.y0, b.y0);
    const x1 = @min(a.x1, b.x1);
    const y1 = @min(a.y1, b.y1);
    if (x1 <= x0 or y1 <= y0) return 0;
    return (x1 - x0) * (y1 - y0);
}

fn reorderSpansToLayoutOrder(spans: []layout.TextSpan, ordered: []const layout.TextSpan) void {
    if (spans.len != ordered.len) return;
    @memcpy(spans, ordered);
}

fn buildLayoutLayerSpans(allocator: std.mem.Allocator, page_layout: *const layout.LayoutResult) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }

    for (page_layout.blocks, 0..) |block, block_index| {
        if (block.removed or block.lines.len == 0) continue;

        if (page_layout.tableForBlock(block_index)) |table| {
            if (tableHasUsefulTextRows(table)) {
                try appendBlockLinesOutsideTable(allocator, &spans, block, table);
                try appendTableRowSpans(allocator, &spans, table);
                continue;
            }
        }
        if (page_layout.blockCoveredByTable(block_index)) {
            var skip_covered = false;
            if (tableCoveringBlock(page_layout.tables, block_index)) |table| {
                skip_covered = tableHasUsefulTextRows(table);
            }
            if (skip_covered) continue;
        }

        for (block.lines) |line| {
            const text = try lineTextOwned(allocator, &line);
            errdefer allocator.free(text);
            if (text.len == 0) {
                allocator.free(text);
                continue;
            }
            try spans.append(allocator, layout.TextSpan.init(.{
                .page_index = line.bounds.page_index,
                .bbox = line.bounds.bbox,
                .text = text,
                .source = line.bounds.source,
                .confidence = block.confidence,
                .font = stableFont(line.bounds.font),
                .block_id = line.bounds.block_id,
                .line_id = line.bounds.line_id,
                .mcid = line.bounds.mcid,
            }));
        }
    }

    return spans.toOwnedSlice(allocator);
}

fn tableCoveringBlock(tables: []const layout.TableGrid, block_index: usize) ?*const layout.TableGrid {
    for (tables) |*table| {
        const start: usize = @intCast(table.block_index);
        if (block_index >= start and block_index < start + table.block_count) return table;
    }
    return null;
}

fn tableHasUsefulTextRows(table: *const layout.TableGrid) bool {
    var occupied_rows: usize = 0;
    for (table.rows) |row| {
        for (row.cells) |cell| {
            if (cell.text.len > 0) {
                occupied_rows += 1;
                break;
            }
        }
    }
    return occupied_rows >= 2;
}

fn appendTableRowSpans(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    table: *const layout.TableGrid,
) !void {
    for (table.rows) |row| {
        const text = try tableRowTextOwned(allocator, row);
        errdefer allocator.free(text);
        if (text.len == 0) {
            allocator.free(text);
            continue;
        }
        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = row.bounds.page_index,
            .bbox = row.bounds.bbox,
            .text = text,
            .source = .table_model,
            .confidence = table.confidence,
            .font = stableFont(row.bounds.font),
            .block_id = row.bounds.block_id,
            .line_id = row.bounds.line_id,
            .mcid = row.bounds.mcid,
        }));
    }
}

fn appendBlockLinesOutsideTable(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    block: layout.LayoutBlock,
    table: *const layout.TableGrid,
) !void {
    for (block.lines) |line| {
        if (spansIntersect(line.bounds, table.bounds)) continue;
        try appendLineSpan(allocator, spans, line, block.confidence);
    }
}

fn appendLineSpan(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    line: layout.TextLine,
    confidence: f32,
) !void {
    const text = try lineTextOwned(allocator, &line);
    errdefer allocator.free(text);
    if (text.len == 0) {
        allocator.free(text);
        return;
    }
    try spans.append(allocator, layout.TextSpan.init(.{
        .page_index = line.bounds.page_index,
        .bbox = line.bounds.bbox,
        .text = text,
        .source = line.bounds.source,
        .confidence = confidence,
        .font = stableFont(line.bounds.font),
        .block_id = line.bounds.block_id,
        .line_id = line.bounds.line_id,
        .mcid = line.bounds.mcid,
    }));
}

fn spansIntersect(a: layout.TextSpan, b: layout.TextSpan) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
}

fn lineTextOwned(allocator: std.mem.Allocator, line: *const layout.TextLine) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var wrote = false;
    for (line.words, 0..) |word, word_index| {
        if (word_index > 0 and wrote) try output.append(allocator, ' ');
        for (word.spans) |span| {
            try output.appendSlice(allocator, span.text);
            wrote = true;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn tableRowTextOwned(allocator: std.mem.Allocator, row: layout.TableRow) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var wrote_cell = false;
    for (row.cells) |cell| {
        if (cell.text.len == 0) continue;
        if (wrote_cell) try output.append(allocator, ' ');
        try output.appendSlice(allocator, cell.text);
        wrote_cell = true;
    }

    return output.toOwnedSlice(allocator);
}

fn stableFont(font: layout.FontMetadata) layout.FontMetadata {
    return .{
        .size = font.size,
        .has_to_unicode = font.has_to_unicode,
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
        .column_index = block.column_index,
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
        .artifact_jsonl => unreachable,
        .hocr => reconcile.renderHocr(allocator, doc),
        .alto => reconcile.renderAlto(allocator, doc),
        .debug_svg => reconcile.renderDebugSvg(allocator, doc),
    };
}

pub fn renderDebugSvg(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const box = debugDocumentBox(result);
    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\" data-debug-svg=\"adaptive\">\n",
        .{ box.x0, box.y0, @max(1, width(box)), @max(1, height(box)) },
    );
    try writer.writeAll("<style>");
    try writer.writeAll(".page{fill:#fff;stroke:#111827;stroke-width:1.2}.native-span{fill:#2563eb;fill-opacity:.18;stroke:#2563eb;stroke-width:.55}.layout-block{fill:none;stroke-width:1.3;stroke-dasharray:5 3}.layout-col-0{stroke:#16a34a}.layout-col-1{stroke:#7c3aed}.layout-col-n{stroke:#0891b2}.table-candidate{fill:#f59e0b;fill-opacity:.16;stroke:#b45309;stroke-width:2}.formula-candidate{fill:#ec4899;fill-opacity:.16;stroke:#be185d;stroke-width:2}.header-footer{fill:#64748b;fill-opacity:.12;stroke:#475569;stroke-width:1.5}.ocr-needed{fill:#ef4444;fill-opacity:.10;stroke:#dc2626;stroke-width:2.2;stroke-dasharray:8 4}.low-confidence{fill:#f97316;fill-opacity:.10;stroke:#ea580c;stroke-width:1.7;stroke-dasharray:3 3}.label{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:8px;paint-order:stroke;stroke:white;stroke-width:2px;stroke-linejoin:round}.legend{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:9px}");
    try writer.writeAll("</style>\n");
    try writer.writeAll("<rect class=\"page\" width=\"100%\" height=\"100%\"/>\n");
    try writer.writeAll("<g class=\"legend\"><text x=\"8\" y=\"14\">debug-svg: native spans, layout blocks, table/formula candidates, headers/footers, OCR/low confidence regions</text></g>\n");

    try writer.writeAll("<g id=\"native-spans\">\n");
    for (result.reconciled.spans) |span| {
        try writer.print(
            "<rect class=\"native-span\" data-page=\"{d}\" data-source=\"{s}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"><title>",
            .{ span.span.page_index, sourceName(span.chosen_source), span.span.bbox.x0, span.span.bbox.y0, width(span.span.bbox), height(span.span.bbox) },
        );
        try writeXmlEscaped(writer, span.span.text);
        try writer.writeAll("</title></rect>\n");
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("<g id=\"layout-blocks\">\n");
    for (result.layout_blocks) |block| {
        const class = if (block.kind == .header or block.kind == .footer)
            "layout-block header-footer"
        else if (block.column_index == 0)
            "layout-block layout-col-0"
        else if (block.column_index == 1)
            "layout-block layout-col-1"
        else
            "layout-block layout-col-n";
        try writer.print(
            "<rect class=\"{s}\" data-layer=\"layout-block\" data-page=\"{d}\" data-block=\"{d}\" data-column=\"{d}\" data-kind=\"{s}\" data-removed=\"{}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{
                class,
                block.page_index,
                block.block_index,
                block.column_index,
                blockKindName(block.kind),
                block.removed,
                block.confidence,
                block.bbox.x0,
                block.bbox.y0,
                width(block.bbox),
                height(block.bbox),
            },
        );
        try writer.print(
            "<text class=\"label\" data-layer=\"layout-label\" x=\"{d:.2}\" y=\"{d:.2}\" fill=\"{s}\">block {d} col {d} {s}</text>\n",
            .{ block.bbox.x0, block.bbox.y0 - 3, columnColor(block.column_index), block.block_index, block.column_index, blockKindName(block.kind) },
        );
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("<g id=\"route-regions\">\n");
    for (result.page_routes) |route| {
        if (!route.route.needs_ocr and routeConfidence(route.route) >= 0.45) continue;
        const class = if (route.route.needs_ocr) "ocr-needed" else "low-confidence";
        try writeRouteRect(writer, class, "page", route.page_index, null, route.bbox, route.route, route.reason_mask);
    }
    for (result.region_routes) |route| {
        if (isTableCandidate(route)) {
            try writeRouteRect(writer, "table-candidate", "table", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
        if (isFormulaCandidate(route)) {
            try writeRouteRect(writer, "formula-candidate", "formula", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
        if (route.route.needs_ocr or routeConfidence(route.route) < 0.45) {
            const class = if (route.route.needs_ocr) "ocr-needed" else "low-confidence";
            try writeRouteRect(writer, class, "region", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice(allocator);
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

fn writeRouteRect(
    writer: anytype,
    class: []const u8,
    layer: []const u8,
    page_index: u32,
    region_index: ?u32,
    bbox: BBox,
    route: RouteDecision,
    reason_mask: RouteReasonMask,
) !void {
    try writer.print(
        "<rect class=\"{s}\" data-layer=\"{s}\" data-page=\"{d}\" ",
        .{ class, layer, page_index },
    );
    if (region_index) |index| try writer.print("data-region=\"{d}\" ", .{index});
    try writer.print(
        "data-route=\"{s}\" data-confidence=\"{d:.3}\" data-reasons=\"",
        .{ routeName(route), routeConfidence(route) },
    );
    try writeReasonCsv(writer, reason_mask);
    try writer.print(
        "\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
        .{ bbox.x0, bbox.y0, width(bbox), height(bbox) },
    );
}

fn debugDocumentBox(result: *const Result) BBox {
    var maybe_box: ?BBox = null;
    for (result.page_routes) |route| maybe_box = unionMaybeBox(maybe_box, route.bbox);
    for (result.layout_blocks) |block| maybe_box = unionMaybeBox(maybe_box, block.bbox);
    for (result.region_routes) |route| maybe_box = unionMaybeBox(maybe_box, route.bbox);
    for (result.reconciled.spans) |span| maybe_box = unionMaybeBox(maybe_box, span.span.bbox);
    return maybe_box orelse .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
}

fn unionMaybeBox(existing: ?BBox, next: BBox) BBox {
    if (width(next) <= 0 and height(next) <= 0) return existing orelse next;
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

fn isTableCandidate(route: RegionRoute) bool {
    return route.route.needs_table_model or
        hasReason(route.reason_mask, .table_alignment) or
        hasReason(route.reason_mask, .table_route_stub) or
        route.block_kind == .table_candidate or
        (route.table != null and route.table.?.needsSpecialist());
}

fn isFormulaCandidate(route: RegionRoute) bool {
    return route.route.needs_formula_model or
        hasReason(route.reason_mask, .formula_density) or
        hasReason(route.reason_mask, .formula_route_stub) or
        route.block_kind == .formula_candidate or
        (route.formula != null and route.formula.?.needsSpecialist());
}

fn routeName(route: RouteDecision) []const u8 {
    if (route.native_fast_path) return "use_native";
    if (route.needs_ocr) return "queue_ocr";
    if (route.needs_table_model and route.needs_formula_model) return "candidate_table_formula";
    if (route.needs_table_model) return "candidate_table";
    if (route.needs_formula_model) return "candidate_formula";
    if (route.needs_layout_model) return "candidate_layout";
    return "review";
}

fn routeConfidence(route: RouteDecision) f32 {
    const signal = @max(0.0, @min(1.0, route.max_signal));
    if (route.native_fast_path) return 1.0 - signal;
    return signal;
}

fn writeReasonCsv(writer: anytype, mask: RouteReasonMask) !void {
    const reasons = [_]RouteReason{
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
    var first = true;
    for (reasons) |reason| {
        if (!hasReason(mask, reason)) continue;
        if (!first) try writer.writeByte(',');
        try writer.writeAll(reasonName(reason));
        first = false;
    }
}

fn reasonName(reason: RouteReason) []const u8 {
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

fn blockKindName(kind: BlockKind) []const u8 {
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

fn sourceName(source: layout.SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native_pdf",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula_model",
        .manual => "manual",
    };
}

fn columnColor(column_index: u32) []const u8 {
    return switch (column_index) {
        0 => "#16a34a",
        1 => "#7c3aed",
        else => "#0891b2",
    };
}

fn width(box: BBox) f64 {
    return @max(0, box.x1 - box.x0);
}

fn height(box: BBox) f64 {
    return @max(0, box.y1 - box.y0);
}

fn writeXmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(byte),
    };
}

fn freeTextSpans(allocator: std.mem.Allocator, spans: []layout.TextSpan) void {
    if (spans.len == 0) return;
    for (spans) |span| freeOwnedTextSpan(allocator, span);
    allocator.free(spans);
}

fn freeOwnedTextSpan(allocator: std.mem.Allocator, span: layout.TextSpan) void {
    if (span.text.len > 0) allocator.free(@constCast(span.text));
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

test "debug svg marks low-confidence review regions" {
    var spans = [_]reconcile.ReconciledSpan{};
    var blocks = [_]reconcile.ReconciledBlock{};
    var chunks = [_]reconcile.RagChunk{};
    const doc = ReconciledDocument{
        .allocator = std.testing.allocator,
        .spans = &spans,
        .blocks = &blocks,
        .chunks = &chunks,
    };
    var layout_blocks = [_]LayoutBlockSummary{};
    var page_routes = [_]PageRoute{
        .{
            .page_index = 0,
            .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
            .span_count = 1,
            .image_count = 0,
            .char_count = 8,
            .signals = .{},
            .route = .{ .native_fast_path = false, .max_signal = 0.25 },
            .reason_mask = reasonBit(.low_reading_order_confidence),
        },
    };
    var region_routes = [_]RegionRoute{};
    var trace_records = [_]TraceRecord{};
    const result = Result{
        .allocator = std.testing.allocator,
        .reconciled = doc,
        .layout_blocks = &layout_blocks,
        .page_routes = &page_routes,
        .region_routes = &region_routes,
        .trace_records = &trace_records,
        .form_fields = &.{},
        .tables = &.{},
    };

    const svg = try renderDebugSvg(std.testing.allocator, &result);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "class=\"low-confidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "low_reading_order_confidence") != null);
}

test "mixed native OCR filter keeps image OCR and drops page furniture OCR" {
    const allocator = std.testing.allocator;

    var ocr_spans = try allocator.alloc(layout.TextSpan, 2);
    ocr_spans[0] = layout.TextSpan.init(.{
        .page_index = 0,
        .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 40, .y1 = 24 },
        .text = try allocator.dupe(u8, "native duplicate"),
        .source = .fresh_ocr,
    });
    ocr_spans[1] = layout.TextSpan.init(.{
        .page_index = 0,
        .bbox = .{ .x0 = 110, .y0 = 110, .x1 = 160, .y1 = 124 },
        .text = try allocator.dupe(u8, "scan text"),
        .source = .fresh_ocr,
    });

    const native_spans = [_]layout.TextSpan{
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 40, .y1 = 24 },
            .text = "native duplicate",
        }),
    };
    const images = [_]complexity.ImageBox{
        .{
            .bbox = .{ .x0 = 100, .y0 = 100, .x1 = 200, .y1 = 200 },
            .pixel_width = 1000,
            .pixel_height = 1000,
        },
    };

    const filtered = try filterOcrSpansForPage(allocator, ocr_spans, &native_spans, &images);
    defer {
        for (filtered) |span| allocator.free(@constCast(span.text));
        allocator.free(filtered);
    }

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("scan text", filtered[0].text);
}
