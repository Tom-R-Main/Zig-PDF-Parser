const std = @import("std");
const layout = @import("layout.zig");

pub const NodeId = u32;
pub const EvidenceMask = u16;

pub const max_nodes: usize = 4096;
pub const max_edges_per_node: usize = 8;

pub const Relation = enum(u8) {
    precedes,
    caption_of,
    footnote_of,
};

pub const EvidenceKind = enum(u4) {
    structure_tree,
    same_column_successor,
    column_transition,
    spanning_heading,
    sidebar_anchor,
    caption_candidate,
    footnote_marker,

    pub fn mask(self: EvidenceKind) EvidenceMask {
        return @as(EvidenceMask, 1) << @intFromEnum(self);
    }
};

pub const BlockNode = struct {
    id: NodeId,
    page_index: u32,
    original_block_index: u32,
    original_position: u32,
    bounds: layout.BBox,
    kind: layout.BlockKind,
    column_index: u32,
    mcids: []const i32,
};

pub const GraphEdge = struct {
    source: NodeId,
    target: NodeId,
    relation: Relation,
    confidence: f32,
    evidence: EvidenceMask,
    hard: bool = false,
};

pub const RejectedReason = enum(u8) {
    cycle,
};

pub const RejectedEdge = struct {
    edge: GraphEdge,
    reason: RejectedReason,
};

pub const FallbackReason = enum(u8) {
    none,
    too_many_nodes,
    too_many_edges,
    hard_cycle,
    projection_cycle,
};

pub const BuildOptions = struct {
    structure_mcid_order: []const i32 = &.{},
    include_structure: bool = true,
    structure_is_hard: bool = true,
    include_semantics: bool = true,
    include_geometry: bool = true,
};

pub const PageReadingOrderGraph = struct {
    nodes: []const BlockNode,
    edges: []const GraphEdge,
    rejected_edges: []const RejectedEdge,
    projected_block_order: []const u32,
    validity: bool,
    fallback: FallbackReason,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PageReadingOrderGraph) void {
        for (self.nodes) |node| self.allocator.free(node.mcids);
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
        self.allocator.free(self.rejected_edges);
        self.allocator.free(self.projected_block_order);
        self.* = undefined;
    }

    pub fn hasEvidence(self: *const PageReadingOrderGraph, kind: EvidenceKind) bool {
        for (self.edges) |edge| {
            if (edge.evidence & kind.mask() != 0) return true;
        }
        return false;
    }
};

/// Builds an owned, page-local graph over the live blocks in `layout_result`.
/// The layout result and the optional structure MCID sequence are borrowed only
/// for the duration of this call.
pub fn build(
    allocator: std.mem.Allocator,
    page_index: u32,
    layout_result: *const layout.LayoutResult,
    options: BuildOptions,
) !PageReadingOrderGraph {
    return buildFromParts(
        allocator,
        page_index,
        layout_result.blocks,
        layout_result.candidates,
        layout_result.body_font_size,
        options,
    );
}

fn buildFromParts(
    allocator: std.mem.Allocator,
    page_index: u32,
    blocks: []const layout.LayoutBlock,
    candidates: []const layout.LayoutCandidate,
    body_font_size: f64,
    options: BuildOptions,
) !PageReadingOrderGraph {
    var nodes: std.ArrayList(BlockNode) = .empty;
    var edges: std.ArrayList(GraphEdge) = .empty;
    var rejected: std.ArrayList(RejectedEdge) = .empty;
    var projected: std.ArrayList(u32) = .empty;
    var soft_edges: std.ArrayList(GraphEdge) = .empty;
    var transferred = false;
    defer if (!transferred) {
        freeNodeItems(allocator, nodes.items);
        nodes.deinit(allocator);
        edges.deinit(allocator);
        rejected.deinit(allocator);
        projected.deinit(allocator);
        soft_edges.deinit(allocator);
    };

    for (blocks, 0..) |block, block_index| {
        if (block.removed or block.lines.len == 0) continue;
        if (nodes.items.len == max_nodes) {
            soft_edges.deinit(allocator);
            soft_edges = .empty;
            const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, false, .too_many_nodes);
            transferred = true;
            return graph;
        }

        const mcids = try collectMcids(allocator, block);
        nodes.append(allocator, .{
            .id = @intCast(nodes.items.len),
            .page_index = page_index,
            .original_block_index = @intCast(block_index),
            .original_position = @intCast(block_index),
            .bounds = block.bounds.bbox,
            .kind = block.kind,
            .column_index = block.column_index,
            .mcids = mcids,
        }) catch |err| {
            allocator.free(mcids);
            return err;
        };
    }

    const visited = try allocator.alloc(bool, nodes.items.len);
    defer allocator.free(visited);
    const stack = try allocator.alloc(NodeId, nodes.items.len);
    defer allocator.free(stack);
    const outgoing = try allocator.alloc(u8, nodes.items.len);
    defer allocator.free(outgoing);
    @memset(outgoing, 0);

    if (options.include_structure) {
        var previous: ?NodeId = null;
        for (options.structure_mcid_order) |mcid| {
            const current = uniqueNodeForMcid(nodes.items, mcid) orelse continue;
            if (previous) |source| {
                if (source != current) {
                    const edge: GraphEdge = .{
                        .source = source,
                        .target = current,
                        .relation = .precedes,
                        .confidence = 1.0,
                        .evidence = EvidenceKind.structure_tree.mask(),
                        .hard = options.structure_is_hard,
                    };
                    if (edge.hard) {
                        if (wouldCreateCycle(edges.items, edge.source, edge.target, visited, stack)) {
                            soft_edges.deinit(allocator);
                            soft_edges = .empty;
                            const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, false, .hard_cycle);
                            transferred = true;
                            return graph;
                        }
                        const inserted = try mergeOrAppendEdge(allocator, &edges, edge);
                        if (inserted and !incrementWithinBound(outgoing, edge.source)) {
                            soft_edges.deinit(allocator);
                            soft_edges = .empty;
                            const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, false, .too_many_edges);
                            transferred = true;
                            return graph;
                        }
                    } else {
                        try mergeOrAppendProposal(allocator, &soft_edges, edge);
                    }
                }
            }
            previous = current;
        }
    }

    if (options.include_semantics) {
        try appendCaptionEvidence(allocator, nodes.items, candidates, &soft_edges);
        try appendFootnoteEvidence(allocator, nodes.items, blocks, body_font_size, &soft_edges);
    }
    if (options.include_geometry) {
        try appendGeometryEvidence(allocator, nodes.items, &soft_edges);
    }

    std.mem.sort(GraphEdge, soft_edges.items, {}, softEdgeLessThan);
    for (soft_edges.items) |edge| {
        if (edge.relation == .precedes and wouldCreateCycle(edges.items, edge.source, edge.target, visited, stack)) {
            try rejected.append(allocator, .{ .edge = edge, .reason = .cycle });
            continue;
        }
        const inserted = try mergeOrAppendEdge(allocator, &edges, edge);
        if (inserted and !incrementWithinBound(outgoing, edge.source)) {
            soft_edges.deinit(allocator);
            soft_edges = .empty;
            const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, false, .too_many_edges);
            transferred = true;
            return graph;
        }
    }
    soft_edges.deinit(allocator);
    soft_edges = .empty;

    if (!try projectStable(allocator, nodes.items, edges.items, &projected)) {
        const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, false, .projection_cycle);
        transferred = true;
        return graph;
    }

    const graph = try finishGraph(allocator, &nodes, &edges, &rejected, &projected, true, .none);
    transferred = true;
    return graph;
}

fn finishGraph(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(BlockNode),
    edges: *std.ArrayList(GraphEdge),
    rejected: *std.ArrayList(RejectedEdge),
    projected: *std.ArrayList(u32),
    validity: bool,
    fallback: FallbackReason,
) !PageReadingOrderGraph {
    const owned_nodes = try nodes.toOwnedSlice(allocator);
    errdefer freeOwnedNodes(allocator, owned_nodes);
    const owned_edges = try edges.toOwnedSlice(allocator);
    errdefer allocator.free(owned_edges);
    const owned_rejected = try rejected.toOwnedSlice(allocator);
    errdefer allocator.free(owned_rejected);
    const owned_projected = try projected.toOwnedSlice(allocator);
    errdefer allocator.free(owned_projected);
    return .{
        .nodes = owned_nodes,
        .edges = owned_edges,
        .rejected_edges = owned_rejected,
        .projected_block_order = owned_projected,
        .validity = validity,
        .fallback = fallback,
        .allocator = allocator,
    };
}

fn freeNodeItems(allocator: std.mem.Allocator, nodes: []BlockNode) void {
    for (nodes) |node| allocator.free(node.mcids);
}

fn freeOwnedNodes(allocator: std.mem.Allocator, nodes: []BlockNode) void {
    freeNodeItems(allocator, nodes);
    allocator.free(nodes);
}

fn collectMcids(allocator: std.mem.Allocator, block: layout.LayoutBlock) ![]const i32 {
    var mcids: std.ArrayList(i32) = .empty;
    defer mcids.deinit(allocator);

    try appendUniqueMcid(allocator, &mcids, block.bounds.mcid);
    for (block.lines) |line| {
        try appendUniqueMcid(allocator, &mcids, line.bounds.mcid);
        for (line.words) |word| {
            try appendUniqueMcid(allocator, &mcids, word.bounds.mcid);
            for (word.spans) |span| try appendUniqueMcid(allocator, &mcids, span.mcid);
        }
    }
    std.mem.sort(i32, mcids.items, {}, comptime std.sort.asc(i32));
    return mcids.toOwnedSlice(allocator);
}

fn appendUniqueMcid(allocator: std.mem.Allocator, mcids: *std.ArrayList(i32), maybe_mcid: ?i32) !void {
    const mcid = maybe_mcid orelse return;
    for (mcids.items) |existing| {
        if (existing == mcid) return;
    }
    try mcids.append(allocator, mcid);
}

fn uniqueNodeForMcid(nodes: []const BlockNode, mcid: i32) ?NodeId {
    var found: ?NodeId = null;
    for (nodes) |node| {
        if (std.mem.indexOfScalar(i32, node.mcids, mcid) != null) {
            if (found != null) return null;
            found = node.id;
        }
    }
    return found;
}

fn appendCaptionEvidence(
    allocator: std.mem.Allocator,
    nodes: []const BlockNode,
    candidates: []const layout.LayoutCandidate,
    proposals: *std.ArrayList(GraphEdge),
) !void {
    for (candidates) |candidate| {
        const anchor_block = candidate.block_index orelse continue;
        const caption_block = candidate.caption_block_index orelse continue;
        const anchor = nodeForBlock(nodes, anchor_block) orelse continue;
        const caption = nodeForBlock(nodes, caption_block) orelse continue;
        if (anchor == caption) continue;

        const evidence = EvidenceKind.caption_candidate.mask();
        try mergeOrAppendProposal(allocator, proposals, .{
            .source = caption,
            .target = anchor,
            .relation = .caption_of,
            .confidence = 0.90,
            .evidence = evidence,
        });
        try mergeOrAppendProposal(allocator, proposals, .{
            .source = anchor,
            .target = caption,
            .relation = .precedes,
            .confidence = 0.90,
            .evidence = evidence,
        });
    }
}

fn appendFootnoteEvidence(
    allocator: std.mem.Allocator,
    nodes: []const BlockNode,
    blocks: []const layout.LayoutBlock,
    body_font_size: f64,
    proposals: *std.ArrayList(GraphEdge),
) !void {
    if (nodes.len < 2 or body_font_size <= 0) return;
    var min_y = nodes[0].bounds.y0;
    var max_y = nodes[0].bounds.y1;
    for (nodes[1..]) |node| {
        min_y = @min(min_y, node.bounds.y0);
        max_y = @max(max_y, node.bounds.y1);
    }
    const bottom_limit = min_y + (max_y - min_y) * 0.20;

    for (nodes) |footnote_node| {
        const block = blocks[footnote_node.original_block_index];
        if (footnote_node.bounds.y1 > bottom_limit) continue;
        if (block.bounds.font_size >= body_font_size * 0.90) continue;
        const marker = firstMarker(block) orelse continue;

        var anchor: ?NodeId = null;
        var ambiguous = false;
        for (nodes) |candidate| {
            if (candidate.id == footnote_node.id or candidate.bounds.y0 <= footnote_node.bounds.y0) continue;
            if (!blockContainsMarker(blocks[candidate.original_block_index], marker)) continue;
            if (anchor != null) {
                ambiguous = true;
                break;
            }
            anchor = candidate.id;
        }
        if (ambiguous or anchor == null) continue;

        const evidence = EvidenceKind.footnote_marker.mask();
        try mergeOrAppendProposal(allocator, proposals, .{
            .source = footnote_node.id,
            .target = anchor.?,
            .relation = .footnote_of,
            .confidence = 0.90,
            .evidence = evidence,
        });
        try mergeOrAppendProposal(allocator, proposals, .{
            .source = anchor.?,
            .target = footnote_node.id,
            .relation = .precedes,
            .confidence = 0.90,
            .evidence = evidence,
        });
    }
}

fn firstMarker(block: layout.LayoutBlock) ?[]const u8 {
    if (block.lines.len == 0 or block.lines[0].words.len == 0) return null;
    const text = std.mem.trim(u8, block.lines[0].words[0].bounds.text, " \t\r\n");
    if (text.len == 0) return null;
    if (text[0] == '*') return text[0..1];
    if (std.mem.startsWith(u8, text, "†") or std.mem.startsWith(u8, text, "‡")) return text[0..3];

    var offset: usize = @intFromBool(text[0] == '[' or text[0] == '(');
    const digit_start = offset;
    while (offset < text.len and offset - digit_start < 3 and std.ascii.isDigit(text[offset])) : (offset += 1) {}
    if (offset == digit_start) return null;
    if (offset < text.len and (text[offset] == ']' or text[offset] == ')' or text[offset] == '.')) {
        offset += 1;
    }
    if (offset < text.len and !std.ascii.isWhitespace(text[offset])) return null;
    return text[0..offset];
}

fn blockContainsMarker(block: layout.LayoutBlock, marker: []const u8) bool {
    for (block.lines) |line| {
        for (line.words) |word| {
            const text = std.mem.trim(u8, word.bounds.text, " \t\r\n");
            var search_start: usize = 0;
            while (std.mem.indexOfPos(u8, text, search_start, marker)) |offset| {
                const before_boundary = offset == 0 or std.ascii.isWhitespace(text[offset - 1]);
                const after = offset + marker.len;
                const after_boundary = after == text.len or std.ascii.isWhitespace(text[after]);
                if (before_boundary and after_boundary) return true;
                search_start = offset + 1;
            }
        }
    }
    return false;
}

fn appendGeometryEvidence(
    allocator: std.mem.Allocator,
    nodes: []const BlockNode,
    proposals: *std.ArrayList(GraphEdge),
) !void {
    if (nodes.len < 2) return;

    // Connect only immediate visual successors within a column. This keeps the
    // partial order sparse and avoids inventing relations between side material.
    for (nodes) |source| {
        var successor: ?BlockNode = null;
        for (nodes) |candidate| {
            if (candidate.id == source.id or candidate.column_index != source.column_index) continue;
            if (!visualLessThan({}, source, candidate)) continue;
            if (successor == null or visualLessThan({}, candidate, successor.?)) successor = candidate;
        }
        if (successor) |target| {
            try mergeOrAppendProposal(allocator, proposals, .{
                .source = source.id,
                .target = target.id,
                .relation = .precedes,
                .confidence = 0.80,
                .evidence = EvidenceKind.same_column_successor.mask(),
            });
        }
    }

    var columns: std.ArrayList(u32) = .empty;
    defer columns.deinit(allocator);
    for (nodes) |node| {
        var seen = false;
        for (columns.items) |column| {
            if (column == node.column_index) {
                seen = true;
                break;
            }
        }
        if (!seen) try columns.append(allocator, node.column_index);
    }
    std.mem.sort(u32, columns.items, {}, comptime std.sort.asc(u32));
    for (columns.items[0 .. columns.items.len - 1], columns.items[1..]) |left_column, right_column| {
        const left_last = lastNodeInColumn(nodes, left_column) orelse continue;
        const right_first = firstNodeInColumn(nodes, right_column) orelse continue;
        try mergeOrAppendProposal(allocator, proposals, .{
            .source = left_last,
            .target = right_first,
            .relation = .precedes,
            .confidence = 0.80,
            .evidence = EvidenceKind.column_transition.mask(),
        });
    }

    var min_x = nodes[0].bounds.x0;
    var max_x = nodes[0].bounds.x1;
    for (nodes[1..]) |node| {
        min_x = @min(min_x, node.bounds.x0);
        max_x = @max(max_x, node.bounds.x1);
    }
    const content_width = max_x - min_x;
    const midpoint = min_x + content_width / 2.0;
    if (content_width <= 0) return;

    for (nodes) |heading| {
        if (heading.kind != .heading) continue;
        const width = heading.bounds.x1 - heading.bounds.x0;
        if (width < content_width * 0.60 and !(heading.bounds.x0 < midpoint and heading.bounds.x1 > midpoint)) continue;

        for (columns.items) |column| {
            const above = nearestAbove(nodes, heading, column);
            const below = nearestBelow(nodes, heading, column);
            if (above) |source| {
                try mergeOrAppendProposal(allocator, proposals, .{
                    .source = source,
                    .target = heading.id,
                    .relation = .precedes,
                    .confidence = 0.85,
                    .evidence = EvidenceKind.spanning_heading.mask(),
                });
            }
            if (below) |target| {
                try mergeOrAppendProposal(allocator, proposals, .{
                    .source = heading.id,
                    .target = target,
                    .relation = .precedes,
                    .confidence = 0.85,
                    .evidence = EvidenceKind.spanning_heading.mask(),
                });
            }
        }
    }
}

fn firstNodeInColumn(nodes: []const BlockNode, column: u32) ?NodeId {
    var best: ?BlockNode = null;
    for (nodes) |node| {
        if (node.column_index != column) continue;
        if (best == null or visualLessThan({}, node, best.?)) best = node;
    }
    return if (best) |node| node.id else null;
}

fn lastNodeInColumn(nodes: []const BlockNode, column: u32) ?NodeId {
    var best: ?BlockNode = null;
    for (nodes) |node| {
        if (node.column_index != column) continue;
        if (best == null or visualLessThan({}, best.?, node)) best = node;
    }
    return if (best) |node| node.id else null;
}

fn nearestAbove(nodes: []const BlockNode, heading: BlockNode, column: u32) ?NodeId {
    var best: ?BlockNode = null;
    for (nodes) |node| {
        if (node.id == heading.id or node.column_index != column or node.bounds.y0 < heading.bounds.y1) continue;
        if (best == null or node.bounds.y0 < best.?.bounds.y0 or
            (node.bounds.y0 == best.?.bounds.y0 and node.original_position < best.?.original_position))
        {
            best = node;
        }
    }
    return if (best) |node| node.id else null;
}

fn nearestBelow(nodes: []const BlockNode, heading: BlockNode, column: u32) ?NodeId {
    var best: ?BlockNode = null;
    for (nodes) |node| {
        if (node.id == heading.id or node.column_index != column or node.bounds.y1 > heading.bounds.y0) continue;
        if (best == null or node.bounds.y1 > best.?.bounds.y1 or
            (node.bounds.y1 == best.?.bounds.y1 and node.original_position < best.?.original_position))
        {
            best = node;
        }
    }
    return if (best) |node| node.id else null;
}

fn nodeForBlock(nodes: []const BlockNode, block_index: u32) ?NodeId {
    for (nodes) |node| {
        if (node.original_block_index == block_index) return node.id;
    }
    return null;
}

fn mergeOrAppendProposal(allocator: std.mem.Allocator, proposals: *std.ArrayList(GraphEdge), edge: GraphEdge) !void {
    _ = try mergeOrAppendEdge(allocator, proposals, edge);
}

fn mergeOrAppendEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(GraphEdge), edge: GraphEdge) !bool {
    if (edge.source == edge.target) return false;
    for (edges.items) |*existing| {
        if (existing.source == edge.source and existing.target == edge.target and existing.relation == edge.relation) {
            existing.confidence = @max(existing.confidence, edge.confidence);
            existing.evidence |= edge.evidence;
            existing.hard = existing.hard or edge.hard;
            return false;
        }
    }
    try edges.append(allocator, edge);
    return true;
}

fn incrementWithinBound(outgoing: []u8, source: NodeId) bool {
    const index: usize = @intCast(source);
    outgoing[index] += 1;
    return outgoing[index] <= max_edges_per_node;
}

fn wouldCreateCycle(
    edges: []const GraphEdge,
    source: NodeId,
    target: NodeId,
    visited: []bool,
    stack: []NodeId,
) bool {
    if (source == target) return true;
    @memset(visited, false);
    var stack_len: usize = 1;
    stack[0] = target;
    visited[target] = true;

    while (stack_len > 0) {
        stack_len -= 1;
        const current = stack[stack_len];
        if (current == source) return true;
        for (edges) |edge| {
            if (edge.relation != .precedes or edge.source != current) continue;
            if (!visited[edge.target]) {
                visited[edge.target] = true;
                stack[stack_len] = edge.target;
                stack_len += 1;
            }
        }
    }
    return false;
}

fn projectStable(
    allocator: std.mem.Allocator,
    nodes: []const BlockNode,
    edges: []const GraphEdge,
    projected: *std.ArrayList(u32),
) !bool {
    const indegree = try allocator.alloc(u16, nodes.len);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    const emitted = try allocator.alloc(bool, nodes.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    for (edges) |edge| {
        if (edge.relation == .precedes) indegree[edge.target] += 1;
    }

    while (projected.items.len < nodes.len) {
        var next: ?BlockNode = null;
        for (nodes) |node| {
            if (emitted[node.id] or indegree[node.id] != 0) continue;
            if (next == null or projectionLessThan(node, next.?)) next = node;
        }
        const selected = next orelse return false;
        emitted[selected.id] = true;
        try projected.append(allocator, selected.original_block_index);
        for (edges) |edge| {
            if (edge.relation == .precedes and edge.source == selected.id) indegree[edge.target] -= 1;
        }
    }
    return true;
}

fn projectionLessThan(left: BlockNode, right: BlockNode) bool {
    if (left.original_position != right.original_position) return left.original_position < right.original_position;
    return left.original_block_index < right.original_block_index;
}

fn visualLessThan(_: void, left: BlockNode, right: BlockNode) bool {
    if (left.bounds.y1 != right.bounds.y1) return left.bounds.y1 > right.bounds.y1;
    if (left.bounds.x0 != right.bounds.x0) return left.bounds.x0 < right.bounds.x0;
    return left.original_position < right.original_position;
}

fn softEdgeLessThan(_: void, left: GraphEdge, right: GraphEdge) bool {
    if (left.confidence != right.confidence) return left.confidence > right.confidence;
    const left_priority = evidencePriority(left.evidence);
    const right_priority = evidencePriority(right.evidence);
    if (left_priority != right_priority) return left_priority < right_priority;
    if (left.source != right.source) return left.source < right.source;
    if (left.target != right.target) return left.target < right.target;
    return @intFromEnum(left.relation) < @intFromEnum(right.relation);
}

fn evidencePriority(mask: EvidenceMask) u8 {
    const order = [_]EvidenceKind{
        .structure_tree,
        .caption_candidate,
        .footnote_marker,
        .spanning_heading,
        .same_column_successor,
        .column_transition,
        .sidebar_anchor,
    };
    for (order, 0..) |kind, index| {
        if (mask & kind.mask() != 0) return @intCast(index);
    }
    return std.math.maxInt(u8);
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64, mcid: ?i32) layout.TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .size = y1 - y0 },
        .mcid = mcid,
    });
}

fn testBlock(bounds: layout.TextSpan, lines: []const layout.TextLine, column: u32, kind: layout.BlockKind) layout.LayoutBlock {
    return .{
        .bounds = bounds,
        .lines = lines,
        .column_index = column,
        .kind = kind,
    };
}

test "graph excludes removed and empty blocks and owns sorted MCIDs" {
    const allocator = std.testing.allocator;
    const word_spans = [_]layout.TextSpan{
        testSpan("A", 10, 90, 20, 100, 9),
        testSpan("B", 22, 90, 32, 100, 3),
    };
    const words = [_]layout.TextWord{.{ .bounds = word_spans[0], .spans = &word_spans }};
    const lines = [_]layout.TextLine{.{ .bounds = word_spans[0], .words = &words, .baseline_y = 90 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(word_spans[0], &lines, 0, .paragraph),
        .{ .bounds = word_spans[0], .lines = &lines, .column_index = 0, .kind = .paragraph, .removed = true },
        testBlock(word_spans[0], &.{}, 0, .paragraph),
    };

    var graph = try buildFromParts(allocator, 4, &blocks, &.{}, 10, .{});
    defer graph.deinit();

    try std.testing.expect(graph.validity);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.len);
    try std.testing.expectEqual(@as(u32, 4), graph.nodes[0].page_index);
    try std.testing.expectEqualSlices(i32, &.{ 3, 9 }, graph.nodes[0].mcids);
    try std.testing.expectEqualSlices(u32, &.{0}, graph.projected_block_order);
}

test "hard structure order overrides and rejects conflicting geometry" {
    const allocator = std.testing.allocator;
    const top_span = testSpan("top", 10, 90, 40, 100, 1);
    const bottom_span = testSpan("bottom", 10, 70, 50, 80, 2);
    const top_words = [_]layout.TextWord{.{ .bounds = top_span, .spans = &.{top_span} }};
    const bottom_words = [_]layout.TextWord{.{ .bounds = bottom_span, .spans = &.{bottom_span} }};
    const top_lines = [_]layout.TextLine{.{ .bounds = top_span, .words = &top_words, .baseline_y = 90 }};
    const bottom_lines = [_]layout.TextLine{.{ .bounds = bottom_span, .words = &bottom_words, .baseline_y = 70 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(top_span, &top_lines, 0, .paragraph),
        testBlock(bottom_span, &bottom_lines, 0, .paragraph),
    };

    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{
        .structure_mcid_order = &.{ 2, 1 },
    });
    defer graph.deinit();

    try std.testing.expect(graph.validity);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, graph.projected_block_order);
    try std.testing.expectEqual(@as(usize, 1), graph.rejected_edges.len);
    try std.testing.expectEqual(RejectedReason.cycle, graph.rejected_edges[0].reason);
}

test "ambiguous MCID ownership is excluded from structure evidence" {
    const allocator = std.testing.allocator;
    const a = testSpan("a", 10, 90, 20, 100, 7);
    const b = testSpan("b", 10, 70, 20, 80, 7);
    const a_words = [_]layout.TextWord{.{ .bounds = a, .spans = &.{a} }};
    const b_words = [_]layout.TextWord{.{ .bounds = b, .spans = &.{b} }};
    const a_lines = [_]layout.TextLine{.{ .bounds = a, .words = &a_words, .baseline_y = 90 }};
    const b_lines = [_]layout.TextLine{.{ .bounds = b, .words = &b_words, .baseline_y = 70 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(a, &a_lines, 0, .paragraph),
        testBlock(b, &b_lines, 0, .paragraph),
    };

    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{
        .structure_mcid_order = &.{7},
        .include_geometry = false,
    });
    defer graph.deinit();

    try std.testing.expect(graph.validity);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, graph.projected_block_order);
}

test "repeated hard structure blocks produce a diagnostic cycle fallback" {
    const allocator = std.testing.allocator;
    const a = testSpan("a", 10, 90, 20, 100, 1);
    const b = testSpan("b", 10, 70, 20, 80, 2);
    const a_words = [_]layout.TextWord{.{ .bounds = a, .spans = &.{a} }};
    const b_words = [_]layout.TextWord{.{ .bounds = b, .spans = &.{b} }};
    const a_lines = [_]layout.TextLine{.{ .bounds = a, .words = &a_words, .baseline_y = 90 }};
    const b_lines = [_]layout.TextLine{.{ .bounds = b, .words = &b_words, .baseline_y = 70 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(a, &a_lines, 0, .paragraph),
        testBlock(b, &b_lines, 0, .paragraph),
    };

    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{
        .structure_mcid_order = &.{ 1, 2, 1 },
        .include_geometry = false,
    });
    defer graph.deinit();

    try std.testing.expect(!graph.validity);
    try std.testing.expectEqual(FallbackReason.hard_cycle, graph.fallback);
    try std.testing.expectEqual(@as(usize, 0), graph.projected_block_order.len);
}

test "caption relation induces anchor before caption" {
    const allocator = std.testing.allocator;
    const caption_span = testSpan("Figure 1", 10, 70, 50, 80, null);
    const anchor_span = testSpan("figure", 10, 90, 90, 100, null);
    const caption_lines = [_]layout.TextLine{.{ .bounds = caption_span, .words = &.{}, .baseline_y = 70 }};
    const anchor_lines = [_]layout.TextLine{.{ .bounds = anchor_span, .words = &.{}, .baseline_y = 90 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(caption_span, &caption_lines, 0, .caption),
        testBlock(anchor_span, &anchor_lines, 0, .figure_candidate),
    };
    const candidates = [_]layout.LayoutCandidate{.{
        .kind = .figure,
        .bounds = anchor_span,
        .line_index = 1,
        .block_index = 1,
        .caption_block_index = 0,
        .confidence = 0.9,
    }};

    var graph = try buildFromParts(allocator, 0, &blocks, &candidates, 10, .{ .include_geometry = false });
    defer graph.deinit();

    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, graph.projected_block_order);
    var saw_relation = false;
    for (graph.edges) |edge| {
        if (edge.relation == .caption_of and edge.source == 0 and edge.target == 1) saw_relation = true;
    }
    try std.testing.expect(saw_relation);
}

test "unambiguous bottom-band footnote emits relation and precedence" {
    const allocator = std.testing.allocator;
    const body_text = testSpan("body [1] reference", 10, 90, 80, 100, null);
    const footnote_text = testSpan("[1] source", 10, 5, 55, 12, null);
    const body_words = [_]layout.TextWord{.{ .bounds = body_text, .spans = &.{body_text} }};
    const footnote_words = [_]layout.TextWord{.{ .bounds = footnote_text, .spans = &.{footnote_text} }};
    const body_lines = [_]layout.TextLine{.{ .bounds = body_text, .words = &body_words, .baseline_y = 90 }};
    const footnote_lines = [_]layout.TextLine{.{ .bounds = footnote_text, .words = &footnote_words, .baseline_y = 5 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(body_text, &body_lines, 0, .paragraph),
        testBlock(footnote_text, &footnote_lines, 0, .paragraph),
    };

    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{ .include_geometry = false });
    defer graph.deinit();

    var saw_relation = false;
    for (graph.edges) |edge| {
        if (edge.relation == .footnote_of and edge.source == 1 and edge.target == 0) saw_relation = true;
    }
    try std.testing.expect(saw_relation);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, graph.projected_block_order);
}

test "two-column geometry is sparse and deterministic" {
    const allocator = std.testing.allocator;
    const spans = [_]layout.TextSpan{
        testSpan("L1", 10, 90, 20, 100, null),
        testSpan("L2", 10, 70, 20, 80, null),
        testSpan("R1", 60, 90, 70, 100, null),
        testSpan("R2", 60, 70, 70, 80, null),
    };
    const lines = [_]layout.TextLine{
        .{ .bounds = spans[0], .words = &.{}, .baseline_y = 90 },
        .{ .bounds = spans[1], .words = &.{}, .baseline_y = 70 },
        .{ .bounds = spans[2], .words = &.{}, .baseline_y = 90 },
        .{ .bounds = spans[3], .words = &.{}, .baseline_y = 70 },
    };
    const blocks = [_]layout.LayoutBlock{
        testBlock(spans[0], lines[0..1], 0, .paragraph),
        testBlock(spans[1], lines[1..2], 0, .paragraph),
        testBlock(spans[2], lines[2..3], 1, .paragraph),
        testBlock(spans[3], lines[3..4], 1, .paragraph),
    };

    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{});
    defer graph.deinit();

    try std.testing.expect(graph.validity);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, graph.projected_block_order);
    try std.testing.expectEqual(@as(usize, 3), graph.edges.len);
}

test "edge fanout beyond the resource bound falls back" {
    const allocator = std.testing.allocator;
    var spans: [10]layout.TextSpan = undefined;
    var lines: [10]layout.TextLine = undefined;
    var blocks: [10]layout.LayoutBlock = undefined;
    var candidates: [9]layout.LayoutCandidate = undefined;
    for (0..10) |index| {
        spans[index] = testSpan("x", 10, @floatFromInt(100 - index), 20, @floatFromInt(110 - index), null);
        lines[index] = .{ .bounds = spans[index], .words = &.{}, .baseline_y = spans[index].y0 };
        blocks[index] = testBlock(spans[index], lines[index .. index + 1], 0, .paragraph);
        if (index > 0) {
            candidates[index - 1] = .{
                .kind = .figure,
                .bounds = spans[index],
                .line_index = @intCast(index),
                .block_index = 0,
                .caption_block_index = @intCast(index),
                .confidence = 0.9,
            };
        }
    }

    var graph = try buildFromParts(allocator, 0, &blocks, &candidates, 10, .{ .include_geometry = false });
    defer graph.deinit();

    try std.testing.expect(!graph.validity);
    try std.testing.expectEqual(FallbackReason.too_many_edges, graph.fallback);
}

test "node count beyond the resource bound falls back" {
    const allocator = std.testing.allocator;
    const span = testSpan("x", 10, 90, 20, 100, null);
    const lines = [_]layout.TextLine{.{ .bounds = span, .words = &.{}, .baseline_y = 90 }};
    const blocks = try allocator.alloc(layout.LayoutBlock, max_nodes + 1);
    defer allocator.free(blocks);
    for (blocks) |*block| block.* = testBlock(span, &lines, 0, .paragraph);

    var graph = try buildFromParts(allocator, 0, blocks, &.{}, 10, .{});
    defer graph.deinit();

    try std.testing.expect(!graph.validity);
    try std.testing.expectEqual(FallbackReason.too_many_nodes, graph.fallback);
    try std.testing.expectEqual(max_nodes, graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), graph.projected_block_order.len);
}

test "deterministic generated DAGs project without accepted cycles" {
    const allocator = std.testing.allocator;
    const node_count = 16;
    var nodes: [node_count]BlockNode = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = .{
            .id = @intCast(index),
            .page_index = 0,
            .original_block_index = @intCast(index),
            .original_position = @intCast(index),
            .bounds = .{ .x0 = 0, .y0 = @floatFromInt(node_count - index), .x1 = 1, .y1 = @floatFromInt(node_count - index + 1) },
            .kind = .paragraph,
            .column_index = 0,
            .mcids = &.{},
        };
    }

    for (1..65) |seed| {
        var state: u64 = @intCast(seed);
        var edges: std.ArrayList(GraphEdge) = .empty;
        defer edges.deinit(allocator);
        for (0..node_count) |source| {
            for (source + 1..node_count) |target| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                if (state & 3 != 0) continue;
                try edges.append(allocator, .{
                    .source = @intCast(source),
                    .target = @intCast(target),
                    .relation = .precedes,
                    .confidence = 0.8,
                    .evidence = EvidenceKind.same_column_successor.mask(),
                });
            }
        }

        var first: std.ArrayList(u32) = .empty;
        defer first.deinit(allocator);
        var second: std.ArrayList(u32) = .empty;
        defer second.deinit(allocator);
        try std.testing.expect(try projectStable(allocator, &nodes, edges.items, &first));
        try std.testing.expect(try projectStable(allocator, &nodes, edges.items, &second));
        try std.testing.expectEqualSlices(u32, first.items, second.items);

        var position: [node_count]usize = undefined;
        for (first.items, 0..) |block_index, index| position[block_index] = index;
        var visited: [node_count]bool = undefined;
        var stack: [node_count]NodeId = undefined;
        for (edges.items) |edge| {
            try std.testing.expect(position[edge.source] < position[edge.target]);
            try std.testing.expect(wouldCreateCycle(edges.items, edge.target, edge.source, &visited, &stack));
        }
    }
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const a = testSpan("a", 10, 90, 20, 100, 1);
    const b = testSpan("b", 10, 70, 20, 80, 2);
    const a_words = [_]layout.TextWord{.{ .bounds = a, .spans = &.{a} }};
    const b_words = [_]layout.TextWord{.{ .bounds = b, .spans = &.{b} }};
    const a_lines = [_]layout.TextLine{.{ .bounds = a, .words = &a_words, .baseline_y = 90 }};
    const b_lines = [_]layout.TextLine{.{ .bounds = b, .words = &b_words, .baseline_y = 70 }};
    const blocks = [_]layout.LayoutBlock{
        testBlock(a, &a_lines, 0, .paragraph),
        testBlock(b, &b_lines, 0, .paragraph),
    };
    var graph = try buildFromParts(allocator, 0, &blocks, &.{}, 10, .{ .structure_mcid_order = &.{ 1, 2 } });
    defer graph.deinit();
}

test "graph ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
