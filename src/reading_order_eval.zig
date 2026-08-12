//! Relation-aware evaluation for the internal reading-order graph experiment.
//!
//! This module is deliberately independent from the parser and layout types.
//! Callers adapt their graph into `Prediction`, then evaluate it against a
//! versioned truth document. Text anchors must resolve to exactly one predicted
//! node on the declared page; missing and ambiguous anchors are hard errors.

const std = @import("std");

pub const truth_version: u32 = 1;
pub const max_nodes: usize = 4096;

pub const Relation = enum {
    precedes,
    caption_of,
    footnote_of,
};

pub const TruthNode = struct {
    id: []const u8,
    page_index: u32,
    text_anchor: []const u8,
};

pub const NodePair = [2][]const u8;

pub const TruthRelation = struct {
    type: Relation,
    from: []const u8,
    to: []const u8,
};

pub const TruthDocument = struct {
    version: u32,
    nodes: []const TruthNode,
    required_precedence: []const NodePair = &.{},
    forbidden_precedence: []const NodePair = &.{},
    ambiguous_pairs: []const NodePair = &.{},
    relations: []const TruthRelation = &.{},
    valid_orders: []const []const []const u8 = &.{},
};

pub const Truth = struct {
    parsed: std.json.Parsed(TruthDocument),

    pub fn document(self: *const Truth) *const TruthDocument {
        return &self.parsed.value;
    }

    pub fn deinit(self: *Truth) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const PredictedNode = struct {
    id: u32,
    page_index: u32,
    text: []const u8,
};

pub const PredictedEdge = struct {
    from: u32,
    to: u32,
    relation: Relation,
};

/// Borrowed neutral representation of an inferred graph and its stable
/// projection. `projection` contains predicted node ids, not slice indexes.
pub const Prediction = struct {
    nodes: []const PredictedNode,
    edges: []const PredictedEdge,
    projection: []const u32,
    valid: bool = true,
};

pub const DetectionMetrics = struct {
    true_positive: u32 = 0,
    false_positive: u32 = 0,
    false_negative: u32 = 0,
    precision: ?f64 = null,
    recall: ?f64 = null,
    f1: ?f64 = null,
};

pub const Metrics = struct {
    precedence: DetectionMetrics = .{},
    required_recall: ?f64 = null,
    forbidden_path_rate: ?f64 = null,
    caption: DetectionMetrics = .{},
    footnote: DetectionMetrics = .{},
    cycle_rate: f64 = 0.0,
    ambiguity_preservation: ?f64 = null,
    valid_projection: f64 = 0.0,
};

pub const Evaluation = struct {
    metrics: Metrics,
    /// One predicted node id for every truth node, in truth-node order.
    truth_to_prediction: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Evaluation) void {
        self.allocator.free(self.truth_to_prediction);
        self.* = undefined;
    }
};

pub const AnchorStatus = enum {
    resolved,
    not_found,
    ambiguous,
    collision,
};

/// One audit entry per truth node. Truth strings and predicted node text stay
/// borrowed; only `matched_node_ids` and the enclosing slice are owned.
pub const AnchorDiagnostic = struct {
    truth_index: u32,
    status: AnchorStatus,
    matched_node_ids: []u32,
    collision_with_truth_index: ?u32 = null,
};

pub const AnchorAudit = struct {
    diagnostics: []AnchorDiagnostic,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AnchorAudit) void {
        for (self.diagnostics) |diagnostic| self.allocator.free(diagnostic.matched_node_ids);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidTruthJson,
    UnsupportedTruthVersion,
    EmptyTruthNodeId,
    EmptyTextAnchor,
    DuplicateTruthNodeId,
    InvalidTruthReference,
    InvalidTruthConstraints,
    InvalidValidOrder,
    DuplicatePredictionNodeId,
    InvalidPredictionEdge,
    InvalidProjectionNode,
    DuplicateProjectionNode,
    NodeAnchorNotFound,
    NodeAnchorAmbiguous,
    NodeAnchorCollision,
    GraphTooLarge,
};

pub fn parseTruth(allocator: std.mem.Allocator, json: []const u8) !Truth {
    const parsed = std.json.parseFromSlice(TruthDocument, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTruthJson,
    };
    errdefer parsed.deinit();
    try validateTruth(allocator, &parsed.value);
    return .{ .parsed = parsed };
}

/// Resolves truth anchors, computes graph reachability, and scores only the
/// comparisons named by the truth contract. Unlabelled node pairs do not affect
/// precedence precision. `valid_orders`, when present, also contribute every
/// precedence relation shared by all listed valid orders.
pub fn evaluate(
    allocator: std.mem.Allocator,
    truth: *const Truth,
    prediction: Prediction,
) !Evaluation {
    try validatePrediction(prediction);

    const document = truth.document();
    const truth_to_prediction_index = try resolveAnchors(allocator, document, prediction.nodes);
    defer allocator.free(truth_to_prediction_index);

    const truth_to_prediction = try allocator.alloc(u32, document.nodes.len);
    errdefer allocator.free(truth_to_prediction);
    for (truth_to_prediction_index, 0..) |prediction_index, truth_index| {
        truth_to_prediction[truth_index] = prediction.nodes[prediction_index].id;
    }

    const reachability = try buildReachability(allocator, prediction);
    defer allocator.free(reachability);

    const truth_count = document.nodes.len;
    const matrix_len = std.math.mul(usize, truth_count, truth_count) catch return error.GraphTooLarge;
    const expected_precedence = try allocator.alloc(bool, matrix_len);
    defer allocator.free(expected_precedence);
    @memset(expected_precedence, false);
    try populateExpectedPrecedence(document, expected_precedence);

    const precedence = scorePrecedence(
        document,
        prediction,
        truth_to_prediction_index,
        reachability,
        expected_precedence,
    );
    const caption = scoreRelation(
        document,
        prediction,
        truth_to_prediction_index,
        .caption_of,
    );
    const footnote = scoreRelation(
        document,
        prediction,
        truth_to_prediction_index,
        .footnote_of,
    );

    const cycle_rate = cycleRate(prediction.nodes.len, reachability);
    const valid_projection = try projectionIsValid(
        allocator,
        document,
        prediction,
        truth_to_prediction_index,
        expected_precedence,
        cycle_rate > 0.0,
    );

    return .{
        .metrics = .{
            .precedence = precedence.detection,
            .required_recall = ratio(
                precedence.explicit_required_satisfied,
                precedence.explicit_required_total,
            ),
            .forbidden_path_rate = ratio(precedence.forbidden_violated, precedence.forbidden_total),
            .caption = caption,
            .footnote = footnote,
            .cycle_rate = cycle_rate,
            .ambiguity_preservation = ratio(
                precedence.ambiguity_preserved,
                precedence.ambiguity_total,
            ),
            .valid_projection = if (valid_projection) 1.0 else 0.0,
        },
        .truth_to_prediction = truth_to_prediction,
        .allocator = allocator,
    };
}

/// Resolves every anchor without aborting on representation failures. This is
/// an evaluator diagnostic, not a relaxed scoring path: `evaluate` continues
/// to require an exact one-to-one mapping.
pub fn auditAnchors(
    allocator: std.mem.Allocator,
    truth: *const Truth,
    predicted_nodes: []const PredictedNode,
) !AnchorAudit {
    try validatePrediction(.{
        .nodes = predicted_nodes,
        .edges = &.{},
        .projection = &.{},
    });

    const document = truth.document();
    const diagnostics = try allocator.alloc(AnchorDiagnostic, document.nodes.len);
    var initialized: usize = 0;
    errdefer {
        for (diagnostics[0..initialized]) |diagnostic| allocator.free(diagnostic.matched_node_ids);
        allocator.free(diagnostics);
    }

    for (document.nodes, 0..) |truth_node, truth_index| {
        const normalized_anchor = try normalizeWhitespace(allocator, truth_node.text_anchor);
        defer allocator.free(normalized_anchor);

        var matches: std.ArrayList(u32) = .empty;
        errdefer matches.deinit(allocator);
        for (predicted_nodes) |predicted_node| {
            if (predicted_node.page_index != truth_node.page_index) continue;
            const normalized_text = try normalizeWhitespace(allocator, predicted_node.text);
            defer allocator.free(normalized_text);
            if (std.mem.indexOf(u8, normalized_text, normalized_anchor) != null) {
                try matches.append(allocator, predicted_node.id);
            }
        }

        var status: AnchorStatus = if (matches.items.len == 0)
            .not_found
        else if (matches.items.len > 1)
            .ambiguous
        else
            .resolved;
        var collision_with: ?u32 = null;
        if (status == .resolved) {
            for (diagnostics[0..initialized]) |prior| {
                if (prior.matched_node_ids.len == 1 and prior.matched_node_ids[0] == matches.items[0]) {
                    status = .collision;
                    collision_with = prior.truth_index;
                    break;
                }
            }
        }

        diagnostics[truth_index] = .{
            .truth_index = @intCast(truth_index),
            .status = status,
            .matched_node_ids = try matches.toOwnedSlice(allocator),
            .collision_with_truth_index = collision_with,
        };
        initialized += 1;
    }

    return .{ .diagnostics = diagnostics, .allocator = allocator };
}

const PrecedenceScore = struct {
    detection: DetectionMetrics,
    explicit_required_satisfied: usize,
    explicit_required_total: usize,
    forbidden_violated: usize,
    forbidden_total: usize,
    ambiguity_preserved: usize,
    ambiguity_total: usize,
};

fn validateTruth(allocator: std.mem.Allocator, document: *const TruthDocument) !void {
    if (document.version != truth_version) return error.UnsupportedTruthVersion;
    if (document.nodes.len > max_nodes) return error.GraphTooLarge;

    for (document.nodes, 0..) |node, index| {
        if (node.id.len == 0) return error.EmptyTruthNodeId;
        if (normalizedLength(node.text_anchor) == 0) return error.EmptyTextAnchor;
        for (document.nodes[0..index]) |prior| {
            if (std.mem.eql(u8, node.id, prior.id)) return error.DuplicateTruthNodeId;
        }
    }

    try validatePairs(document, document.required_precedence, false);
    try validatePairs(document, document.forbidden_precedence, false);
    try validatePairs(document, document.ambiguous_pairs, true);
    for (document.relations, 0..) |relation, relation_index| {
        if (relation.type == .precedes) return error.InvalidTruthConstraints;
        const from = truthIndex(document, relation.from) orelse return error.InvalidTruthReference;
        const to = truthIndex(document, relation.to) orelse return error.InvalidTruthReference;
        if (from == to) return error.InvalidTruthConstraints;
        for (document.relations[0..relation_index]) |prior| {
            if (prior.type == relation.type and
                std.mem.eql(u8, prior.from, relation.from) and
                std.mem.eql(u8, prior.to, relation.to)) return error.InvalidTruthConstraints;
        }
    }

    for (document.valid_orders) |order| {
        if (order.len != document.nodes.len) return error.InvalidValidOrder;
        for (order, 0..) |id, index| {
            _ = truthIndex(document, id) orelse return error.InvalidTruthReference;
            for (order[0..index]) |prior| {
                if (std.mem.eql(u8, id, prior)) return error.InvalidValidOrder;
            }
        }
        for (document.required_precedence) |pair| {
            if (orderPosition(order, pair[0]).? >= orderPosition(order, pair[1]).?) {
                return error.InvalidTruthConstraints;
            }
        }
        for (document.forbidden_precedence) |pair| {
            if (orderPosition(order, pair[0]).? < orderPosition(order, pair[1]).?) {
                return error.InvalidTruthConstraints;
            }
        }
    }

    const count = document.nodes.len;
    const matrix_len = std.math.mul(usize, count, count) catch return error.GraphTooLarge;
    const expected = try allocator.alloc(bool, matrix_len);
    defer allocator.free(expected);
    @memset(expected, false);
    try populateExpectedPrecedence(document, expected);

    for (0..count) |middle| {
        for (0..count) |from| {
            if (!expected[from * count + middle]) continue;
            for (0..count) |to| {
                if (expected[middle * count + to]) expected[from * count + to] = true;
            }
        }
    }
    for (0..count) |index| {
        if (expected[index * count + index]) return error.InvalidTruthConstraints;
    }

    for (document.forbidden_precedence) |pair| {
        const from = truthIndex(document, pair[0]).?;
        const to = truthIndex(document, pair[1]).?;
        if (expected[from * count + to]) return error.InvalidTruthConstraints;
    }
    for (document.ambiguous_pairs) |pair| {
        const first = truthIndex(document, pair[0]).?;
        const second = truthIndex(document, pair[1]).?;
        if (expected[first * count + second] or expected[second * count + first]) {
            return error.InvalidTruthConstraints;
        }
        if (containsDirectedPair(document.forbidden_precedence, pair[0], pair[1]) or
            containsDirectedPair(document.forbidden_precedence, pair[1], pair[0]))
        {
            return error.InvalidTruthConstraints;
        }
        if (document.valid_orders.len > 0) {
            var first_before_second = false;
            var second_before_first = false;
            for (document.valid_orders) |order| {
                const first_position = orderPosition(order, pair[0]).?;
                const second_position = orderPosition(order, pair[1]).?;
                if (first_position < second_position) {
                    first_before_second = true;
                } else {
                    second_before_first = true;
                }
            }
            if (!first_before_second or !second_before_first) return error.InvalidTruthConstraints;
        }
    }
}

fn validatePairs(document: *const TruthDocument, pairs: []const NodePair, unordered: bool) !void {
    for (pairs, 0..) |pair, pair_index| {
        const first = truthIndex(document, pair[0]) orelse return error.InvalidTruthReference;
        const second = truthIndex(document, pair[1]) orelse return error.InvalidTruthReference;
        if (first == second) return error.InvalidTruthConstraints;
        for (pairs[0..pair_index]) |prior| {
            const same_direction = std.mem.eql(u8, prior[0], pair[0]) and
                std.mem.eql(u8, prior[1], pair[1]);
            const reverse_direction = unordered and std.mem.eql(u8, prior[0], pair[1]) and
                std.mem.eql(u8, prior[1], pair[0]);
            if (same_direction or reverse_direction) return error.InvalidTruthConstraints;
        }
    }
}

fn validatePrediction(prediction: Prediction) !void {
    if (prediction.nodes.len > max_nodes) return error.GraphTooLarge;
    for (prediction.nodes, 0..) |node, index| {
        for (prediction.nodes[0..index]) |prior| {
            if (node.id == prior.id) return error.DuplicatePredictionNodeId;
        }
    }
    for (prediction.edges) |edge| {
        if (edge.from == edge.to) return error.InvalidPredictionEdge;
        _ = predictionIndex(prediction.nodes, edge.from) orelse return error.InvalidPredictionEdge;
        _ = predictionIndex(prediction.nodes, edge.to) orelse return error.InvalidPredictionEdge;
    }
    for (prediction.projection, 0..) |id, index| {
        _ = predictionIndex(prediction.nodes, id) orelse return error.InvalidProjectionNode;
        for (prediction.projection[0..index]) |prior| {
            if (id == prior) return error.DuplicateProjectionNode;
        }
    }
}

fn resolveAnchors(
    allocator: std.mem.Allocator,
    document: *const TruthDocument,
    predicted_nodes: []const PredictedNode,
) ![]usize {
    const mapping = try allocator.alloc(usize, document.nodes.len);
    errdefer allocator.free(mapping);

    for (document.nodes, 0..) |truth_node, truth_index| {
        const normalized_anchor = try normalizeWhitespace(allocator, truth_node.text_anchor);
        defer allocator.free(normalized_anchor);

        var match: ?usize = null;
        for (predicted_nodes, 0..) |predicted_node, predicted_index| {
            if (predicted_node.page_index != truth_node.page_index) continue;
            const normalized_text = try normalizeWhitespace(allocator, predicted_node.text);
            defer allocator.free(normalized_text);
            if (std.mem.indexOf(u8, normalized_text, normalized_anchor) == null) continue;
            if (match != null) return error.NodeAnchorAmbiguous;
            match = predicted_index;
        }
        mapping[truth_index] = match orelse return error.NodeAnchorNotFound;
        for (mapping[0..truth_index]) |prior| {
            if (prior == mapping[truth_index]) return error.NodeAnchorCollision;
        }
    }
    return mapping;
}

fn buildReachability(allocator: std.mem.Allocator, prediction: Prediction) ![]bool {
    const count = prediction.nodes.len;
    const matrix_len = std.math.mul(usize, count, count) catch return error.GraphTooLarge;
    const reachability = try allocator.alloc(bool, matrix_len);
    errdefer allocator.free(reachability);
    @memset(reachability, false);

    const adjacency_counts = try allocator.alloc(usize, count);
    defer allocator.free(adjacency_counts);
    @memset(adjacency_counts, 0);
    var precedence_edge_count: usize = 0;
    for (prediction.edges) |edge| {
        if (edge.relation != .precedes) continue;
        const from = predictionIndex(prediction.nodes, edge.from).?;
        adjacency_counts[from] += 1;
        precedence_edge_count += 1;
    }

    const adjacency_offsets = try allocator.alloc(usize, count + 1);
    defer allocator.free(adjacency_offsets);
    adjacency_offsets[0] = 0;
    for (adjacency_counts, 0..) |edge_count, index| {
        adjacency_offsets[index + 1] = adjacency_offsets[index] + edge_count;
    }
    const adjacency_cursor = try allocator.dupe(usize, adjacency_offsets[0..count]);
    defer allocator.free(adjacency_cursor);
    const adjacency = try allocator.alloc(usize, precedence_edge_count);
    defer allocator.free(adjacency);
    for (prediction.edges) |edge| {
        if (edge.relation != .precedes) continue;
        const from = predictionIndex(prediction.nodes, edge.from).?;
        const to = predictionIndex(prediction.nodes, edge.to).?;
        adjacency[adjacency_cursor[from]] = to;
        adjacency_cursor[from] += 1;
    }

    const stack = try allocator.alloc(usize, count);
    defer allocator.free(stack);
    for (0..count) |source| {
        const row = reachability[source * count ..][0..count];
        var stack_len: usize = 0;
        for (adjacency[adjacency_offsets[source]..adjacency_offsets[source + 1]]) |target| {
            if (row[target]) continue;
            row[target] = true;
            stack[stack_len] = target;
            stack_len += 1;
        }
        while (stack_len > 0) {
            stack_len -= 1;
            const current = stack[stack_len];
            for (adjacency[adjacency_offsets[current]..adjacency_offsets[current + 1]]) |target| {
                if (row[target]) continue;
                row[target] = true;
                stack[stack_len] = target;
                stack_len += 1;
            }
        }
    }
    return reachability;
}

fn populateExpectedPrecedence(document: *const TruthDocument, expected: []bool) !void {
    const count = document.nodes.len;
    for (document.required_precedence) |pair| {
        const from = truthIndex(document, pair[0]) orelse return error.InvalidTruthReference;
        const to = truthIndex(document, pair[1]) orelse return error.InvalidTruthReference;
        expected[from * count + to] = true;
    }

    if (document.valid_orders.len == 0) return;
    for (0..count) |first| {
        for (0..count) |second| {
            if (first == second) continue;
            var unanimous = true;
            for (document.valid_orders) |order| {
                const first_position = orderPosition(order, document.nodes[first].id).?;
                const second_position = orderPosition(order, document.nodes[second].id).?;
                if (first_position >= second_position) {
                    unanimous = false;
                    break;
                }
            }
            if (unanimous) expected[first * count + second] = true;
        }
    }
}

fn scorePrecedence(
    document: *const TruthDocument,
    prediction: Prediction,
    mapping: []const usize,
    reachability: []const bool,
    expected: []const bool,
) PrecedenceScore {
    const truth_count = document.nodes.len;
    const predicted_count = prediction.nodes.len;
    var tp: usize = 0;
    var fp: usize = 0;
    var fn_count: usize = 0;

    for (0..truth_count) |from| {
        for (0..truth_count) |to| {
            if (!expected[from * truth_count + to]) continue;
            if (reachable(reachability, predicted_count, mapping[from], mapping[to])) {
                tp += 1;
            } else {
                fn_count += 1;
            }
            if (reachable(reachability, predicted_count, mapping[to], mapping[from]) and
                !containsDirectedPair(document.forbidden_precedence, document.nodes[to].id, document.nodes[from].id))
            {
                fp += 1;
            }
        }
    }

    var forbidden_violated: usize = 0;
    for (document.forbidden_precedence) |pair| {
        const from = truthIndex(document, pair[0]).?;
        const to = truthIndex(document, pair[1]).?;
        if (reachable(reachability, predicted_count, mapping[from], mapping[to])) {
            forbidden_violated += 1;
            fp += 1;
        }
    }

    var ambiguity_preserved: usize = 0;
    for (document.ambiguous_pairs) |pair| {
        const first = truthIndex(document, pair[0]).?;
        const second = truthIndex(document, pair[1]).?;
        const comparable = reachable(reachability, predicted_count, mapping[first], mapping[second]) or
            reachable(reachability, predicted_count, mapping[second], mapping[first]);
        if (comparable) {
            fp += 1;
        } else {
            ambiguity_preserved += 1;
        }
    }

    var explicit_required_satisfied: usize = 0;
    for (document.required_precedence) |pair| {
        const from = truthIndex(document, pair[0]).?;
        const to = truthIndex(document, pair[1]).?;
        if (reachable(reachability, predicted_count, mapping[from], mapping[to])) {
            explicit_required_satisfied += 1;
        }
    }

    return .{
        .detection = detection(tp, fp, fn_count),
        .explicit_required_satisfied = explicit_required_satisfied,
        .explicit_required_total = document.required_precedence.len,
        .forbidden_violated = forbidden_violated,
        .forbidden_total = document.forbidden_precedence.len,
        .ambiguity_preserved = ambiguity_preserved,
        .ambiguity_total = document.ambiguous_pairs.len,
    };
}

fn scoreRelation(
    document: *const TruthDocument,
    prediction: Prediction,
    mapping: []const usize,
    relation: Relation,
) DetectionMetrics {
    var tp: usize = 0;
    var fp: usize = 0;
    var expected_count: usize = 0;

    for (document.relations) |truth_relation| {
        if (truth_relation.type != relation) continue;
        expected_count += 1;
        const from = truthIndex(document, truth_relation.from).?;
        const to = truthIndex(document, truth_relation.to).?;
        if (hasPredictedRelation(prediction, mapping[from], mapping[to], relation)) tp += 1;
    }

    for (prediction.edges, 0..) |edge, edge_index| {
        if (edge.relation != relation) continue;
        if (duplicatePredictedEdgeBefore(prediction.edges, edge_index)) continue;
        const from_prediction = predictionIndex(prediction.nodes, edge.from).?;
        const to_prediction = predictionIndex(prediction.nodes, edge.to).?;
        const from_truth = mappedTruthIndex(mapping, from_prediction) orelse continue;
        const to_truth = mappedTruthIndex(mapping, to_prediction) orelse continue;
        if (!hasTruthRelation(document, from_truth, to_truth, relation)) fp += 1;
    }

    return detection(tp, fp, expected_count - tp);
}

fn projectionIsValid(
    allocator: std.mem.Allocator,
    document: *const TruthDocument,
    prediction: Prediction,
    mapping: []const usize,
    expected: []const bool,
    has_cycle: bool,
) !bool {
    if (!prediction.valid or has_cycle) return false;
    if (prediction.projection.len != prediction.nodes.len) return false;

    const prediction_positions = try allocator.alloc(usize, prediction.nodes.len);
    defer allocator.free(prediction_positions);
    @memset(prediction_positions, std.math.maxInt(usize));
    for (prediction.projection, 0..) |id, position| {
        const index = predictionIndex(prediction.nodes, id).?;
        prediction_positions[index] = position;
    }
    for (prediction_positions) |position| {
        if (position == std.math.maxInt(usize)) return false;
    }
    for (prediction.edges) |edge| {
        if (edge.relation != .precedes) continue;
        const from = predictionIndex(prediction.nodes, edge.from).?;
        const to = predictionIndex(prediction.nodes, edge.to).?;
        if (prediction_positions[from] >= prediction_positions[to]) return false;
    }

    const count = document.nodes.len;
    for (0..count) |from| {
        for (0..count) |to| {
            if (expected[from * count + to] and
                prediction_positions[mapping[from]] >= prediction_positions[mapping[to]]) return false;
        }
    }
    for (document.forbidden_precedence) |pair| {
        const from = truthIndex(document, pair[0]).?;
        const to = truthIndex(document, pair[1]).?;
        if (prediction_positions[mapping[from]] < prediction_positions[mapping[to]]) return false;
    }

    if (document.valid_orders.len == 0) return true;
    const projected_truth = try allocator.alloc(usize, document.nodes.len);
    defer allocator.free(projected_truth);
    var projected_truth_len: usize = 0;
    for (prediction.projection) |id| {
        const predicted_index = predictionIndex(prediction.nodes, id).?;
        const truth_index = mappedTruthIndex(mapping, predicted_index) orelse continue;
        projected_truth[projected_truth_len] = truth_index;
        projected_truth_len += 1;
    }
    if (projected_truth_len != document.nodes.len) return false;
    for (document.valid_orders) |valid_order| {
        var matches = true;
        for (0..valid_order.len) |position| {
            const expected_truth = truthIndex(document, valid_order[position]).?;
            if (projected_truth[position] != expected_truth) matches = false;
            if (!matches) break;
        }
        if (matches) return true;
    }
    return false;
}

fn cycleRate(node_count: usize, reachability: []const bool) f64 {
    if (node_count == 0) return 0.0;
    var cyclic_nodes: usize = 0;
    for (0..node_count) |index| {
        if (reachability[index * node_count + index]) cyclic_nodes += 1;
    }
    return @as(f64, @floatFromInt(cyclic_nodes)) / @as(f64, @floatFromInt(node_count));
}

fn hasPredictedRelation(
    prediction: Prediction,
    from_index: usize,
    to_index: usize,
    relation: Relation,
) bool {
    const from_id = prediction.nodes[from_index].id;
    const to_id = prediction.nodes[to_index].id;
    for (prediction.edges) |edge| {
        if (edge.relation == relation and edge.from == from_id and edge.to == to_id) return true;
    }
    return false;
}

fn hasTruthRelation(
    document: *const TruthDocument,
    from_index: usize,
    to_index: usize,
    relation: Relation,
) bool {
    for (document.relations) |edge| {
        if (edge.type != relation) continue;
        if (std.mem.eql(u8, edge.from, document.nodes[from_index].id) and
            std.mem.eql(u8, edge.to, document.nodes[to_index].id)) return true;
    }
    return false;
}

fn duplicatePredictedEdgeBefore(edges: []const PredictedEdge, index: usize) bool {
    const edge = edges[index];
    for (edges[0..index]) |prior| {
        if (prior.from == edge.from and prior.to == edge.to and prior.relation == edge.relation) return true;
    }
    return false;
}

fn containsDirectedPair(pairs: []const NodePair, from: []const u8, to: []const u8) bool {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair[0], from) and std.mem.eql(u8, pair[1], to)) return true;
    }
    return false;
}

fn mappedTruthIndex(mapping: []const usize, prediction_index: usize) ?usize {
    for (mapping, 0..) |mapped_prediction, truth_index| {
        if (mapped_prediction == prediction_index) return truth_index;
    }
    return null;
}

fn truthIndex(document: *const TruthDocument, id: []const u8) ?usize {
    for (document.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, id)) return index;
    }
    return null;
}

fn predictionIndex(nodes: []const PredictedNode, id: u32) ?usize {
    for (nodes, 0..) |node, index| {
        if (node.id == id) return index;
    }
    return null;
}

fn orderPosition(order: []const []const u8, id: []const u8) ?usize {
    for (order, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, id)) return index;
    }
    return null;
}

fn reachable(matrix: []const bool, count: usize, from: usize, to: usize) bool {
    return matrix[from * count + to];
}

fn detection(tp: usize, fp: usize, fn_count: usize) DetectionMetrics {
    const precision = ratio(tp, tp + fp);
    const recall = ratio(tp, tp + fn_count);
    const f1_denominator = 2 * tp + fp + fn_count;
    const f1 = if (f1_denominator == 0)
        null
    else
        @as(f64, @floatFromInt(2 * tp)) / @as(f64, @floatFromInt(f1_denominator));
    return .{
        .true_positive = @intCast(tp),
        .false_positive = @intCast(fp),
        .false_negative = @intCast(fn_count),
        .precision = precision,
        .recall = recall,
        .f1 = f1,
    };
}

fn ratio(numerator: usize, denominator: usize) ?f64 {
    if (denominator == 0) return null;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn normalizedLength(text: []const u8) usize {
    var count: usize = 0;
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                count += 1;
                previous_space = true;
            }
        } else {
            count += 1;
            previous_space = false;
        }
    }
    if (count > 0 and previous_space) count -= 1;
    return count;
}

fn normalizeWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try out.append(allocator, ' ');
                previous_space = true;
            }
        } else {
            try out.append(allocator, byte);
            previous_space = false;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(allocator);
}

const complete_truth_json =
    \\{
    \\  "version": 1,
    \\  "nodes": [
    \\    {"id":"heading","page_index":0,"text_anchor":"Results"},
    \\    {"id":"body","page_index":0,"text_anchor":"Body text"},
    \\    {"id":"sidebar","page_index":0,"text_anchor":"Side note"},
    \\    {"id":"figure","page_index":0,"text_anchor":"Figure image"},
    \\    {"id":"caption","page_index":0,"text_anchor":"Figure 1"},
    \\    {"id":"footnote","page_index":0,"text_anchor":"Footnote one"}
    \\  ],
    \\  "required_precedence": [["heading","body"],["body","footnote"]],
    \\  "forbidden_precedence": [["footnote","body"]],
    \\  "ambiguous_pairs": [["sidebar","body"]],
    \\  "relations": [
    \\    {"type":"caption_of","from":"caption","to":"figure"},
    \\    {"type":"footnote_of","from":"footnote","to":"body"}
    \\  ],
    \\  "valid_orders": []
    \\}
;

test "parse and evaluate a relation-aware acyclic graph" {
    var truth = try parseTruth(std.testing.allocator, complete_truth_json);
    defer truth.deinit();

    const nodes = [_]PredictedNode{
        .{ .id = 10, .page_index = 0, .text = "Results" },
        .{ .id = 20, .page_index = 0, .text = "Body   text" },
        .{ .id = 30, .page_index = 0, .text = "Side note" },
        .{ .id = 40, .page_index = 0, .text = "Figure image" },
        .{ .id = 50, .page_index = 0, .text = "Figure 1" },
        .{ .id = 60, .page_index = 0, .text = "Footnote one" },
    };
    const edges = [_]PredictedEdge{
        .{ .from = 10, .to = 20, .relation = .precedes },
        .{ .from = 20, .to = 60, .relation = .precedes },
        .{ .from = 50, .to = 40, .relation = .caption_of },
        .{ .from = 60, .to = 20, .relation = .footnote_of },
    };
    const projection = [_]u32{ 10, 20, 30, 40, 50, 60 };

    var result = try evaluate(std.testing.allocator, &truth, .{
        .nodes = &nodes,
        .edges = &edges,
        .projection = &projection,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.precedence.precision);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.precedence.recall);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.required_recall);
    try std.testing.expectEqual(@as(?f64, 0.0), result.metrics.forbidden_path_rate);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.ambiguity_preservation);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.caption.f1);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.footnote.f1);
    try std.testing.expectEqual(@as(f64, 0.0), result.metrics.cycle_rate);
    try std.testing.expectEqual(@as(f64, 1.0), result.metrics.valid_projection);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40, 50, 60 }, result.truth_to_prediction);
}

test "unmatched and ambiguous anchors are evaluation errors" {
    const json =
        \\{"version":1,"nodes":[{"id":"n","page_index":0,"text_anchor":"same"}]}
    ;
    var truth = try parseTruth(std.testing.allocator, json);
    defer truth.deinit();

    const missing = [_]PredictedNode{.{ .id = 1, .page_index = 0, .text = "different" }};
    try std.testing.expectError(error.NodeAnchorNotFound, evaluate(std.testing.allocator, &truth, .{
        .nodes = &missing,
        .edges = &.{},
        .projection = &.{1},
    }));

    const ambiguous = [_]PredictedNode{
        .{ .id = 1, .page_index = 0, .text = "same" },
        .{ .id = 2, .page_index = 0, .text = "also same" },
    };
    try std.testing.expectError(error.NodeAnchorAmbiguous, evaluate(std.testing.allocator, &truth, .{
        .nodes = &ambiguous,
        .edges = &.{},
        .projection = &.{ 1, 2 },
    }));
}

test "anchor audit reports every representation failure without aborting" {
    const json =
        \\{
        \\  "version":1,
        \\  "nodes":[
        \\    {"id":"first","page_index":0,"text_anchor":"shared"},
        \\    {"id":"collision","page_index":0,"text_anchor":"shared"},
        \\    {"id":"missing","page_index":0,"text_anchor":"absent"},
        \\    {"id":"ambiguous","page_index":0,"text_anchor":"duplicate"}
        \\  ]
        \\}
    ;
    var truth = try parseTruth(std.testing.allocator, json);
    defer truth.deinit();
    const nodes = [_]PredictedNode{
        .{ .id = 10, .page_index = 0, .text = "shared text" },
        .{ .id = 20, .page_index = 0, .text = "duplicate one" },
        .{ .id = 30, .page_index = 0, .text = "duplicate two" },
    };

    var audit = try auditAnchors(std.testing.allocator, &truth, &nodes);
    defer audit.deinit();

    try std.testing.expectEqual(@as(usize, 4), audit.diagnostics.len);
    try std.testing.expectEqual(AnchorStatus.resolved, audit.diagnostics[0].status);
    try std.testing.expectEqualSlices(u32, &.{10}, audit.diagnostics[0].matched_node_ids);
    try std.testing.expectEqual(AnchorStatus.collision, audit.diagnostics[1].status);
    try std.testing.expectEqual(@as(?u32, 0), audit.diagnostics[1].collision_with_truth_index);
    try std.testing.expectEqual(AnchorStatus.not_found, audit.diagnostics[2].status);
    try std.testing.expectEqual(@as(usize, 0), audit.diagnostics[2].matched_node_ids.len);
    try std.testing.expectEqual(AnchorStatus.ambiguous, audit.diagnostics[3].status);
    try std.testing.expectEqualSlices(u32, &.{ 20, 30 }, audit.diagnostics[3].matched_node_ids);
}

test "cycles forbidden paths and asserted ambiguity are measured" {
    var truth = try parseTruth(std.testing.allocator, complete_truth_json);
    defer truth.deinit();

    const nodes = [_]PredictedNode{
        .{ .id = 10, .page_index = 0, .text = "Results" },
        .{ .id = 20, .page_index = 0, .text = "Body text" },
        .{ .id = 30, .page_index = 0, .text = "Side note" },
        .{ .id = 40, .page_index = 0, .text = "Figure image" },
        .{ .id = 50, .page_index = 0, .text = "Figure 1" },
        .{ .id = 60, .page_index = 0, .text = "Footnote one" },
    };
    const edges = [_]PredictedEdge{
        .{ .from = 10, .to = 20, .relation = .precedes },
        .{ .from = 20, .to = 60, .relation = .precedes },
        .{ .from = 60, .to = 20, .relation = .precedes },
        .{ .from = 30, .to = 20, .relation = .precedes },
        .{ .from = 50, .to = 20, .relation = .caption_of },
    };
    const projection = [_]u32{ 10, 20, 30, 40, 50, 60 };
    var result = try evaluate(std.testing.allocator, &truth, .{
        .nodes = &nodes,
        .edges = &edges,
        .projection = &projection,
    });
    defer result.deinit();

    try std.testing.expect(result.metrics.cycle_rate > 0.0);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.forbidden_path_rate);
    try std.testing.expectEqual(@as(?f64, 0.0), result.metrics.ambiguity_preservation);
    try std.testing.expectEqual(@as(f64, 0.0), result.metrics.valid_projection);
    try std.testing.expectEqual(@as(u32, 1), result.metrics.caption.false_positive);
    try std.testing.expectEqual(@as(u32, 1), result.metrics.caption.false_negative);
}

test "valid orders add unanimous precedence and accept alternatives" {
    const json =
        \\{
        \\  "version":1,
        \\  "nodes":[
        \\    {"id":"a","page_index":0,"text_anchor":"A"},
        \\    {"id":"b","page_index":0,"text_anchor":"B"},
        \\    {"id":"c","page_index":0,"text_anchor":"C"}
        \\  ],
        \\  "ambiguous_pairs":[["b","c"]],
        \\  "valid_orders":[["a","b","c"],["a","c","b"]]
        \\}
    ;
    var truth = try parseTruth(std.testing.allocator, json);
    defer truth.deinit();

    const nodes = [_]PredictedNode{
        .{ .id = 1, .page_index = 0, .text = "A" },
        .{ .id = 2, .page_index = 0, .text = "B" },
        .{ .id = 3, .page_index = 0, .text = "C" },
    };
    const edges = [_]PredictedEdge{
        .{ .from = 1, .to = 2, .relation = .precedes },
        .{ .from = 1, .to = 3, .relation = .precedes },
    };
    const projection = [_]u32{ 1, 3, 2 };
    var result = try evaluate(std.testing.allocator, &truth, .{
        .nodes = &nodes,
        .edges = &edges,
        .projection = &projection,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.precedence.recall);
    try std.testing.expectEqual(@as(?f64, 1.0), result.metrics.ambiguity_preservation);
    try std.testing.expectEqual(@as(f64, 1.0), result.metrics.valid_projection);
}

test "truth validation rejects contradictory constraints" {
    const contradictory =
        \\{
        \\  "version":1,
        \\  "nodes":[
        \\    {"id":"a","page_index":0,"text_anchor":"A"},
        \\    {"id":"b","page_index":0,"text_anchor":"B"}
        \\  ],
        \\  "required_precedence":[["a","b"]],
        \\  "ambiguous_pairs":[["a","b"]]
        \\}
    ;
    try std.testing.expectError(
        error.InvalidTruthConstraints,
        parseTruth(std.testing.allocator, contradictory),
    );
}

test "missing expected relation reports zero F1" {
    const metrics = detection(0, 0, 1);
    try std.testing.expectEqual(@as(?f64, null), metrics.precision);
    try std.testing.expectEqual(@as(?f64, 0.0), metrics.recall);
    try std.testing.expectEqual(@as(?f64, 0.0), metrics.f1);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    const json =
        \\{
        \\  "version":1,
        \\  "nodes":[
        \\    {"id":"a","page_index":0,"text_anchor":"Alpha"},
        \\    {"id":"b","page_index":0,"text_anchor":"Beta"}
        \\  ],
        \\  "required_precedence":[["a","b"]]
        \\}
    ;
    var truth = try parseTruth(allocator, json);
    defer truth.deinit();
    const nodes = [_]PredictedNode{
        .{ .id = 1, .page_index = 0, .text = "Alpha" },
        .{ .id = 2, .page_index = 0, .text = "Beta" },
    };
    const edges = [_]PredictedEdge{.{ .from = 1, .to = 2, .relation = .precedes }};
    var audit = try auditAnchors(allocator, &truth, &nodes);
    defer audit.deinit();
    var result = try evaluate(allocator, &truth, .{
        .nodes = &nodes,
        .edges = &edges,
        .projection = &.{ 1, 2 },
    });
    defer result.deinit();
}

test "truth parsing and evaluation clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
