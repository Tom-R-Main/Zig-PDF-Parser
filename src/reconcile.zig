//! Span reconciliation and multi-format export.
//!
//! The reconciler is the boundary between extraction routes. Native text,
//! embedded OCR, fresh OCR, and local specialist spans are collapsed into one
//! ordered span/block/chunk model while retaining source provenance.

const std = @import("std");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");

pub const BBox = layout.BBox;
pub const TextSpan = layout.TextSpan;
pub const SourceKind = layout.SourceKind;
pub const BlockKind = layout.BlockKind;

pub const SourceMask = u32;

pub const SpanLayer = struct {
    source: SourceKind,
    spans: []const TextSpan,
    trust: f32 = 1.0,
};

pub const ReconcileOptions = struct {
    overlap_threshold: f64 = 0.65,
    same_line_threshold: f64 = 4,
    block_gap_multiplier: f64 = 1.8,
    default_chunk_source_id: []const u8 = "document",
    max_chunk_bytes: usize = 1600,
};

pub const ReconciledSpan = struct {
    span: TextSpan,
    source_mask: SourceMask,
    source_count: u8 = 1,
    duplicate_count: u32 = 0,
    chosen_source: SourceKind,
    confidence: f32,
};

pub const ReconciledBlock = struct {
    id: u32,
    page_index: u32,
    bbox: BBox,
    kind: BlockKind,
    text: []u8,
    span_start: u32,
    span_count: u32,
    source_mask: SourceMask,
    confidence: f32,
};

pub const RagChunk = struct {
    source_id: []u8,
    chunk_index: u32,
    block_start: u32,
    block_count: u32,
    page_start: u32,
    page_end: u32,
    bbox: BBox,
    content: []u8,
    source_mask: SourceMask,
    confidence: f32,
};

pub const ReconciledDocument = struct {
    allocator: std.mem.Allocator,
    spans: []ReconciledSpan,
    blocks: []ReconciledBlock,
    chunks: []RagChunk,

    pub fn deinit(self: *ReconciledDocument) void {
        for (self.spans) |span| freeOwnedSpan(self.allocator, span.span);
        self.allocator.free(self.spans);

        for (self.blocks) |block| self.allocator.free(block.text);
        self.allocator.free(self.blocks);

        for (self.chunks) |chunk| {
            self.allocator.free(chunk.source_id);
            self.allocator.free(chunk.content);
        }
        self.allocator.free(self.chunks);
    }
};

pub const JsonlKind = enum {
    spans,
    blocks,
    chunks,
};

pub fn reconcile(
    allocator: std.mem.Allocator,
    layers: []const SpanLayer,
    options: ReconcileOptions,
) !ReconciledDocument {
    var spans: std.ArrayList(ReconciledSpan) = .empty;
    errdefer {
        for (spans.items) |span| freeOwnedSpan(allocator, span.span);
        spans.deinit(allocator);
    }

    for (layers) |layer| {
        for (layer.spans) |span| {
            if (span.text.len == 0) continue;

            const candidate = try copySpan(allocator, span, layer.source, layer.trust);

            if (findDuplicate(spans.items, candidate, options.overlap_threshold)) |index| {
                mergeDuplicate(allocator, &spans.items[index], candidate);
            } else {
                spans.append(allocator, candidate) catch |err| {
                    freeReconciledSpan(allocator, candidate);
                    return err;
                };
            }
        }
    }

    std.mem.sort(ReconciledSpan, spans.items, {}, spanLessThan);

    const blocks = try buildBlocks(allocator, spans.items, options);
    errdefer {
        for (blocks) |block| allocator.free(block.text);
        allocator.free(blocks);
    }

    const chunks = try buildChunks(allocator, blocks, options);
    errdefer {
        for (chunks) |chunk| {
            allocator.free(chunk.source_id);
            allocator.free(chunk.content);
        }
        allocator.free(chunks);
    }

    return .{
        .allocator = allocator,
        .spans = try spans.toOwnedSlice(allocator),
        .blocks = blocks,
        .chunks = chunks,
    };
}

pub fn renderMarkdown(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    var previous_page: ?u32 = null;
    for (doc.blocks, 0..) |block, index| {
        if (previous_page) |page| {
            if (page != block.page_index) try writer.writeAll("\n---\n\n");
        }
        previous_page = block.page_index;

        if (index > 0 and output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
            try writer.writeAll("\n\n");
        }

        switch (block.kind) {
            .heading => try writer.print("## {s}\n", .{block.text}),
            .list_item => try writer.print("- {s}\n", .{stripListPrefix(block.text)}),
            .table_candidate => try writer.print("```table\n{s}\n```\n", .{block.text}),
            .formula_candidate => try writer.print("```math\n{s}\n```\n", .{block.text}),
            .caption => try writer.print("> {s}\n", .{block.text}),
            .header, .footer => {},
            else => try writer.print("{s}\n", .{block.text}),
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn renderJson(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("{\"spans\":[");
    for (doc.spans, 0..) |span, index| {
        if (index > 0) try writer.writeByte(',');
        try writeSpanJson(writer, span);
    }
    try writer.writeAll("],\"blocks\":[");
    for (doc.blocks, 0..) |block, index| {
        if (index > 0) try writer.writeByte(',');
        try writeBlockJson(writer, block);
    }
    try writer.writeAll("],\"rag_chunks\":[");
    for (doc.chunks, 0..) |chunk, index| {
        if (index > 0) try writer.writeByte(',');
        try writeChunkJson(writer, chunk);
    }
    try writer.writeAll("]}");

    return output.toOwnedSlice(allocator);
}

pub fn renderJsonl(
    allocator: std.mem.Allocator,
    doc: *const ReconciledDocument,
    kind: JsonlKind,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    switch (kind) {
        .spans => for (doc.spans) |span| {
            try writeSpanJson(writer, span);
            try writer.writeByte('\n');
        },
        .blocks => for (doc.blocks) |block| {
            try writeBlockJson(writer, block);
            try writer.writeByte('\n');
        },
        .chunks => for (doc.chunks) |chunk| {
            try writeRagChunkJsonl(writer, chunk);
            try writer.writeByte('\n');
        },
    }

    return output.toOwnedSlice(allocator);
}

pub fn renderRagJsonl(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    return renderJsonl(allocator, doc, .chunks);
}

pub fn renderHocr(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("<!DOCTYPE html>\n<html><body>\n");
    var current_page: ?u32 = null;
    for (doc.blocks) |block| {
        if (current_page == null or current_page.? != block.page_index) {
            if (current_page != null) try writer.writeAll("</div>\n");
            current_page = block.page_index;
            try writer.print(
                "<div class=\"ocr_page\" id=\"page_{d}\" title=\"bbox {d:.0} {d:.0} {d:.0} {d:.0}\">\n",
                .{ block.page_index + 1, block.bbox.x0, block.bbox.y0, block.bbox.x1, block.bbox.y1 },
            );
        }
        try writer.print(
            "<p class=\"ocr_par\" id=\"block_{d}\" title=\"bbox {d:.0} {d:.0} {d:.0} {d:.0}; x_source {s}; x_wconf {d:.0}\">",
            .{
                block.id,
                block.bbox.x0,
                block.bbox.y0,
                block.bbox.x1,
                block.bbox.y1,
                sourceMaskName(block.source_mask),
                block.confidence * 100,
            },
        );
        try writeHtmlEscaped(writer, block.text);
        try writer.writeAll("</p>\n");
    }
    if (current_page != null) try writer.writeAll("</div>\n");
    try writer.writeAll("</body></html>\n");

    return output.toOwnedSlice(allocator);
}

pub fn renderAlto(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<alto><Layout>\n");
    var current_page: ?u32 = null;
    for (doc.blocks) |block| {
        if (current_page == null or current_page.? != block.page_index) {
            if (current_page != null) try writer.writeAll("</PrintSpace></Page>\n");
            current_page = block.page_index;
            try writer.print(
                "<Page ID=\"page_{d}\" PHYSICAL_IMG_NR=\"{d}\"><PrintSpace>\n",
                .{ block.page_index + 1, block.page_index + 1 },
            );
        }
        try writer.print(
            "<TextBlock ID=\"block_{d}\" HPOS=\"{d:.2}\" VPOS=\"{d:.2}\" WIDTH=\"{d:.2}\" HEIGHT=\"{d:.2}\" TAGREFS=\"{s}\"><TextLine><String CONTENT=\"",
            .{
                block.id,
                block.bbox.x0,
                block.bbox.y0,
                width(block.bbox),
                height(block.bbox),
                sourceMaskName(block.source_mask),
            },
        );
        try writeXmlEscaped(writer, block.text);
        try writer.writeAll("\" WC=\"");
        try writer.print("{d:.3}", .{block.confidence});
        try writer.writeAll("\"/></TextLine></TextBlock>\n");
    }
    if (current_page != null) try writer.writeAll("</PrintSpace></Page>\n");
    try writer.writeAll("</Layout></alto>\n");

    return output.toOwnedSlice(allocator);
}

pub fn renderDebugSvg(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const page_box = documentBox(doc.blocks);
    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\">\n",
        .{ page_box.x0, page_box.y0, @max(1, width(page_box)), @max(1, height(page_box)) },
    );
    try writer.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n");
    for (doc.blocks) |block| {
        try writer.print(
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"1\"/>\n",
            .{ block.bbox.x0, block.bbox.y0, width(block.bbox), height(block.bbox), sourceColor(block.source_mask) },
        );
        try writer.print(
            "<text x=\"{d:.2}\" y=\"{d:.2}\" font-size=\"8\" fill=\"{s}\">#{d} {s}</text>\n",
            .{ block.bbox.x0, block.bbox.y0, sourceColor(block.source_mask), block.id, blockKindName(block.kind) },
        );
    }
    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice(allocator);
}

fn buildBlocks(
    allocator: std.mem.Allocator,
    spans: []const ReconciledSpan,
    options: ReconcileOptions,
) ![]ReconciledBlock {
    var blocks: std.ArrayList(ReconciledBlock) = .empty;
    errdefer {
        for (blocks.items) |block| allocator.free(block.text);
        blocks.deinit(allocator);
    }

    if (spans.len == 0) return blocks.toOwnedSlice(allocator);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    var start_index: usize = 0;
    var current_bbox = spans[0].span.bbox;
    var current_page = spans[0].span.page_index;
    var current_kind = kindForSpan(spans[0].span);
    var current_mask = spans[0].source_mask;
    var confidence_sum: f32 = 0;
    var confidence_count: u32 = 0;

    for (spans, 0..) |span, index| {
        if (index > start_index and shouldStartBlock(spans[index - 1], span, options)) {
            try finishBlock(
                allocator,
                &blocks,
                &text,
                start_index,
                index - start_index,
                current_page,
                current_bbox,
                current_kind,
                current_mask,
                confidence_sum,
                confidence_count,
            );
            start_index = index;
            current_bbox = span.span.bbox;
            current_page = span.span.page_index;
            current_kind = kindForSpan(span.span);
            current_mask = span.source_mask;
            confidence_sum = 0;
            confidence_count = 0;
        } else if (index > start_index) {
            current_bbox = unionBox(current_bbox, span.span.bbox);
            current_kind = mergeBlockKind(current_kind, kindForSpan(span.span));
            current_mask |= span.source_mask;
        }

        if (text.items.len > 0) {
            const previous = spans[index - 1].span;
            if (sameLine(previous, span.span, options.same_line_threshold)) {
                const gap = span.span.bbox.x0 - previous.bbox.x1;
                if (gap > @max(1, previous.font_size * 0.15)) try text.append(allocator, ' ');
            } else {
                try text.append(allocator, '\n');
            }
        }
        try text.appendSlice(allocator, span.span.text);
        confidence_sum += span.confidence;
        confidence_count += 1;
    }

    try finishBlock(
        allocator,
        &blocks,
        &text,
        start_index,
        spans.len - start_index,
        current_page,
        current_bbox,
        current_kind,
        current_mask,
        confidence_sum,
        confidence_count,
    );

    return blocks.toOwnedSlice(allocator);
}

fn finishBlock(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(ReconciledBlock),
    text: *std.ArrayList(u8),
    span_start: usize,
    span_count: usize,
    page_index: u32,
    bbox: BBox,
    kind: BlockKind,
    source_mask: SourceMask,
    confidence_sum: f32,
    confidence_count: u32,
) !void {
    const owned_text = try text.toOwnedSlice(allocator);
    text.* = .empty;
    if (owned_text.len == 0) {
        allocator.free(owned_text);
        return;
    }

    try blocks.append(allocator, .{
        .id = @intCast(blocks.items.len),
        .page_index = page_index,
        .bbox = bbox,
        .kind = kind,
        .text = owned_text,
        .span_start = @intCast(span_start),
        .span_count = @intCast(span_count),
        .source_mask = source_mask,
        .confidence = if (confidence_count == 0) 0 else confidence_sum / @as(f32, @floatFromInt(confidence_count)),
    });
}

fn buildChunks(
    allocator: std.mem.Allocator,
    blocks: []const ReconciledBlock,
    options: ReconcileOptions,
) ![]RagChunk {
    var chunks: std.ArrayList(RagChunk) = .empty;
    errdefer {
        for (chunks.items) |chunk| {
            allocator.free(chunk.source_id);
            allocator.free(chunk.content);
        }
        chunks.deinit(allocator);
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    var start_block: usize = 0;
    var bbox: BBox = .{};
    var page_start: u32 = 0;
    var page_end: u32 = 0;
    var source_mask: SourceMask = 0;
    var confidence_sum: f32 = 0;
    var confidence_count: u32 = 0;

    for (blocks, 0..) |block, index| {
        const would_overflow = text.items.len > 0 and text.items.len + block.text.len + 2 > options.max_chunk_bytes;
        if (would_overflow) {
            try finishChunk(
                allocator,
                &chunks,
                &text,
                options.default_chunk_source_id,
                start_block,
                index - start_block,
                page_start,
                page_end,
                bbox,
                source_mask,
                confidence_sum,
                confidence_count,
            );
            start_block = index;
            bbox = block.bbox;
            page_start = block.page_index;
            page_end = block.page_index;
            source_mask = 0;
            confidence_sum = 0;
            confidence_count = 0;
        } else if (text.items.len == 0) {
            bbox = block.bbox;
            page_start = block.page_index;
            page_end = block.page_index;
        } else {
            bbox = unionBox(bbox, block.bbox);
            page_end = block.page_index;
        }

        if (text.items.len > 0) try text.appendSlice(allocator, "\n\n");
        try text.appendSlice(allocator, block.text);
        source_mask |= block.source_mask;
        confidence_sum += block.confidence;
        confidence_count += 1;
    }

    if (text.items.len > 0) {
        try finishChunk(
            allocator,
            &chunks,
            &text,
            options.default_chunk_source_id,
            start_block,
            blocks.len - start_block,
            page_start,
            page_end,
            bbox,
            source_mask,
            confidence_sum,
            confidence_count,
        );
    }

    return chunks.toOwnedSlice(allocator);
}

fn finishChunk(
    allocator: std.mem.Allocator,
    chunks: *std.ArrayList(RagChunk),
    text: *std.ArrayList(u8),
    source_id: []const u8,
    block_start: usize,
    block_count: usize,
    page_start: u32,
    page_end: u32,
    bbox: BBox,
    source_mask: SourceMask,
    confidence_sum: f32,
    confidence_count: u32,
) !void {
    const content = try text.toOwnedSlice(allocator);
    text.* = .empty;

    try chunks.append(allocator, .{
        .source_id = try allocator.dupe(u8, source_id),
        .chunk_index = @intCast(chunks.items.len),
        .block_start = @intCast(block_start),
        .block_count = @intCast(block_count),
        .page_start = page_start,
        .page_end = page_end,
        .bbox = bbox,
        .content = content,
        .source_mask = source_mask,
        .confidence = if (confidence_count == 0) 0 else confidence_sum / @as(f32, @floatFromInt(confidence_count)),
    });
}

fn copySpan(
    allocator: std.mem.Allocator,
    span: TextSpan,
    source: SourceKind,
    trust: f32,
) !ReconciledSpan {
    var copied = span;
    copied.source = source;
    copied.text = try allocator.dupe(u8, span.text);
    errdefer allocator.free(@constCast(copied.text));

    copied.font.name = if (span.font.name) |name| try allocator.dupe(u8, name) else null;
    errdefer if (copied.font.name) |name| allocator.free(@constCast(name));
    copied.font.encoding = if (span.font.encoding) |encoding| try allocator.dupe(u8, encoding) else null;
    errdefer if (copied.font.encoding) |encoding| allocator.free(@constCast(encoding));

    const confidence = @min(1.0, copied.confidence * trust);
    copied.confidence = confidence;

    return .{
        .span = copied,
        .source_mask = sourceMask(source),
        .source_count = 1,
        .duplicate_count = 0,
        .chosen_source = source,
        .confidence = confidence,
    };
}

fn freeReconciledSpan(allocator: std.mem.Allocator, span: ReconciledSpan) void {
    freeOwnedSpan(allocator, span.span);
}

fn freeOwnedSpan(allocator: std.mem.Allocator, span: TextSpan) void {
    allocator.free(@constCast(span.text));
    if (span.font.name) |name| allocator.free(@constCast(name));
    if (span.font.encoding) |encoding| allocator.free(@constCast(encoding));
}

fn findDuplicate(spans: []const ReconciledSpan, candidate: ReconciledSpan, overlap_threshold: f64) ?usize {
    for (spans, 0..) |existing, index| {
        if (existing.span.page_index != candidate.span.page_index) continue;
        if (existing.span.mcid != null and candidate.span.mcid != null and existing.span.mcid.? == candidate.span.mcid.?) {
            return index;
        }
        if (!std.mem.eql(u8, normalizedText(existing.span.text), normalizedText(candidate.span.text))) continue;
        if (intersectionOverMinArea(existing.span.bbox, candidate.span.bbox) >= overlap_threshold) return index;
    }
    return null;
}

fn mergeDuplicate(allocator: std.mem.Allocator, existing: *ReconciledSpan, candidate: ReconciledSpan) void {
    const merged_mask = existing.source_mask | candidate.source_mask;
    const replace = sourceScore(candidate) > sourceScore(existing.*);

    if (replace) {
        const old_span = existing.span;
        existing.span = candidate.span;
        existing.chosen_source = candidate.chosen_source;
        freeOwnedSpan(allocator, old_span);
    } else {
        freeReconciledSpan(allocator, candidate);
    }

    existing.source_mask = merged_mask;
    existing.source_count = countSourceBits(merged_mask);
    existing.duplicate_count += 1;
    existing.confidence = @max(existing.confidence, candidate.confidence);
}

fn shouldStartBlock(previous: ReconciledSpan, current: ReconciledSpan, options: ReconcileOptions) bool {
    if (previous.span.page_index != current.span.page_index) return true;
    if (kindForSpan(previous.span) != kindForSpan(current.span)) return true;
    if (previous.span.block_id != null and current.span.block_id != null and previous.span.block_id.? != current.span.block_id.?) return true;

    if (sameLine(previous.span, current.span, options.same_line_threshold)) return false;

    const gap = previous.span.bbox.y0 - current.span.bbox.y0;
    const font_size = @max(1, previous.span.font_size);
    return gap > font_size * options.block_gap_multiplier;
}

fn spanLessThan(_: void, a: ReconciledSpan, b: ReconciledSpan) bool {
    if (a.span.page_index != b.span.page_index) return a.span.page_index < b.span.page_index;
    const ay = @as(i64, @intFromFloat(a.span.bbox.y0 / 4));
    const by = @as(i64, @intFromFloat(b.span.bbox.y0 / 4));
    if (ay != by) return ay > by;
    return a.span.bbox.x0 < b.span.bbox.x0;
}

fn sourceScore(span: ReconciledSpan) f32 {
    return span.confidence * sourcePriority(span.chosen_source);
}

fn sourcePriority(source: SourceKind) f32 {
    return switch (source) {
        .native_pdf => 1.0,
        .embedded_ocr => 0.94,
        .table_model => 0.92,
        .formula_model => 0.92,
        .fresh_ocr => 0.82,
        .manual => 1.0,
    };
}

fn kindForSpan(span: TextSpan) BlockKind {
    return switch (span.source) {
        .table_model => .table_candidate,
        .formula_model => .formula_candidate,
        else => if (span.font_size >= 16) .heading else .paragraph,
    };
}

fn mergeBlockKind(a: BlockKind, b: BlockKind) BlockKind {
    if (a == b) return a;
    if (a == .table_candidate or b == .table_candidate) return .table_candidate;
    if (a == .formula_candidate or b == .formula_candidate) return .formula_candidate;
    if (a == .heading or b == .heading) return .heading;
    return .paragraph;
}

fn sameLine(a: TextSpan, b: TextSpan, threshold: f64) bool {
    return @abs(a.bbox.y0 - b.bbox.y0) <= threshold;
}

fn sourceMask(source: SourceKind) SourceMask {
    return @as(SourceMask, 1) << @as(u5, @intCast(@intFromEnum(source)));
}

pub fn hasSource(mask: SourceMask, source: SourceKind) bool {
    return (mask & sourceMask(source)) != 0;
}

fn countSourceBits(mask: SourceMask) u8 {
    return @intCast(@popCount(mask));
}

fn sourceMaskName(mask: SourceMask) []const u8 {
    if (hasSource(mask, .manual)) return "manual";
    if (hasSource(mask, .native_pdf) and countSourceBits(mask) == 1) return "native_pdf";
    if (hasSource(mask, .table_model) and countSourceBits(mask) == 1) return "table_model";
    if (hasSource(mask, .formula_model) and countSourceBits(mask) == 1) return "formula_model";
    if (hasSource(mask, .fresh_ocr) and countSourceBits(mask) == 1) return "fresh_ocr";
    if (hasSource(mask, .embedded_ocr) and countSourceBits(mask) == 1) return "embedded_ocr";
    return "mixed";
}

fn sourceKindName(source: SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native_pdf",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula_model",
        .manual => "manual",
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

fn sourceColor(mask: SourceMask) []const u8 {
    if (hasSource(mask, .table_model)) return "#0f766e";
    if (hasSource(mask, .formula_model)) return "#7c3aed";
    if (hasSource(mask, .fresh_ocr)) return "#dc2626";
    if (hasSource(mask, .embedded_ocr)) return "#ca8a04";
    return "#2563eb";
}

fn normalizedText(text: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = text.len;
    while (start < end and std.ascii.isWhitespace(text[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    return text[start..end];
}

fn intersectionOverMinArea(a: BBox, b: BBox) f64 {
    const ix0 = @max(a.x0, b.x0);
    const iy0 = @max(a.y0, b.y0);
    const ix1 = @min(a.x1, b.x1);
    const iy1 = @min(a.y1, b.y1);
    if (ix1 <= ix0 or iy1 <= iy0) return 0;
    const intersection = (ix1 - ix0) * (iy1 - iy0);
    const min_area = @min(area(a), area(b));
    if (min_area <= 0) return 0;
    return intersection / min_area;
}

fn area(box: BBox) f64 {
    return @max(0, width(box)) * @max(0, height(box));
}

fn width(box: BBox) f64 {
    return box.x1 - box.x0;
}

fn height(box: BBox) f64 {
    return box.y1 - box.y0;
}

fn unionBox(a: BBox, b: BBox) BBox {
    return .{
        .x0 = @min(a.x0, b.x0),
        .y0 = @min(a.y0, b.y0),
        .x1 = @max(a.x1, b.x1),
        .y1 = @max(a.y1, b.y1),
    };
}

fn documentBox(blocks: []const ReconciledBlock) BBox {
    if (blocks.len == 0) return .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
    var box = blocks[0].bbox;
    for (blocks[1..]) |block| box = unionBox(box, block.bbox);
    return box;
}

fn stripListPrefix(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    if (i < text.len and (text[i] == '-' or text[i] == '*' or text[i] == '+')) i += 1;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return text[i..];
}

fn writeSpanJson(writer: anytype, span: ReconciledSpan) !void {
    try writer.writeAll("{\"page\":");
    try writer.print("{d}", .{span.span.page_index + 1});
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, span.span.bbox);
    try writer.writeAll(",\"text\":\"");
    try writeJsonEscaped(writer, span.span.text);
    try writer.writeAll("\",\"chosen_source\":\"");
    try writer.writeAll(sourceKindName(span.chosen_source));
    try writer.writeAll("\",\"sources\":\"");
    try writer.writeAll(sourceMaskName(span.source_mask));
    try writer.writeAll("\",\"confidence\":");
    try writer.print("{d:.3}", .{span.confidence});
    try writer.writeAll(",\"duplicate_count\":");
    try writer.print("{d}", .{span.duplicate_count});
    if (span.span.mcid) |mcid| {
        try writer.writeAll(",\"mcid\":");
        try writer.print("{d}", .{mcid});
    }
    try writer.writeByte('}');
}

fn writeBlockJson(writer: anytype, block: ReconciledBlock) !void {
    try writer.writeAll("{\"id\":");
    try writer.print("{d}", .{block.id});
    try writer.writeAll(",\"page\":");
    try writer.print("{d}", .{block.page_index + 1});
    try writer.writeAll(",\"kind\":\"");
    try writer.writeAll(blockKindName(block.kind));
    try writer.writeAll("\",\"bbox\":");
    try writeBBoxJson(writer, block.bbox);
    try writer.writeAll(",\"text\":\"");
    try writeJsonEscaped(writer, block.text);
    try writer.writeAll("\",\"sources\":\"");
    try writer.writeAll(sourceMaskName(block.source_mask));
    try writer.writeAll("\",\"confidence\":");
    try writer.print("{d:.3}", .{block.confidence});
    try writer.writeAll(",\"span_start\":");
    try writer.print("{d}", .{block.span_start});
    try writer.writeAll(",\"span_count\":");
    try writer.print("{d}", .{block.span_count});
    try writer.writeByte('}');
}

fn writeChunkJson(writer: anytype, chunk: RagChunk) !void {
    try writer.writeAll("{\"source_id\":\"");
    try writeJsonEscaped(writer, chunk.source_id);
    try writer.writeAll("\",\"chunk_index\":");
    try writer.print("{d}", .{chunk.chunk_index});
    try writer.writeAll(",\"content\":\"");
    try writeJsonEscaped(writer, chunk.content);
    try writer.writeAll("\",\"page_start\":");
    try writer.print("{d}", .{chunk.page_start + 1});
    try writer.writeAll(",\"page_end\":");
    try writer.print("{d}", .{chunk.page_end + 1});
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, chunk.bbox);
    try writer.writeAll(",\"sources\":\"");
    try writer.writeAll(sourceMaskName(chunk.source_mask));
    try writer.writeAll("\",\"confidence\":");
    try writer.print("{d:.3}", .{chunk.confidence});
    try writer.writeByte('}');
}

fn writeRagChunkJsonl(writer: anytype, chunk: RagChunk) !void {
    try writer.writeAll("{\"source_id\":\"");
    try writeJsonEscaped(writer, chunk.source_id);
    try writer.writeAll("\",\"chunk_index\":");
    try writer.print("{d}", .{chunk.chunk_index});
    try writer.writeAll(",\"content\":\"");
    try writeJsonEscaped(writer, chunk.content);
    try writer.writeAll("\",\"embedding\":null,\"metadata\":{\"page_start\":");
    try writer.print("{d}", .{chunk.page_start + 1});
    try writer.writeAll(",\"page_end\":");
    try writer.print("{d}", .{chunk.page_end + 1});
    try writer.writeAll(",\"bbox\":");
    try writeBBoxJson(writer, chunk.bbox);
    try writer.writeAll(",\"block_start\":");
    try writer.print("{d}", .{chunk.block_start});
    try writer.writeAll(",\"block_count\":");
    try writer.print("{d}", .{chunk.block_count});
    try writer.writeAll(",\"sources\":\"");
    try writer.writeAll(sourceMaskName(chunk.source_mask));
    try writer.writeAll("\",\"confidence\":");
    try writer.print("{d:.3}", .{chunk.confidence});
    try writer.writeAll("}}");
}

fn writeBBoxJson(writer: anytype, box: BBox) !void {
    try writer.print("[{d:.2},{d:.2},{d:.2},{d:.2}]", .{ box.x0, box.y0, box.x1, box.y1 });
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

fn writeHtmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(byte),
    };
}

fn writeXmlEscaped(writer: anytype, text: []const u8) !void {
    try writeHtmlEscaped(writer, text);
}

fn testSpan(
    text: []const u8,
    source: SourceKind,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
) TextSpan {
    return TextSpan.init(.{
        .page_index = 0,
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .source = source,
        .confidence = 0.95,
        .font = .{ .size = y1 - y0 },
    });
}

test "reconciler deduplicates same text and preserves provenance" {
    const native = [_]TextSpan{
        testSpan("Total", .native_pdf, 10, 700, 50, 712),
    };
    const ocr = [_]TextSpan{
        testSpan(" Total ", .fresh_ocr, 10.5, 700, 50.5, 712),
    };

    var doc = try reconcile(std.testing.allocator, &.{
        .{ .source = .native_pdf, .spans = &native },
        .{ .source = .fresh_ocr, .spans = &ocr },
    }, .{});
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.spans.len);
    try std.testing.expect(hasSource(doc.spans[0].source_mask, .native_pdf));
    try std.testing.expect(hasSource(doc.spans[0].source_mask, .fresh_ocr));
    try std.testing.expectEqual(SourceKind.native_pdf, doc.spans[0].chosen_source);
    try std.testing.expectEqual(@as(u32, 1), doc.spans[0].duplicate_count);
}

test "reconciler emits specialist blocks and rag jsonl chunks" {
    const table = [_]TextSpan{
        testSpan("Year Revenue\n2025 42", .table_model, 20, 650, 180, 690),
    };
    const formula = [_]TextSpan{
        testSpan("E = mc^2", .formula_model, 20, 600, 90, 615),
    };

    var doc = try reconcile(std.testing.allocator, &.{
        .{ .source = .table_model, .spans = &table },
        .{ .source = .formula_model, .spans = &formula },
    }, .{ .default_chunk_source_id = "fixture.pdf", .max_chunk_bytes = 64 });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqual(BlockKind.table_candidate, doc.blocks[0].kind);
    try std.testing.expectEqual(BlockKind.formula_candidate, doc.blocks[1].kind);

    const md = try renderMarkdown(std.testing.allocator, &doc);
    defer std.testing.allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "```table") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "```math") != null);

    const jsonl = try renderRagJsonl(std.testing.allocator, &doc);
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"source_id\":\"fixture.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"embedding\":null") != null);
}

test "coordinate serializers include hocr alto and debug overlay" {
    const native = [_]TextSpan{
        testSpan("Hello <PDF>", .native_pdf, 10, 700, 80, 712),
    };
    var doc = try reconcile(std.testing.allocator, &.{
        .{ .source = .native_pdf, .spans = &native },
    }, .{});
    defer doc.deinit();

    const json = try renderJson(std.testing.allocator, &doc);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "Hello <PDF>") != null);

    const hocr = try renderHocr(std.testing.allocator, &doc);
    defer std.testing.allocator.free(hocr);
    try std.testing.expect(std.mem.indexOf(u8, hocr, "ocr_page") != null);
    try std.testing.expect(std.mem.indexOf(u8, hocr, "Hello &lt;PDF&gt;") != null);

    const alto = try renderAlto(std.testing.allocator, &doc);
    defer std.testing.allocator.free(alto);
    try std.testing.expect(std.mem.indexOf(u8, alto, "<alto>") != null);
    try std.testing.expect(std.mem.indexOf(u8, alto, "Hello &lt;PDF&gt;") != null);

    const svg = try renderDebugSvg(std.testing.allocator, &doc);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<rect") != null);
}
