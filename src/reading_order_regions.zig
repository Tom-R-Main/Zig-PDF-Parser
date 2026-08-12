//! Hierarchical, page-local regions for reading-order experiments.
//!
//! The ordinary layout layer deliberately exposes flat blocks. Reading-order
//! diagnostics need the earlier geometric substrate because a coarse line
//! threshold can fuse independent columns before a graph sees them. This module
//! groups coherent source lines inside stable horizontal flows while retaining
//! an explicit root -> flow -> block hierarchy.

const std = @import("std");
const layout = @import("layout.zig");

pub const max_blocks: usize = 4096;

pub const RegionKind = enum(u8) {
    root,
    flow,
    block,
};

pub const RegionNode = struct {
    id: u32,
    parent_id: ?u32,
    kind: RegionKind,
    bounds: layout.BBox,
    source_span_count: usize,
    source_span_indices: []const u32,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    nodes: []const RegionNode,
    blocks: []const layout.LayoutBlock,

    pub fn deinit(self: *Result) void {
        for (self.nodes) |node| {
            if (node.source_span_indices.len > 0) self.allocator.free(node.source_span_indices);
        }
        self.allocator.free(self.nodes);
        freeBlockItems(self.allocator, self.blocks);
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

const Flow = struct {
    anchor_x: f64,
    source_span_indices: std.ArrayList(u32) = .empty,

    fn deinit(self: *Flow, allocator: std.mem.Allocator) void {
        self.source_span_indices.deinit(allocator);
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    page_layout: *const layout.LayoutResult,
) !Result {
    var unique_span_indices: std.ArrayList(u32) = .empty;
    defer unique_span_indices.deinit(allocator);
    for (page_layout.spans, 0..) |span, span_index| {
        if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) continue;
        if (span.x1 <= span.x0 or span.y1 <= span.y0) continue;
        if (isExactDuplicate(page_layout.spans, unique_span_indices.items, span)) continue;
        try unique_span_indices.append(allocator, @intCast(span_index));
    }

    if (unique_span_indices.items.len == 0) {
        return .{
            .allocator = allocator,
            .nodes = try allocator.alloc(RegionNode, 0),
            .blocks = try allocator.alloc(layout.LayoutBlock, 0),
        };
    }

    const body_height = try medianSpanHeight(allocator, page_layout.spans, unique_span_indices.items);
    const x_tolerance = @max(1.0, page_layout.body_font_size * 0.25);

    std.mem.sort(u32, unique_span_indices.items, page_layout.spans, sourceXLessThan);
    var flows: std.ArrayList(Flow) = .empty;
    defer {
        for (flows.items) |*flow| flow.deinit(allocator);
        flows.deinit(allocator);
    }
    for (unique_span_indices.items) |span_index| {
        const span = page_layout.spans[span_index];
        var flow_index: ?usize = null;
        for (flows.items, 0..) |flow, candidate_index| {
            if (@abs(flow.anchor_x - span.x0) <= x_tolerance) {
                flow_index = candidate_index;
                break;
            }
        }
        if (flow_index) |index| {
            try flows.items[index].source_span_indices.append(allocator, span_index);
        } else {
            var indices: std.ArrayList(u32) = .empty;
            errdefer indices.deinit(allocator);
            try indices.append(allocator, span_index);
            try flows.append(allocator, .{
                .anchor_x = span.x0,
                .source_span_indices = indices,
            });
        }
    }
    std.mem.sort(Flow, flows.items, {}, flowLessThan);

    var nodes: std.ArrayList(RegionNode) = .empty;
    var blocks: std.ArrayList(layout.LayoutBlock) = .empty;
    var transferred = false;
    defer if (!transferred) {
        freeNodeItems(allocator, nodes.items);
        nodes.deinit(allocator);
        freeBlockItems(allocator, blocks.items);
        blocks.deinit(allocator);
    };

    try nodes.append(allocator, .{
        .id = 0,
        .parent_id = null,
        .kind = .root,
        .bounds = boundsForIndices(page_layout.spans, unique_span_indices.items),
        .source_span_count = unique_span_indices.items.len,
        .source_span_indices = &.{},
    });

    for (flows.items, 0..) |*flow, column_index| {
        std.mem.sort(u32, flow.source_span_indices.items, page_layout.spans, sourceVisualLessThan);
        const flow_node_id: u32 = @intCast(nodes.items.len);
        try nodes.append(allocator, .{
            .id = flow_node_id,
            .parent_id = 0,
            .kind = .flow,
            .bounds = boundsForIndices(page_layout.spans, flow.source_span_indices.items),
            .source_span_count = flow.source_span_indices.items.len,
            .source_span_indices = &.{},
        });

        const line_step = medianLineStep(
            allocator,
            page_layout.spans,
            flow.source_span_indices.items,
            page_layout.body_font_size,
        ) catch |err| switch (err) {
            error.NoLineStep => @max(1.0, page_layout.body_font_size),
            else => return err,
        };
        var group_start: usize = 0;
        var span_offset: usize = 1;
        while (span_offset <= flow.source_span_indices.items.len) : (span_offset += 1) {
            const at_end = span_offset == flow.source_span_indices.items.len;
            const split = if (at_end)
                true
            else
                shouldSplitBlock(
                    page_layout.spans[flow.source_span_indices.items[span_offset - 1]],
                    page_layout.spans[flow.source_span_indices.items[span_offset]],
                    line_step,
                    body_height,
                    page_layout.body_font_size,
                );
            if (!split) continue;

            const group = flow.source_span_indices.items[group_start..span_offset];
            if (blocks.items.len == max_blocks) return error.RegionTreeTooLarge;
            const block = try makeBlock(
                allocator,
                page_layout.spans,
                group,
                @intCast(column_index),
                body_height,
            );
            var block_transferred = false;
            defer if (!block_transferred) freeBlockItem(allocator, block);
            try blocks.append(allocator, block);
            block_transferred = true;

            const owned_indices = try allocator.dupe(u32, group);
            var indices_transferred = false;
            defer if (!indices_transferred) allocator.free(owned_indices);
            try nodes.append(allocator, .{
                .id = @intCast(nodes.items.len),
                .parent_id = flow_node_id,
                .kind = .block,
                .bounds = block.bounds.bbox,
                .source_span_count = group.len,
                .source_span_indices = owned_indices,
            });
            indices_transferred = true;
            group_start = span_offset;
        }
    }

    const owned_nodes = try nodes.toOwnedSlice(allocator);
    errdefer {
        freeNodeItems(allocator, owned_nodes);
        allocator.free(owned_nodes);
    }
    const owned_blocks = try blocks.toOwnedSlice(allocator);
    transferred = true;
    return .{
        .allocator = allocator,
        .nodes = owned_nodes,
        .blocks = owned_blocks,
    };
}

fn isExactDuplicate(spans: []const layout.TextSpan, accepted: []const u32, candidate: layout.TextSpan) bool {
    for (accepted) |span_index| {
        const prior = spans[span_index];
        if (!std.mem.eql(u8, prior.text, candidate.text)) continue;
        if (@abs(prior.x0 - candidate.x0) <= 0.001 and
            @abs(prior.y0 - candidate.y0) <= 0.001 and
            @abs(prior.x1 - candidate.x1) <= 0.001 and
            @abs(prior.y1 - candidate.y1) <= 0.001)
        {
            return true;
        }
    }
    return false;
}

fn medianSpanHeight(allocator: std.mem.Allocator, spans: []const layout.TextSpan, indices: []const u32) !f64 {
    const heights = try allocator.alloc(f64, indices.len);
    defer allocator.free(heights);
    for (indices, 0..) |span_index, index| heights[index] = spans[span_index].y1 - spans[span_index].y0;
    std.mem.sort(f64, heights, {}, comptime std.sort.asc(f64));
    return heights[(heights.len - 1) / 2];
}

fn medianLineStep(
    allocator: std.mem.Allocator,
    spans: []const layout.TextSpan,
    indices: []const u32,
    body_font_size: f64,
) !f64 {
    var steps: std.ArrayList(f64) = .empty;
    defer steps.deinit(allocator);
    for (indices[0..indices.len -| 1], indices[1..]) |upper_index, lower_index| {
        const step = spans[upper_index].y0 - spans[lower_index].y0;
        if (step <= @max(0.20, body_font_size * 0.20) or step >= @max(4.0, body_font_size * 4.0)) continue;
        try steps.append(allocator, step);
    }
    if (steps.items.len == 0) return error.NoLineStep;
    std.mem.sort(f64, steps.items, {}, comptime std.sort.asc(f64));
    return steps.items[(steps.items.len - 1) / 2];
}

fn shouldSplitBlock(
    previous: layout.TextSpan,
    current: layout.TextSpan,
    line_step: f64,
    body_height: f64,
    body_font_size: f64,
) bool {
    const vertical_step = previous.y0 - current.y0;
    const gap_limit = @max(line_step * 1.38, @max(0.75, body_font_size * 0.75));
    if (vertical_step > gap_limit or vertical_step < -0.10) return true;

    const previous_height = previous.y1 - previous.y0;
    const current_height = current.y1 - current.y0;
    const min_height = @max(0.01, @min(previous_height, current_height));
    if (@max(previous_height, current_height) / min_height >= 1.35) return true;

    const previous_emphasized = previous_height >= body_height * 1.18;
    const current_emphasized = current_height >= body_height * 1.18;
    return previous_emphasized != current_emphasized;
}

fn makeBlock(
    allocator: std.mem.Allocator,
    spans: []const layout.TextSpan,
    indices: []const u32,
    column_index: u32,
    body_height: f64,
) !layout.LayoutBlock {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var max_height: f64 = 0;
    var common_mcid: ?i32 = spans[indices[0]].mcid;
    for (indices) |span_index| {
        const span = spans[span_index];
        const trimmed = std.mem.trim(u8, span.text, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (text.items.len > 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, trimmed);
        max_height = @max(max_height, span.y1 - span.y0);
        if (common_mcid != span.mcid) common_mcid = null;
    }
    const owned_text = try text.toOwnedSlice(allocator);
    errdefer allocator.free(owned_text);
    const bounds = boundsForIndices(spans, indices);
    const representative = spans[indices[0]];
    const synthetic_span = layout.TextSpan.init(.{
        .page_index = representative.page_index,
        .bbox = bounds,
        .text = owned_text,
        .source = representative.source,
        .confidence = representative.confidence,
        .font = .{ .size = representative.font_size },
        .mcid = common_mcid,
        .writing_mode = representative.writing_mode,
    });
    const leaf_spans = try allocator.alloc(layout.TextSpan, 1);
    errdefer allocator.free(leaf_spans);
    leaf_spans[0] = synthetic_span;
    const words = try allocator.alloc(layout.TextWord, 1);
    errdefer allocator.free(words);
    words[0] = .{ .bounds = synthetic_span, .spans = leaf_spans };
    const lines = try allocator.alloc(layout.TextLine, 1);
    errdefer allocator.free(lines);
    const kind: layout.BlockKind = if (max_height >= body_height * 1.18 and owned_text.len <= 240)
        .heading
    else
        .paragraph;
    lines[0] = .{
        .bounds = synthetic_span,
        .words = words,
        .baseline_y = representative.y0,
        .role = if (kind == .heading) .heading else .body,
    };
    return .{
        .bounds = synthetic_span,
        .lines = lines,
        .column_index = column_index,
        .kind = kind,
        .confidence = 0.78,
        .removed = false,
    };
}

fn boundsForIndices(spans: []const layout.TextSpan, indices: []const u32) layout.BBox {
    var bounds = spans[indices[0]].bbox;
    for (indices[1..]) |span_index| bounds = unionBox(bounds, spans[span_index].bbox);
    return bounds;
}

fn unionBox(left: layout.BBox, right: layout.BBox) layout.BBox {
    return .{
        .x0 = @min(left.x0, right.x0),
        .y0 = @min(left.y0, right.y0),
        .x1 = @max(left.x1, right.x1),
        .y1 = @max(left.y1, right.y1),
    };
}

fn sourceXLessThan(spans: []const layout.TextSpan, left_index: u32, right_index: u32) bool {
    const left = spans[left_index];
    const right = spans[right_index];
    if (left.x0 != right.x0) return left.x0 < right.x0;
    if (left.y0 != right.y0) return left.y0 > right.y0;
    return left_index < right_index;
}

fn sourceVisualLessThan(spans: []const layout.TextSpan, left_index: u32, right_index: u32) bool {
    const left = spans[left_index];
    const right = spans[right_index];
    if (left.y0 != right.y0) return left.y0 > right.y0;
    if (left.x0 != right.x0) return left.x0 < right.x0;
    return left_index < right_index;
}

fn flowLessThan(_: void, left: Flow, right: Flow) bool {
    return left.anchor_x < right.anchor_x;
}

fn freeNodeItems(allocator: std.mem.Allocator, nodes: []const RegionNode) void {
    for (nodes) |node| {
        if (node.source_span_indices.len > 0) allocator.free(node.source_span_indices);
    }
}

fn freeBlockItems(allocator: std.mem.Allocator, blocks: []const layout.LayoutBlock) void {
    for (blocks) |block| freeBlockItem(allocator, block);
}

fn freeBlockItem(allocator: std.mem.Allocator, block: layout.LayoutBlock) void {
    if (block.lines.len == 0) return;
    const line = block.lines[0];
    if (line.words.len > 0) {
        if (line.words[0].spans.len > 0) allocator.free(@constCast(line.words[0].spans[0].text));
        allocator.free(line.words[0].spans);
    }
    allocator.free(line.words);
    allocator.free(block.lines);
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) layout.TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .size = 1 },
    });
}

fn testLayout(allocator: std.mem.Allocator, spans: []const layout.TextSpan) layout.LayoutResult {
    return .{
        .spans = spans,
        .lines = &.{},
        .columns = &.{},
        .paragraphs = &.{},
        .blocks = &.{},
        .tables = &.{},
        .candidates = &.{},
        .reading_order = &.{},
        .body_font_size = 1,
        .allocator = allocator,
    };
}

test "hierarchy separates aligned flows and paragraph gaps" {
    const spans = [_]layout.TextSpan{
        testSpan("Left heading", 10, 90.0, 60, 102.0),
        testSpan("Left body one", 10, 84.0, 80, 94.0),
        testSpan("continues", 10, 82.8, 55, 92.8),
        testSpan("New paragraph", 10, 80.9, 75, 90.9),
        testSpan("Right body", 120, 84.0, 180, 94.0),
        testSpan("continues", 120, 82.8, 160, 92.8),
    };
    const page_layout = testLayout(std.testing.allocator, &spans);
    var result = try build(std.testing.allocator, &page_layout);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.blocks.len);
    try std.testing.expectEqualStrings("Left heading", result.blocks[0].bounds.text);
    try std.testing.expectEqualStrings("Left body one continues", result.blocks[1].bounds.text);
    try std.testing.expectEqualStrings("New paragraph", result.blocks[2].bounds.text);
    try std.testing.expectEqualStrings("Right body continues", result.blocks[3].bounds.text);
    try std.testing.expectEqual(@as(usize, 7), result.nodes.len);
}

test "hierarchy removes exact duplicate source spans" {
    const spans = [_]layout.TextSpan{
        testSpan("Footer", 10, 10, 40, 20),
        testSpan("Footer", 10, 10, 40, 20),
    };
    const page_layout = testLayout(std.testing.allocator, &spans);
    var result = try build(std.testing.allocator, &page_layout);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    try std.testing.expectEqualStrings("Footer", result.blocks[0].bounds.text);
}

test "hierarchy construction cleans up every allocation failure" {
    const spans = [_]layout.TextSpan{
        testSpan("First line", 10, 90.0, 60, 100.0),
        testSpan("Second line", 10, 88.8, 65, 98.8),
        testSpan("Other flow", 120, 90.0, 180, 100.0),
    };
    const page_layout = testLayout(std.testing.allocator, &spans);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, source: *const layout.LayoutResult) !void {
            var result = try build(allocator, source);
            result.deinit();
        }
    }.run, .{&page_layout});
}
