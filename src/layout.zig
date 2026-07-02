const std = @import("std");

pub const SourceKind = enum(u8) {
    native_pdf,
    embedded_ocr,
    fresh_ocr,
    table_model,
    formula_model,
    manual,
};

pub const BBox = struct {
    x0: f64 = 0,
    y0: f64 = 0,
    x1: f64 = 0,
    y1: f64 = 0,
};

pub const FontMetadata = struct {
    name: ?[]const u8 = null,
    size: f64 = 0,
    encoding: ?[]const u8 = null,
    has_to_unicode: ?bool = null,
};

pub const LineRole = enum(u8) {
    body,
    heading,
    list_item,
    header,
    footer,
    caption,
    table_candidate,
    formula_candidate,
    figure_candidate,
};

pub const BlockKind = enum(u8) {
    paragraph,
    heading,
    list_item,
    header,
    footer,
    caption,
    table_candidate,
    formula_candidate,
    figure_candidate,
};

pub const CandidateKind = enum(u8) {
    table,
    formula,
    figure,
};

pub const TextSpan = struct {
    page_index: u32 = 0,
    bbox: BBox = .{},
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text: []const u8,
    source: SourceKind = .native_pdf,
    confidence: f32 = 1.0,
    font: FontMetadata = .{},
    font_size: f64,
    page: u32 = 0,
    block_id: ?u32 = null,
    line_id: ?u32 = null,
    mcid: ?i32 = null,

    pub fn init(args: struct {
        page_index: u32 = 0,
        bbox: BBox,
        text: []const u8,
        source: SourceKind = .native_pdf,
        confidence: f32 = 1.0,
        font: FontMetadata = .{},
        block_id: ?u32 = null,
        line_id: ?u32 = null,
        mcid: ?i32 = null,
    }) TextSpan {
        var font = args.font;
        const font_size = if (font.size != 0) font.size else args.bbox.y1 - args.bbox.y0;
        font.size = font_size;
        return .{
            .page_index = args.page_index,
            .bbox = args.bbox,
            .x0 = args.bbox.x0,
            .y0 = args.bbox.y0,
            .x1 = args.bbox.x1,
            .y1 = args.bbox.y1,
            .text = args.text,
            .source = args.source,
            .confidence = args.confidence,
            .font = font,
            .font_size = font_size,
            .page = args.page_index,
            .block_id = args.block_id,
            .line_id = args.line_id,
            .mcid = args.mcid,
        };
    }
};

pub const TextWord = struct {
    bounds: TextSpan,
    spans: []const TextSpan,
};

pub const TextLine = struct {
    bounds: TextSpan,
    words: []const TextWord,
    baseline_y: f64,
    role: LineRole = .body,
};

pub const TextColumn = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    index: u32,
};

pub const TextParagraph = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    column_index: u32,
    first_line_indent: f64,
    kind: BlockKind = .paragraph,
};

pub const LayoutBlock = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    column_index: u32,
    kind: BlockKind,
    confidence: f32 = 0.5,
    removed: bool = false,
};

pub const TableCell = struct {
    bounds: TextSpan,
    text: []const u8,
    row_index: u32,
    column_index: u32,
    confidence: f32 = 0.70,
};

pub const TableRow = struct {
    bounds: TextSpan,
    cells: []TableCell,
    row_index: u32,
};

pub const TableGrid = struct {
    bounds: TextSpan,
    block_index: u32,
    block_count: usize = 1,
    rows: []TableRow,
    column_count: usize,
    confidence: f32 = 0.72,
};

pub const LayoutCandidate = struct {
    kind: CandidateKind,
    bounds: TextSpan,
    line_index: u32,
    block_index: ?u32 = null,
    caption_line_index: ?u32 = null,
    caption_block_index: ?u32 = null,
    confidence: f32,
};

pub const LayoutResult = struct {
    spans: []const TextSpan,
    lines: []const TextLine,
    columns: []const TextColumn,
    paragraphs: []const TextParagraph,
    blocks: []const LayoutBlock,
    tables: []const TableGrid,
    candidates: []const LayoutCandidate,
    reading_order: []const u32,
    body_font_size: f64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LayoutResult) void {
        self.allocator.free(self.spans);
        for (self.lines) |line| {
            for (line.words) |word| {
                self.allocator.free(word.spans);
            }
            self.allocator.free(line.words);
        }
        self.allocator.free(self.lines);
        for (self.columns) |col| {
            self.allocator.free(col.lines);
        }
        self.allocator.free(self.columns);
        for (self.paragraphs) |para| {
            self.allocator.free(para.lines);
        }
        self.allocator.free(self.paragraphs);
        for (self.blocks) |block| {
            self.allocator.free(block.lines);
        }
        self.allocator.free(self.blocks);
        for (self.tables) |table| {
            for (table.rows) |row| {
                for (row.cells) |cell| {
                    self.allocator.free(cell.text);
                }
                self.allocator.free(row.cells);
            }
            self.allocator.free(table.rows);
        }
        self.allocator.free(self.tables);
        self.allocator.free(self.candidates);
        self.allocator.free(self.reading_order);
    }

    /// Get text in reading order
    /// Uses the sorted spans directly (sorted by Y desc, then X asc)
    pub fn getTextInOrder(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        if (self.spans.len == 0) return try allocator.alloc(u8, 0);

        const line_threshold: f64 = 10;

        // Pre-calculate total size needed (worst case: space between every span + newlines)
        var total_len: usize = 0;
        var separator_count: usize = 0;
        var prev_y: f64 = self.spans[0].y0;
        var prev_x1: f64 = self.spans[0].x0;
        var prev_font_size: f64 = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    separator_count += 1; // newline
                    prev_y = span.y0;
                } else {
                    // Detect word gaps using font-relative threshold
                    // Typical space width is ~25-33% of em, kerning is <10%
                    const space_width = prev_font_size * 0.15; // 15% of font size
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        separator_count += 1; // space
                    }
                }
            }
            total_len += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        // Allocate exact size needed
        const result = try allocator.alloc(u8, total_len + separator_count);
        var pos: usize = 0;
        prev_y = self.spans[0].y0;
        prev_x1 = self.spans[0].x0;
        prev_font_size = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    result[pos] = '\n';
                    pos += 1;
                    prev_y = span.y0;
                } else {
                    const space_width = prev_font_size * 0.15;
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
            }
            @memcpy(result[pos..][0..span.text.len], span.text);
            pos += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        return result[0..pos];
    }

    /// Render reconstructed block text, skipping page-furniture candidates and
    /// joining soft hyphenated line breaks inside body paragraphs.
    pub fn getReconstructedText(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        if (self.blocks.len == 0) return self.getTextInOrder(allocator);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var emitted_block = false;
        for (self.blocks, 0..) |block, block_index| {
            if (block.removed) continue;
            if (block.lines.len == 0) continue;

            if (emitted_block and output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
                try output.append(allocator, '\n');
            }
            if (emitted_block) {
                try output.append(allocator, '\n');
            }

            if (block.kind == .table_candidate) {
                if (self.tableForBlock(block_index)) |table| {
                    try appendTablePlain(allocator, &output, table);
                    emitted_block = true;
                    continue;
                }
                if (self.blockCoveredByTable(block_index)) continue;
            }

            for (block.lines, 0..) |line, line_index| {
                if (line_index > 0) {
                    if (endsWithSoftHyphen(output.items) and lineStartsLowercase(&line)) {
                        _ = output.pop();
                    } else if (block.kind == .paragraph) {
                        try output.append(allocator, ' ');
                    } else {
                        try output.append(allocator, '\n');
                    }
                }
                try appendLineText(allocator, &output, &line);
            }

            emitted_block = true;
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn tableForBlock(self: *const LayoutResult, block_index: usize) ?*const TableGrid {
        for (self.tables) |*table| {
            if (table.block_index == block_index) return table;
        }
        return null;
    }

    pub fn blockCoveredByTable(self: *const LayoutResult, block_index: usize) bool {
        for (self.tables) |table| {
            const start: usize = @intCast(table.block_index);
            if (block_index >= start and block_index < start + table.block_count) return true;
        }
        return false;
    }

    pub fn writeTablesJson(self: *const LayoutResult, writer: anytype) !void {
        try writer.writeByte('[');
        for (self.tables, 0..) |table, table_index| {
            if (table_index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"block_index\":{},\"block_count\":{},\"confidence\":{d:.3},\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"rows\":[",
                .{ table.block_index, table.block_count, table.confidence, table.bounds.x0, table.bounds.y0, table.bounds.x1, table.bounds.y1 },
            );
            for (table.rows, 0..) |row, row_index| {
                if (row_index > 0) try writer.writeByte(',');
                try writer.writeByte('[');
                for (row.cells, 0..) |cell, cell_index| {
                    if (cell_index > 0) try writer.writeByte(',');
                    try writer.writeByte('{');
                    try writer.print("\"column\":{},\"text\":\"", .{cell.column_index});
                    try writeJsonEscaped(writer, cell.text);
                    try writer.print(
                        "\",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}]",
                        .{ cell.bounds.x0, cell.bounds.y0, cell.bounds.x1, cell.bounds.y1 },
                    );
                    try writer.writeByte('}');
                }
                try writer.writeByte(']');
            }
            try writer.writeAll("]}");
        }
        try writer.writeByte(']');
    }
};

/// Simple geometric sort: Y (top to bottom), then X (left to right)
/// Matches PyMuPDF's sort=True behavior
pub fn sortGeometric(allocator: std.mem.Allocator, spans: []const TextSpan) ![]u8 {
    if (spans.len == 0) return try allocator.alloc(u8, 0);

    // Sort by Y descending (top to bottom in PDF coords), then X ascending
    const sorted = try allocator.alloc(TextSpan, spans.len);
    defer allocator.free(sorted);
    @memcpy(sorted, spans);

    const line_threshold: f64 = 3; // Tight threshold to match PyMuPDF

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            // Group into rows by Y coordinate
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row; // Higher Y first (top of page)
            return a.x0 < b.x0; // Left to right within row
        }
    }.cmp);

    // Build output text
    var total_len: usize = 0;
    var separator_count: usize = 0;
    var prev_y: f64 = sorted[0].y0;
    var prev_x1: f64 = sorted[0].x0;
    var prev_font_size: f64 = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                separator_count += 1; // newline
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    separator_count += 1; // space
                }
            }
        }
        total_len += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    const result = try allocator.alloc(u8, total_len + separator_count);
    var pos: usize = 0;
    prev_y = sorted[0].y0;
    prev_x1 = sorted[0].x0;
    prev_font_size = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                result[pos] = '\n';
                pos += 1;
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    result[pos] = ' ';
                    pos += 1;
                }
            }
        }
        @memcpy(result[pos..][0..span.text.len], span.text);
        pos += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    return result[0..pos];
}

pub fn analyzeLayout(allocator: std.mem.Allocator, spans: []const TextSpan, page_width: f64) !LayoutResult {
    if (spans.len == 0) {
        return LayoutResult{
            .spans = try allocator.alloc(TextSpan, 0),
            .lines = try allocator.alloc(TextLine, 0),
            .columns = try allocator.alloc(TextColumn, 0),
            .paragraphs = try allocator.alloc(TextParagraph, 0),
            .blocks = try allocator.alloc(LayoutBlock, 0),
            .tables = try allocator.alloc(TableGrid, 0),
            .candidates = try allocator.alloc(LayoutCandidate, 0),
            .reading_order = try allocator.alloc(u32, 0),
            .body_font_size = 0,
            .allocator = allocator,
        };
    }

    const line_threshold: f64 = 10;
    const half_page = page_width / 2;
    const column_margin = page_width * 0.05; // 5% margin for column detection

    // Sort all spans by Y (top to bottom), then X (left to right)
    const sorted = try allocator.alloc(TextSpan, spans.len);
    @memcpy(sorted, spans);

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row;
            return a.x0 < b.x0;
        }
    }.cmp);

    // Analyze column structure: count how many lines have both left and right content
    var left_only: usize = 0;
    var right_only: usize = 0;
    var both_columns: usize = 0;
    var current_y: f64 = sorted[0].y0;
    var has_left = false;
    var has_right = false;

    for (sorted) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            // Commit previous line stats
            if (has_left and has_right) {
                both_columns += 1;
            } else if (has_left) {
                left_only += 1;
            } else if (has_right) {
                right_only += 1;
            }
            current_y = span.y0;
            has_left = false;
            has_right = false;
        }
        const mid_x = (span.x0 + span.x1) / 2;
        if (mid_x < half_page - column_margin) {
            has_left = true;
        } else if (mid_x > half_page + column_margin) {
            has_right = true;
        } else {
            has_left = true; // Center content goes to left
        }
    }
    // Count last line
    if (has_left and has_right) {
        both_columns += 1;
    } else if (has_left) {
        left_only += 1;
    } else if (has_right) {
        right_only += 1;
    }

    const total_lines = left_only + right_only + both_columns;
    const is_two_column = both_columns > total_lines / 3; // >33% of lines have both columns

    var result_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len);

    if (is_two_column) {
        // Two-column layout: output left column first, then right column
        var left_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer left_spans.deinit(allocator);
        var right_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer right_spans.deinit(allocator);

        for (sorted) |span| {
            const mid_x = (span.x0 + span.x1) / 2;
            if (mid_x < half_page) {
                try left_spans.append(allocator, span);
            } else {
                try right_spans.append(allocator, span);
            }
        }

        // Output: left column first, then right column
        for (left_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
        for (right_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
    } else {
        // Single column: just use sorted order
        for (sorted) |span| {
            try result_spans.append(allocator, span);
        }
    }

    allocator.free(sorted);

    // Build lines from the ordered spans
    var lines = try std.ArrayList(TextLine).initCapacity(allocator, spans.len / 10);
    var current_line_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 20);
    current_y = if (result_spans.items.len > 0) result_spans.items[0].y0 else 0;

    for (result_spans.items) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            if (current_line_spans.items.len > 0) {
                try lines.append(allocator, try makeLine(allocator, current_line_spans.items));
                current_line_spans.clearRetainingCapacity();
            }
            current_y = span.y0;
        }
        try current_line_spans.append(allocator, span);
    }
    if (current_line_spans.items.len > 0) {
        try lines.append(allocator, try makeLine(allocator, current_line_spans.items));
    }
    current_line_spans.deinit(allocator);

    const body_font_size = estimateBodyFontSize(result_spans.items);
    classifyLines(lines.items, body_font_size);

    // Build column structure
    var columns = try std.ArrayList(TextColumn).initCapacity(allocator, 1);
    if (lines.items.len > 0) {
        if (is_two_column) {
            var left_lines: std.ArrayList(TextLine) = .empty;
            errdefer left_lines.deinit(allocator);
            var right_lines: std.ArrayList(TextLine) = .empty;
            errdefer right_lines.deinit(allocator);

            for (lines.items) |line| {
                const mid_x = (line.bounds.x0 + line.bounds.x1) / 2;
                if (mid_x < half_page) {
                    try left_lines.append(allocator, line);
                } else {
                    try right_lines.append(allocator, line);
                }
            }

            if (left_lines.items.len > 0) {
                const col_lines = try left_lines.toOwnedSlice(allocator);
                try columns.append(allocator, .{
                    .bounds = mergeBounds(col_lines),
                    .lines = col_lines,
                    .index = 0,
                });
            }
            if (right_lines.items.len > 0) {
                const col_lines = try right_lines.toOwnedSlice(allocator);
                try columns.append(allocator, .{
                    .bounds = mergeBounds(col_lines),
                    .lines = col_lines,
                    .index = 1,
                });
            }
        } else {
            const all_lines = try allocator.dupe(TextLine, lines.items);
            try columns.append(allocator, .{
                .bounds = mergeBounds(all_lines),
                .lines = all_lines,
                .index = 0,
            });
        }
    }

    const order = try allocator.alloc(u32, columns.items.len);
    for (order, 0..) |*o, i| {
        o.* = @intCast(i);
    }

    // Detect paragraphs
    var paragraphs = try std.ArrayList(TextParagraph).initCapacity(allocator, columns.items.len * 3);
    for (columns.items, 0..) |col, col_idx| {
        try detectParagraphs(allocator, col.lines, @intCast(col_idx), &paragraphs);
    }

    var blocks: std.ArrayList(LayoutBlock) = .empty;
    errdefer {
        for (blocks.items) |block| allocator.free(block.lines);
        blocks.deinit(allocator);
    }
    try buildBlocks(allocator, paragraphs.items, &blocks);

    const tables = try buildTableGrids(allocator, blocks.items);
    errdefer freeTableGrids(allocator, tables);

    var candidates: std.ArrayList(LayoutCandidate) = .empty;
    errdefer candidates.deinit(allocator);
    try collectCandidates(allocator, lines.items, blocks.items, &candidates);

    const final_spans = try result_spans.toOwnedSlice(allocator);

    return LayoutResult{
        .spans = final_spans,
        .lines = try lines.toOwnedSlice(allocator),
        .columns = try columns.toOwnedSlice(allocator),
        .paragraphs = try paragraphs.toOwnedSlice(allocator),
        .blocks = try blocks.toOwnedSlice(allocator),
        .tables = tables,
        .candidates = try candidates.toOwnedSlice(allocator),
        .reading_order = order,
        .body_font_size = body_font_size,
        .allocator = allocator,
    };
}

/// Detect paragraphs by analyzing line spacing and indentation
fn detectParagraphs(allocator: std.mem.Allocator, col_lines: []const TextLine, col_idx: u32, paragraphs: *std.ArrayList(TextParagraph)) !void {
    if (col_lines.len == 0) return;

    var para_lines = try std.ArrayList(TextLine).initCapacity(allocator, @min(col_lines.len, 20));
    defer para_lines.deinit(allocator);

    var avg_line_spacing: f64 = 0;
    var avg_left_margin: f64 = 0;

    // Calculate average spacing and margins
    if (col_lines.len > 1) {
        var total_spacing: f64 = 0;
        var total_margin: f64 = 0;
        for (col_lines, 0..) |line, i| {
            total_margin += line.bounds.x0;
            if (i > 0) {
                total_spacing += col_lines[i - 1].bounds.y0 - line.bounds.y0;
            }
        }
        avg_line_spacing = total_spacing / @as(f64, @floatFromInt(col_lines.len - 1));
        avg_left_margin = total_margin / @as(f64, @floatFromInt(col_lines.len));
    }

    const para_gap_threshold = avg_line_spacing * 1.5;
    const indent_threshold: f64 = 15;

    for (col_lines, 0..) |line, i| {
        const is_para_break = blk: {
            if (i == 0) break :blk true;

            // Check for large vertical gap
            const prev_line = col_lines[i - 1];
            if (prev_line.role != .body or line.role != .body) break :blk true;
            const gap = prev_line.bounds.y0 - line.bounds.y0;
            if (gap > para_gap_threshold) break :blk true;

            // Check for indentation (first-line indent)
            const indent = line.bounds.x0 - avg_left_margin;
            if (indent > indent_threshold) break :blk true;

            break :blk false;
        };

        if (is_para_break and para_lines.items.len > 0) {
            // Save current paragraph
            const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
            const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
            errdefer allocator.free(para_lines_copy);
            for (para_lines.items, 0..) |para_line, idx| {
                para_lines_copy[idx] = .{
                    .bounds = para_line.bounds,
                    .words = para_line.words,
                    .baseline_y = para_line.baseline_y,
                    .role = para_line.role,
                };
            }
            try paragraphs.append(allocator, .{
                .bounds = mergeBounds(para_lines.items),
                .lines = para_lines_copy,
                .column_index = col_idx,
                .first_line_indent = first_indent,
                .kind = paragraphKind(para_lines.items),
            });
            para_lines.clearRetainingCapacity();
        }

        try para_lines.append(allocator, line);
    }

    // Save final paragraph
    if (para_lines.items.len > 0) {
        const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
        const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
        errdefer allocator.free(para_lines_copy);
        for (para_lines.items, 0..) |para_line, idx| {
            para_lines_copy[idx] = .{
                .bounds = para_line.bounds,
                .words = para_line.words,
                .baseline_y = para_line.baseline_y,
                .role = para_line.role,
            };
        }
        try paragraphs.append(allocator, .{
            .bounds = mergeBounds(para_lines.items),
            .lines = para_lines_copy,
            .column_index = col_idx,
            .first_line_indent = first_indent,
            .kind = paragraphKind(para_lines.items),
        });
    }
}

fn makeLine(allocator: std.mem.Allocator, spans: []const TextSpan) !TextLine {
    // Estimate words as ~1 per 2-3 spans
    const estimated_words = @max(1, spans.len / 2);
    var words = try std.ArrayList(TextWord).initCapacity(allocator, estimated_words);
    var current_word_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 8);
    const word_gap: f64 = 5;

    var prev_x1: f64 = spans[0].x0;
    for (spans) |span| {
        if (span.x0 - prev_x1 > word_gap and current_word_spans.items.len > 0) {
            try words.append(allocator, try makeWord(allocator, current_word_spans.items));
            current_word_spans.clearRetainingCapacity();
        }
        try current_word_spans.append(allocator, span);
        prev_x1 = span.x1;
    }
    if (current_word_spans.items.len > 0) {
        try words.append(allocator, try makeWord(allocator, current_word_spans.items));
    }
    current_word_spans.deinit(allocator);

    const bounds = mergeSpanBounds(spans);
    return TextLine{
        .bounds = bounds,
        .words = try words.toOwnedSlice(allocator),
        .baseline_y = bounds.y0,
        .role = .body,
    };
}

fn estimateBodyFontSize(spans: []const TextSpan) f64 {
    if (spans.len == 0) return 12;

    var best_size = spans[0].font_size;
    var best_weight: usize = 0;

    for (spans) |candidate| {
        const bucket = @round(candidate.font_size * 2) / 2;
        var weight: usize = 0;
        for (spans) |span| {
            const span_bucket = @round(span.font_size * 2) / 2;
            if (@abs(span_bucket - bucket) < 0.01) {
                weight += span.text.len;
            }
        }
        if (weight > best_weight) {
            best_weight = weight;
            best_size = candidate.font_size;
        }
    }

    return best_size;
}

fn classifyLines(lines: []TextLine, body_font_size: f64) void {
    if (lines.len == 0) return;

    var min_y: f64 = lines[0].bounds.y0;
    var max_y: f64 = lines[0].bounds.y1;
    for (lines) |line| {
        min_y = @min(min_y, line.bounds.y0);
        max_y = @max(max_y, line.bounds.y1);
    }
    const content_height = @max(1, max_y - min_y);

    for (lines, 0..) |*line, line_index| {
        const text_len = lineTextLen(line);
        const top_band = line.bounds.y0 >= min_y + content_height * 0.92;
        const bottom_band = line.bounds.y1 <= min_y + content_height * 0.08;

        line.role = .body;
        const can_detect_furniture = lines.len >= 4;
        if (lineStartsWithCaption(line)) {
            line.role = if (lineStartsWithFigureCaption(line)) .figure_candidate else .caption;
        } else if (lineStartsWithListMarker(line)) {
            line.role = .list_item;
        } else if (lineLooksLikeFormula(line, body_font_size)) {
            line.role = .formula_candidate;
        } else if (lineLooksLikeTable(line)) {
            line.role = .table_candidate;
        } else if (line.bounds.font_size >= body_font_size * 1.18 and text_len <= 160) {
            line.role = .heading;
        } else if (can_detect_furniture and top_band and line_index <= 1 and text_len <= 120) {
            line.role = .header;
        } else if (can_detect_furniture and bottom_band and line_index + 2 >= lines.len and text_len <= 120) {
            line.role = .footer;
        }

        if ((line.role == .body or line.role == .list_item) and line_index > 0 and lineContinuesTable(&lines[line_index - 1], line)) {
            line.role = .table_candidate;
        }
    }
}

fn lineContinuesTable(previous: *const TextLine, current: *const TextLine) bool {
    if (previous.role != .table_candidate) return false;
    if (current.words.len == 0) return false;

    const gap = previous.bounds.y0 - current.bounds.y0;
    const max_gap = @max(previous.bounds.font_size, current.bounds.font_size) * 1.45;
    if (gap < 0 or gap > max_gap) return false;

    const indent = current.bounds.x0 - previous.bounds.x0;
    return indent >= -current.bounds.font_size * 0.5 and indent <= current.bounds.font_size * 2.5;
}

fn paragraphKind(lines: []const TextLine) BlockKind {
    if (lines.len == 0) return .paragraph;
    if (lines.len == 1) return blockKindForRole(lines[0].role);

    var table_count: usize = 0;
    var formula_count: usize = 0;
    var list_count: usize = 0;
    for (lines) |line| {
        switch (line.role) {
            .table_candidate => table_count += 1,
            .formula_candidate => formula_count += 1,
            .list_item => list_count += 1,
            else => {},
        }
    }
    if (table_count >= 2 and table_count * 2 >= lines.len) return .table_candidate;
    if (formula_count >= 1 and formula_count * 2 >= lines.len) return .formula_candidate;
    if (list_count == lines.len) return .list_item;
    return .paragraph;
}

fn blockKindForRole(role: LineRole) BlockKind {
    return switch (role) {
        .body => .paragraph,
        .heading => .heading,
        .list_item => .list_item,
        .header => .header,
        .footer => .footer,
        .caption => .caption,
        .table_candidate => .table_candidate,
        .formula_candidate => .formula_candidate,
        .figure_candidate => .figure_candidate,
    };
}

fn buildBlocks(allocator: std.mem.Allocator, paragraphs: []const TextParagraph, blocks: *std.ArrayList(LayoutBlock)) !void {
    for (paragraphs) |para| {
        if (para.lines.len == 0) continue;

        if (para.kind == .paragraph or para.kind == .table_candidate or para.kind == .formula_candidate) {
            const block_lines = try copyLineShells(allocator, para.lines);
            errdefer allocator.free(block_lines);
            try blocks.append(allocator, .{
                .bounds = para.bounds,
                .lines = block_lines,
                .column_index = para.column_index,
                .kind = para.kind,
                .confidence = confidenceForKind(para.kind),
                .removed = false,
            });
            continue;
        }

        for (para.lines) |line| {
            const block_lines = try copyLineShells(allocator, (&line)[0..1]);
            errdefer allocator.free(block_lines);
            const kind = blockKindForRole(line.role);
            try blocks.append(allocator, .{
                .bounds = line.bounds,
                .lines = block_lines,
                .column_index = para.column_index,
                .kind = kind,
                .confidence = confidenceForKind(kind),
                .removed = kind == .header or kind == .footer,
            });
        }
    }
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    lines: []const TextLine,
    blocks: []const LayoutBlock,
    candidates: *std.ArrayList(LayoutCandidate),
) !void {
    for (lines, 0..) |line, line_index| {
        switch (line.role) {
            .table_candidate => try appendCandidate(allocator, lines, blocks, candidates, .table, &line, line_index, 0.72),
            .formula_candidate => try appendCandidate(allocator, lines, blocks, candidates, .formula, &line, line_index, 0.76),
            .figure_candidate => try appendCandidate(allocator, lines, blocks, candidates, .figure, &line, line_index, 0.68),
            else => {},
        }
    }
}

fn appendCandidate(
    allocator: std.mem.Allocator,
    lines: []const TextLine,
    blocks: []const LayoutBlock,
    candidates: *std.ArrayList(LayoutCandidate),
    kind: CandidateKind,
    line: *const TextLine,
    line_index: usize,
    confidence: f32,
) !void {
    const caption_line_index = findCaptionLine(lines, line_index, kind);
    const caption_block_index = if (caption_line_index) |caption_index|
        findBlockIndex(blocks, &lines[caption_index])
    else
        null;

    try candidates.append(allocator, .{
        .kind = kind,
        .bounds = line.bounds,
        .line_index = @intCast(line_index),
        .block_index = findBlockIndex(blocks, line),
        .caption_line_index = caption_line_index,
        .caption_block_index = caption_block_index,
        .confidence = confidence,
    });
}

fn findCaptionLine(lines: []const TextLine, line_index: usize, kind: CandidateKind) ?u32 {
    if (line_index < lines.len and captionKind(&lines[line_index]) == kind) return @intCast(line_index);

    const max_distance: usize = 3;
    var distance: usize = 1;
    while (distance <= max_distance) : (distance += 1) {
        if (line_index >= distance) {
            const before_index = line_index - distance;
            if (captionKind(&lines[before_index]) == kind) return @intCast(before_index);
        }
        const after_index = line_index + distance;
        if (after_index < lines.len and captionKind(&lines[after_index]) == kind) return @intCast(after_index);
    }

    return null;
}

fn captionKind(line: *const TextLine) ?CandidateKind {
    const first = firstText(line);
    if (std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Chart"))
    {
        return .figure;
    }
    if (std.mem.startsWith(u8, first, "Table")) return .table;
    if (std.mem.startsWith(u8, first, "Equation") or std.mem.startsWith(u8, first, "Eq.")) return .formula;
    return null;
}

fn findBlockIndex(blocks: []const LayoutBlock, line: *const TextLine) ?u32 {
    for (blocks, 0..) |block, block_index| {
        if (containsBounds(block.bounds, line.bounds)) return @intCast(block_index);
    }
    return null;
}

fn containsBounds(outer: TextSpan, inner: TextSpan) bool {
    const epsilon = 0.01;
    return inner.x0 + epsilon >= outer.x0 and
        inner.x1 <= outer.x1 + epsilon and
        inner.y0 + epsilon >= outer.y0 and
        inner.y1 <= outer.y1 + epsilon;
}

fn copyLineShells(allocator: std.mem.Allocator, lines: []const TextLine) ![]TextLine {
    const out = try allocator.alloc(TextLine, lines.len);
    for (lines, 0..) |line, i| {
        out[i] = .{
            .bounds = line.bounds,
            .words = line.words,
            .baseline_y = line.baseline_y,
            .role = line.role,
        };
    }
    return out;
}

fn confidenceForKind(kind: BlockKind) f32 {
    return switch (kind) {
        .paragraph => 0.64,
        .heading => 0.72,
        .list_item => 0.74,
        .header, .footer => 0.62,
        .caption => 0.76,
        .table_candidate => 0.70,
        .formula_candidate => 0.74,
        .figure_candidate => 0.68,
    };
}

fn appendLineText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), line: *const TextLine) !void {
    var wrote = false;
    for (line.words, 0..) |word, word_index| {
        if (word_index > 0 and wrote) {
            try output.append(allocator, ' ');
        }
        for (word.spans) |span| {
            try output.appendSlice(allocator, span.text);
            wrote = true;
        }
    }
}

fn buildTableGrids(allocator: std.mem.Allocator, blocks: []const LayoutBlock) ![]TableGrid {
    var tables: std.ArrayList(TableGrid) = .empty;
    errdefer {
        freeTableGrids(allocator, tables.items);
        tables.deinit(allocator);
    }

    var block_index: usize = 0;
    while (block_index < blocks.len) {
        const block = blocks[block_index];
        if (block.kind != .table_candidate) {
            block_index += 1;
            continue;
        }

        var run_end = block_index + 1;
        while (run_end < blocks.len and
            blocks[run_end].kind == .table_candidate and
            blocks[run_end].column_index == block.column_index and
            !blocks[run_end].removed) : (run_end += 1)
        {}

        if (run_end - block_index > 1) {
            var line_count: usize = 0;
            for (blocks[block_index..run_end]) |run_block| line_count += run_block.lines.len;

            const run_lines = try allocator.alloc(TextLine, line_count);
            defer allocator.free(run_lines);
            var line_index: usize = 0;
            for (blocks[block_index..run_end]) |run_block| {
                for (run_block.lines) |line| {
                    run_lines[line_index] = line;
                    line_index += 1;
                }
            }

            const run_block = LayoutBlock{
                .bounds = mergeBounds(run_lines),
                .lines = run_lines,
                .column_index = block.column_index,
                .kind = .table_candidate,
                .confidence = block.confidence,
                .removed = false,
            };
            if (try buildTableGridForBlock(allocator, run_block, @intCast(block_index))) |built_table| {
                var table = built_table;
                table.block_count = run_end - block_index;
                try tables.append(allocator, table);
                block_index = run_end;
                continue;
            }
        }

        if (try buildTableGridForBlock(allocator, block, @intCast(block_index))) |table| {
            try tables.append(allocator, table);
        }
        block_index += 1;
    }

    return tables.toOwnedSlice(allocator);
}

fn freeTableGrid(allocator: std.mem.Allocator, table: TableGrid) void {
    for (table.rows) |row| freeTableRow(allocator, row);
    allocator.free(table.rows);
}

fn freeTableRow(allocator: std.mem.Allocator, row: TableRow) void {
    for (row.cells) |cell| allocator.free(cell.text);
    allocator.free(row.cells);
}

fn freeTableGrids(allocator: std.mem.Allocator, tables: []const TableGrid) void {
    for (tables) |table| freeTableGrid(allocator, table);
}

const ColumnAnchor = struct {
    x: f64,
    count: usize,
};

fn buildTableGridForBlock(
    allocator: std.mem.Allocator,
    block: LayoutBlock,
    block_index: u32,
) !?TableGrid {
    if (block.lines.len < 2) return null;

    var anchors: std.ArrayList(ColumnAnchor) = .empty;
    defer anchors.deinit(allocator);

    const tolerance = @max(6.0, block.bounds.font_size * 0.75);
    var table_line_count: usize = 0;
    var max_words: usize = 0;
    for (block.lines) |line| {
        if (!lineContributesColumnAnchors(&line)) continue;
        table_line_count += 1;
        max_words = @max(max_words, line.words.len);
        try addLineColumnAnchors(allocator, &anchors, &line, tolerance);
    }

    if (table_line_count < 2 or max_words < 2 or anchors.items.len < 2) return null;
    std.mem.sort(ColumnAnchor, anchors.items, {}, struct {
        fn cmp(_: void, a: ColumnAnchor, b: ColumnAnchor) bool {
            return a.x < b.x;
        }
    }.cmp);

    const column_count = anchors.items.len;
    var rows: std.ArrayList(TableRow) = .empty;
    errdefer {
        for (rows.items) |row| freeTableRow(allocator, row);
        rows.deinit(allocator);
    }

    for (block.lines) |line| {
        if (line.words.len == 0) continue;
        const row = try buildTableRow(allocator, line, anchors.items, block.bounds, @intCast(rows.items.len));
        const occupied_cells = occupiedCellCount(row);
        if (occupied_cells >= 2 or rows.items.len == 0) {
            try rows.append(allocator, row);
        } else {
            try mergeContinuationRow(allocator, &rows.items[rows.items.len - 1], row);
            freeTableRow(allocator, row);
        }
    }

    if (rows.items.len < 2) {
        for (rows.items) |row| freeTableRow(allocator, row);
        rows.deinit(allocator);
        return null;
    }

    return TableGrid{
        .bounds = block.bounds,
        .block_index = block_index,
        .block_count = 1,
        .rows = try rows.toOwnedSlice(allocator),
        .column_count = column_count,
        .confidence = block.confidence,
    };
}

fn lineContributesColumnAnchors(line: *const TextLine) bool {
    if (line.words.len < 2) return false;
    var numeric_words: usize = 0;
    for (line.words) |word| {
        if (wordHasDigit(word)) numeric_words += 1;
    }
    if (numeric_words > 0) return true;
    return lineLooksLikeTable(line);
}

fn addLineColumnAnchors(
    allocator: std.mem.Allocator,
    anchors: *std.ArrayList(ColumnAnchor),
    line: *const TextLine,
    tolerance: f64,
) !void {
    var has_numeric = false;
    for (line.words) |word| {
        if (wordHasDigit(word)) {
            has_numeric = true;
            break;
        }
    }

    if (!has_numeric) {
        for (line.words) |word| try addColumnAnchor(allocator, anchors, word.bounds.x0, tolerance);
        return;
    }

    var added_label_anchor = false;
    for (line.words) |word| {
        if (wordHasDigit(word)) {
            try addColumnAnchor(allocator, anchors, word.bounds.x0, tolerance);
        } else if (!added_label_anchor) {
            try addColumnAnchor(allocator, anchors, word.bounds.x0, tolerance);
            added_label_anchor = true;
        }
    }
}

fn addColumnAnchor(
    allocator: std.mem.Allocator,
    anchors: *std.ArrayList(ColumnAnchor),
    x: f64,
    tolerance: f64,
) !void {
    for (anchors.items) |*anchor| {
        if (@abs(anchor.x - x) <= tolerance) {
            const old_count_f: f64 = @floatFromInt(anchor.count);
            const new_count = anchor.count + 1;
            anchor.x = ((anchor.x * old_count_f) + x) / @as(f64, @floatFromInt(new_count));
            anchor.count = new_count;
            return;
        }
    }
    try anchors.append(allocator, .{ .x = x, .count = 1 });
}

fn buildTableRow(
    allocator: std.mem.Allocator,
    line: TextLine,
    anchors: []const ColumnAnchor,
    table_bounds: TextSpan,
    row_index: u32,
) !TableRow {
    if (lineLooksLikeMergedTextRow(&line, anchors.len, table_bounds)) {
        return buildMergedTextRow(allocator, line, anchors, row_index);
    }

    var texts = try allocator.alloc(std.ArrayList(u8), anchors.len);
    defer allocator.free(texts);
    for (texts) |*text| text.* = .empty;
    defer for (texts) |*text| text.deinit(allocator);

    var bounds = try allocator.alloc(?TextSpan, anchors.len);
    defer allocator.free(bounds);
    @memset(bounds, null);

    for (line.words) |word| {
        const column_index = nearestColumn(anchors, word.bounds.x0);
        if (texts[column_index].items.len > 0) try texts[column_index].append(allocator, ' ');
        try appendWordText(allocator, &texts[column_index], word);
        bounds[column_index] = if (bounds[column_index]) |existing|
            mergeTwoBounds(existing, word.bounds)
        else
            word.bounds;
    }

    const cells = try allocator.alloc(TableCell, anchors.len);
    errdefer {
        for (cells) |cell| allocator.free(cell.text);
        allocator.free(cells);
    }

    for (cells, 0..) |*cell, column_index| {
        const text = try texts[column_index].toOwnedSlice(allocator);
        cell.* = .{
            .bounds = bounds[column_index] orelse emptyCellBounds(line, @intCast(column_index)),
            .text = text,
            .row_index = row_index,
            .column_index = @intCast(column_index),
            .confidence = if (text.len > 0) 0.78 else 0.45,
        };
    }

    return .{
        .bounds = line.bounds,
        .cells = cells,
        .row_index = row_index,
    };
}

fn lineLooksLikeMergedTextRow(line: *const TextLine, column_count: usize, table_bounds: TextSpan) bool {
    if (column_count < 2 or line.words.len == 0) return false;
    for (line.words) |word| {
        if (wordHasDigit(word)) return false;
    }
    const table_width = @max(1, table_bounds.x1 - table_bounds.x0);
    const line_width = line.bounds.x1 - line.bounds.x0;
    return line_width <= table_width * 0.65 or line.words.len < column_count;
}

fn buildMergedTextRow(
    allocator: std.mem.Allocator,
    line: TextLine,
    anchors: []const ColumnAnchor,
    row_index: u32,
) !TableRow {
    const cells = try allocator.alloc(TableCell, anchors.len);
    errdefer {
        for (cells) |cell| allocator.free(cell.text);
        allocator.free(cells);
    }

    const target_column = nearestColumn(anchors, line.bounds.x0);
    for (cells, 0..) |*cell, column_index| {
        const text = if (column_index == target_column)
            try lineTextOwned(allocator, &line)
        else
            try allocator.alloc(u8, 0);
        cell.* = .{
            .bounds = if (column_index == target_column) line.bounds else emptyCellBounds(line, @intCast(column_index)),
            .text = text,
            .row_index = row_index,
            .column_index = @intCast(column_index),
            .confidence = if (text.len > 0) 0.72 else 0.45,
        };
    }

    return .{
        .bounds = line.bounds,
        .cells = cells,
        .row_index = row_index,
    };
}

fn lineTextOwned(allocator: std.mem.Allocator, line: *const TextLine) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendLineText(allocator, &out, line);
    return out.toOwnedSlice(allocator);
}

fn occupiedCellCount(row: TableRow) usize {
    var count: usize = 0;
    for (row.cells) |cell| {
        if (cell.text.len > 0) count += 1;
    }
    return count;
}

fn mergeContinuationRow(allocator: std.mem.Allocator, target: *TableRow, continuation: TableRow) !void {
    target.bounds = mergeTwoBounds(target.bounds, continuation.bounds);
    for (continuation.cells, 0..) |cell, column_index| {
        if (cell.text.len == 0) continue;
        try appendCellContinuation(allocator, &target.cells[column_index], cell);
    }
}

fn appendCellContinuation(allocator: std.mem.Allocator, target: *TableCell, continuation: TableCell) !void {
    if (target.text.len == 0) {
        const text = try allocator.dupe(u8, continuation.text);
        allocator.free(target.text);
        target.text = text;
        target.bounds = continuation.bounds;
        target.confidence = @min(target.confidence, continuation.confidence);
        return;
    }

    var merged: std.ArrayList(u8) = .empty;
    errdefer merged.deinit(allocator);
    try merged.ensureTotalCapacity(allocator, target.text.len + 1 + continuation.text.len);
    try merged.appendSlice(allocator, target.text);
    try merged.append(allocator, ' ');
    try merged.appendSlice(allocator, continuation.text);

    allocator.free(target.text);
    target.text = try merged.toOwnedSlice(allocator);
    target.bounds = mergeTwoBounds(target.bounds, continuation.bounds);
    target.confidence = @min(target.confidence, continuation.confidence);
}

fn nearestColumn(anchors: []const ColumnAnchor, x: f64) usize {
    var best_index: usize = 0;
    var best_distance = @abs(anchors[0].x - x);
    for (anchors[1..], 1..) |anchor, index| {
        const distance = @abs(anchor.x - x);
        if (distance < best_distance) {
            best_distance = distance;
            best_index = index;
        }
    }
    return best_index;
}

fn appendWordText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), word: TextWord) !void {
    for (word.spans) |span| {
        try output.appendSlice(allocator, span.text);
    }
}

fn mergeTwoBounds(a: TextSpan, b: TextSpan) TextSpan {
    return TextSpan.init(.{
        .page_index = a.page_index,
        .bbox = .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        },
        .text = a.text,
        .source = a.source,
        .confidence = @min(a.confidence, b.confidence),
        .font = a.font,
        .block_id = a.block_id,
        .line_id = a.line_id,
        .mcid = a.mcid,
    });
}

fn emptyCellBounds(line: TextLine, column_index: u32) TextSpan {
    _ = column_index;
    return TextSpan.init(.{
        .page_index = line.bounds.page_index,
        .bbox = .{
            .x0 = line.bounds.x0,
            .y0 = line.bounds.y0,
            .x1 = line.bounds.x0,
            .y1 = line.bounds.y1,
        },
        .text = "",
        .source = line.bounds.source,
        .confidence = 0.45,
        .font = line.bounds.font,
        .block_id = line.bounds.block_id,
        .line_id = line.bounds.line_id,
        .mcid = line.bounds.mcid,
    });
}

fn appendTablePlain(allocator: std.mem.Allocator, output: *std.ArrayList(u8), table: *const TableGrid) !void {
    for (table.rows, 0..) |row, row_index| {
        if (row_index > 0) try output.append(allocator, '\n');
        var wrote_cell = false;
        for (row.cells) |cell| {
            if (cell.text.len == 0) continue;
            if (wrote_cell) try output.append(allocator, ' ');
            try output.appendSlice(allocator, cell.text);
            wrote_cell = true;
        }
    }
}

pub fn appendTableMarkdown(allocator: std.mem.Allocator, output: *std.ArrayList(u8), table: *const TableGrid) !void {
    if (table.rows.len == 0) return;
    try appendMarkdownRow(allocator, output, table.rows[0]);
    try output.append(allocator, '|');
    for (0..table.column_count) |_| try output.appendSlice(allocator, " --- |");
    try output.append(allocator, '\n');
    for (table.rows[1..]) |row| try appendMarkdownRow(allocator, output, row);
}

fn appendMarkdownRow(allocator: std.mem.Allocator, output: *std.ArrayList(u8), row: TableRow) !void {
    try output.append(allocator, '|');
    for (row.cells) |cell| {
        try output.append(allocator, ' ');
        try appendMarkdownEscaped(allocator, output, cell.text);
        try output.appendSlice(allocator, " |");
    }
    try output.append(allocator, '\n');
}

fn appendMarkdownEscaped(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        if (byte == '|') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
}

fn endsWithSoftHyphen(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[text.len - 1] != '-') return false;
    if (text.len == 1) return true;
    const prev = text[text.len - 2];
    return std.ascii.isAlphabetic(prev);
}

fn lineStartsLowercase(line: *const TextLine) bool {
    for (line.words) |word| {
        for (word.spans) |span| {
            if (span.text.len == 0) continue;
            return std.ascii.isLower(span.text[0]);
        }
    }
    return false;
}

fn lineTextLen(line: *const TextLine) usize {
    var len: usize = 0;
    for (line.words) |word| {
        for (word.spans) |span| len += span.text.len;
        if (len > 0) len += 1;
    }
    return len;
}

fn firstText(line: *const TextLine) []const u8 {
    for (line.words) |word| {
        for (word.spans) |span| {
            if (span.text.len > 0) return span.text;
        }
    }
    return "";
}

fn lineStartsWithCaption(line: *const TextLine) bool {
    const first = firstText(line);
    return std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Table") or
        std.mem.startsWith(u8, first, "Chart") or
        std.mem.startsWith(u8, first, "Equation") or
        std.mem.startsWith(u8, first, "Eq.");
}

fn lineStartsWithFigureCaption(line: *const TextLine) bool {
    const first = firstText(line);
    return std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Chart");
}

fn lineStartsWithListMarker(line: *const TextLine) bool {
    const first = firstText(line);
    if (first.len == 0) return false;
    if (std.mem.eql(u8, first, "-") or std.mem.eql(u8, first, "*")) return true;
    if (std.mem.startsWith(u8, first, "•") or std.mem.startsWith(u8, first, "◦")) return true;
    if (!std.ascii.isDigit(first[0])) return false;

    var i: usize = 1;
    while (i < first.len and i < 4 and std.ascii.isDigit(first[i])) : (i += 1) {}
    return i < first.len and (first[i] == '.' or first[i] == ')');
}

fn lineLooksLikeFormula(line: *const TextLine, body_font_size: f64) bool {
    var text_bytes: usize = 0;
    var math_marks: usize = 0;
    var small_offset_count: usize = 0;

    for (line.words) |word| {
        for (word.spans) |span| {
            text_bytes += span.text.len;
            for (span.text) |byte| {
                if (byte == '=' or byte == '+' or byte == '*' or byte == '/' or byte == '<' or byte == '>' or byte == '^' or byte == '_') {
                    math_marks += 1;
                }
            }
            if (containsMathUnicode(span.text)) math_marks += 2;
            if (span.font_size < body_font_size * 0.82 and @abs(span.y0 - line.baseline_y) > body_font_size * 0.15) {
                small_offset_count += 1;
            }
        }
    }

    if (small_offset_count > 0 and math_marks > 0) return true;
    if (text_bytes == 0) return false;
    return math_marks * 4 >= text_bytes and lineTextLen(line) <= 120;
}

fn containsMathUnicode(text: []const u8) bool {
    const marks = [_][]const u8{ "∑", "∫", "√", "≤", "≥", "≈", "∞", "π", "α", "β", "γ", "Δ" };
    for (marks) |mark| {
        if (std.mem.indexOf(u8, text, mark) != null) return true;
    }
    return false;
}

fn lineLooksLikeTable(line: *const TextLine) bool {
    if (line.words.len < 3) return false;

    var numeric_words: usize = 0;
    var wide_gaps: usize = 0;
    var prev_x1 = line.words[0].bounds.x1;

    for (line.words, 0..) |word, i| {
        if (wordHasDigit(word)) numeric_words += 1;
        if (i > 0) {
            const gap = word.bounds.x0 - prev_x1;
            if (gap > line.bounds.font_size * 1.8) wide_gaps += 1;
        }
        prev_x1 = word.bounds.x1;
    }

    return wide_gaps >= 2 or numeric_words * 2 >= line.words.len;
}

fn wordHasDigit(word: TextWord) bool {
    for (word.spans) |span| {
        for (span.text) |byte| {
            if (std.ascii.isDigit(byte)) return true;
        }
    }
    return false;
}

fn makeWord(allocator: std.mem.Allocator, spans: []const TextSpan) !TextWord {
    const spans_copy = try allocator.dupe(TextSpan, spans);
    return TextWord{
        .bounds = mergeSpanBounds(spans),
        .spans = spans_copy,
    };
}

fn mergeSpanBounds(spans: []const TextSpan) TextSpan {
    var x0 = spans[0].x0;
    var y0 = spans[0].y0;
    var x1 = spans[0].x1;
    var y1 = spans[0].y1;

    for (spans[1..]) |s| {
        x0 = @min(x0, s.x0);
        y0 = @min(y0, s.y0);
        x1 = @max(x1, s.x1);
        y1 = @max(y1, s.y1);
    }

    return TextSpan.init(.{
        .page_index = spans[0].page_index,
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = spans[0].text,
        .source = spans[0].source,
        .confidence = spans[0].confidence,
        .font = spans[0].font,
        .block_id = spans[0].block_id,
        .line_id = spans[0].line_id,
        .mcid = spans[0].mcid,
    });
}

fn mergeBounds(lines: []const TextLine) TextSpan {
    var x0 = lines[0].bounds.x0;
    var y0 = lines[0].bounds.y0;
    var x1 = lines[0].bounds.x1;
    var y1 = lines[0].bounds.y1;

    for (lines[1..]) |l| {
        x0 = @min(x0, l.bounds.x0);
        y0 = @min(y0, l.bounds.y0);
        x1 = @max(x1, l.bounds.x1);
        y1 = @max(y1, l.bounds.y1);
    }

    return TextSpan.init(.{
        .page_index = lines[0].bounds.page_index,
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = "",
        .source = lines[0].bounds.source,
        .confidence = lines[0].bounds.confidence,
        .font = lines[0].bounds.font,
        .block_id = lines[0].bounds.block_id,
        .line_id = lines[0].bounds.line_id,
        .mcid = lines[0].bounds.mcid,
    });
}

test "TextSpan carries provenance and semantic identity" {
    const span = TextSpan.init(.{
        .page_index = 3,
        .bbox = .{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 42 },
        .text = "alpha",
        .source = .native_pdf,
        .confidence = 0.98,
        .font = .{ .name = "F1", .size = 12, .encoding = "WinAnsiEncoding", .has_to_unicode = true },
        .block_id = 7,
        .line_id = 9,
        .mcid = 11,
    });

    try std.testing.expectEqual(@as(u32, 3), span.page_index);
    try std.testing.expectEqual(@as(u32, 3), span.page);
    try std.testing.expectEqual(@as(f64, 10), span.bbox.x0);
    try std.testing.expectEqual(@as(f64, 30), span.x1);
    try std.testing.expectEqual(SourceKind.native_pdf, span.source);
    try std.testing.expectEqual(@as(f32, 0.98), span.confidence);
    try std.testing.expectEqualStrings("F1", span.font.name.?);
    try std.testing.expectEqual(@as(u32, 7), span.block_id.?);
    try std.testing.expectEqual(@as(u32, 9), span.line_id.?);
    try std.testing.expectEqual(@as(i32, 11), span.mcid.?);
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) TextSpan {
    return TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = y1 - y0, .has_to_unicode = true },
    });
}

fn testSpanSized(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64, size: f64) TextSpan {
    return TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = size, .has_to_unicode = true },
    });
}

test "layout reconstruction clusters lines and dehyphenates paragraphs" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("The", 72, 700, 92, 712),
        testSpan("docu-", 98, 700, 132, 712),
        testSpan("ment", 72, 686, 104, 698),
        testSpan("works.", 110, 686, 150, 698),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("The document works.", text);
}

test "layout reconstruction records two columns in reading order" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("L1", 72, 700, 90, 712),
        testSpan("R1", 330, 700, 348, 712),
        testSpan("L2", 72, 680, 90, 692),
        testSpan("R2", 330, 680, 348, 692),
        testSpan("L3", 72, 660, 90, 672),
        testSpan("R3", 330, 660, 348, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
    try std.testing.expectEqual(@as(u32, 0), result.reading_order[0]);
    try std.testing.expectEqual(@as(u32, 1), result.reading_order[1]);

    const text = try result.getTextInOrder(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("L1\nL2\nL3\nR1\nR2\nR3", text);
}

test "layout reconstruction detects headings and list items" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpanSized("A", 72, 720, 82, 738, 18),
        testSpanSized("Heading", 90, 720, 160, 738, 18),
        testSpan("Body", 72, 690, 104, 702),
        testSpan("text", 110, 690, 136, 702),
        testSpan("1.", 72, 660, 86, 672),
        testSpan("First", 96, 660, 126, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(LineRole.heading, result.lines[0].role);
    try std.testing.expectEqual(LineRole.list_item, result.lines[2].role);
    try std.testing.expectEqual(BlockKind.heading, result.blocks[0].kind);
}

test "layout reconstruction suppresses header and footer candidates" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Chapter", 72, 760, 122, 772),
        testSpan("The", 72, 700, 92, 712),
        testSpan("body", 98, 700, 130, 712),
        testSpan("continues", 72, 682, 128, 694),
        testSpan("42", 300, 60, 314, 72),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(LineRole.header, result.lines[0].role);
    try std.testing.expectEqual(LineRole.footer, result.lines[result.lines.len - 1].role);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Chapter") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "42") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The body continues") != null);
}

test "layout reconstruction emits table formula and figure candidates" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Body", 72, 740, 106, 752),
        testSpan("intro", 112, 740, 146, 752),
        testSpan("Table", 72, 720, 112, 732),
        testSpan("1.", 118, 720, 132, 732),
        testSpan("2019", 72, 700, 104, 712),
        testSpan("120", 180, 700, 204, 712),
        testSpan("240", 300, 700, 324, 712),
        testSpan("E", 72, 660, 80, 672),
        testSpan("=", 86, 660, 92, 672),
        testSpan("mc", 98, 660, 114, 672),
        testSpanSized("2", 116, 668, 122, 674, 7),
        testSpan("Figure", 72, 620, 112, 632),
        testSpan("1.", 118, 620, 132, 632),
        testSpan("System", 138, 620, 180, 632),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    var saw_table = false;
    var saw_formula = false;
    var saw_figure = false;
    for (result.candidates) |candidate| {
        switch (candidate.kind) {
            .table => {
                saw_table = true;
                try std.testing.expect(candidate.caption_line_index != null);
                try std.testing.expect(candidate.caption_block_index != null);
            },
            .formula => saw_formula = true,
            .figure => {
                saw_figure = true;
                try std.testing.expectEqual(candidate.line_index, candidate.caption_line_index.?);
            },
        }
    }

    try std.testing.expect(saw_table);
    try std.testing.expect(saw_formula);
    try std.testing.expect(saw_figure);
}

test "layout reconstruction builds table grid cells from aligned financial rows" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Table", 72, 740, 112, 752),
        testSpan("1.", 118, 740, 132, 752),
        testSpan("Year", 80, 720, 110, 732),
        testSpan("Revenue", 200, 720, 250, 732),
        testSpan("Margin", 320, 720, 365, 732),
        testSpan("2019", 80, 700, 112, 712),
        testSpan("100", 200, 700, 224, 712),
        testSpan("20", 320, 700, 336, 712),
        testSpan("2020", 80, 680, 112, 692),
        testSpan("125", 200, 680, 224, 692),
        testSpan("23", 320, 680, 336, 692),
        testSpan("2021", 80, 660, 112, 672),
        testSpan("140", 200, 660, 224, 672),
        testSpan("25", 320, 660, 336, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Year", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Revenue", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Margin", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("2021", table.rows[3].cells[0].text);
    try std.testing.expectEqualStrings("140", table.rows[3].cells[1].text);
    try std.testing.expectEqualStrings("25", table.rows[3].cells[2].text);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Year Revenue Margin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2021 140 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "YearRevenueMargin") == null);

    var markdown: std.ArrayList(u8) = .empty;
    defer markdown.deinit(allocator);
    try appendTableMarkdown(allocator, &markdown, &table);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "| Year | Revenue | Margin |") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "| 2021 | 140 | 25 |") != null);
}

test "table grid merges multiline labels negatives and footnotes into cells" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Revenue", 190, 720, 242, 732),
        testSpan("Variance", 280, 720, 336, 732),
        testSpan("Subscriptions", 80, 700, 164, 712),
        testSpan("1,200", 190, 700, 230, 712),
        testSpan("(35)", 280, 700, 312, 712),
        testSpan("North America", 94, 686, 184, 698),
        testSpan("Services*", 80, 666, 144, 678),
        testSpan("-250", 190, 666, 222, 678),
        testSpan("12", 280, 666, 296, 678),
        testSpan("* excludes setup fees", 94, 652, 220, 664),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Subscriptions North America", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(35)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("Services* * excludes setup fees", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-250", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("12", table.rows[2].cells[2].text);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Subscriptions North America 1,200 (35)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Services* * excludes setup fees -250 12") != null);
}

test "table grid preserves multiword merged labels without inventing columns" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Revenue", 180, 720, 232, 732),
        testSpan("Expense", 260, 720, 310, 732),
        testSpan("Net", 320, 720, 344, 732),
        testSpan("Total", 80, 700, 116, 712),
        testSpan("revenue", 122, 700, 174, 712),
        testSpan("1,200", 180, 700, 220, 712),
        testSpan("(950)", 260, 700, 300, 712),
        testSpan("250", 320, 700, 344, 712),
        testSpan("Services*", 80, 680, 144, 692),
        testSpan("-300", 180, 680, 212, 692),
        testSpan("(450)", 260, 680, 300, 692),
        testSpan("(750)", 320, 680, 360, 692),
        testSpan("*", 94, 666, 100, 678),
        testSpan("excludes", 108, 666, 160, 678),
        testSpan("setup", 168, 666, 206, 678),
        testSpan("fees", 214, 666, 244, 678),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 4), table.column_count);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Revenue", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Expense", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("Net", table.rows[0].cells[3].text);
    try std.testing.expectEqualStrings("Total revenue", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(950)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("250", table.rows[1].cells[3].text);
    try std.testing.expectEqualStrings("Services* * excludes setup fees", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-300", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("(450)", table.rows[2].cells[2].text);
    try std.testing.expectEqualStrings("(750)", table.rows[2].cells[3].text);
}
