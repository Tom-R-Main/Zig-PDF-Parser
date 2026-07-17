const std = @import("std");

pub const SourceKind = enum(u8) {
    native_pdf,
    embedded_ocr,
    fresh_ocr,
    table_model,
    formula_model,
    manual,
    poppler_text,
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

pub const RulingOrientation = enum {
    horizontal,
    vertical,
};

pub const RulingLine = struct {
    bbox: BBox,
    orientation: RulingOrientation,
    stroke_width: f64 = 1,
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
    unicode_map_error: bool = false,
    actual_text: bool = false,
    writing_mode: u8 = 0,

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
        unicode_map_error: bool = false,
        actual_text: bool = false,
        writing_mode: u8 = 0,
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
            .unicode_map_error = args.unicode_map_error,
            .actual_text = args.actual_text,
            .writing_mode = args.writing_mode,
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
    rowspan: u32 = 1,
    colspan: u32 = 1,
    role: TableCellRole = .data,
    confidence: f32 = 0.70,
};

pub const TableCellRole = enum(u8) {
    data,
    header,
    row_header,
    note,
    footer,
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
    page_index: u32 = 0,
    confidence: f32 = 0.72,
    logical_table_index: ?u32 = null,
    table_part_index: u32 = 0,
    continued_from_table_index: ?u32 = null,
    continued_to_table_index: ?u32 = null,
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

            if (self.tableForBlock(block_index)) |table| {
                try appendTablePlain(allocator, &output, table);
                emitted_block = true;
                continue;
            }
            if (self.blockCoveredByTable(block_index)) continue;

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
            const logical_index = table.logical_table_index orelse @as(u32, @intCast(table_index));
            try writer.print(
                "{{\"table_id\":\"table-{d}\",\"logical_table_id\":\"logical-table-{d}\",\"table_index\":{},\"table_part_index\":{},\"continued_from_table_id\":",
                .{ table_index, logical_index, table_index, table.table_part_index },
            );
            try writeOptionalTableId(writer, table.continued_from_table_index);
            try writer.writeAll(",\"continued_to_table_id\":");
            try writeOptionalTableId(writer, table.continued_to_table_index);
            try writer.print(
                ",\"page_index\":{},\"block_index\":{},\"block_count\":{},\"column_count\":{},\"confidence\":{d:.3},\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[],\"rows\":[",
                .{ table.page_index, table.block_index, table.block_count, table.column_count, table.confidence, table.bounds.x0, table.bounds.y0, table.bounds.x1, table.bounds.y1 },
            );
            for (table.rows, 0..) |row, row_index| {
                if (row_index > 0) try writer.writeByte(',');
                try writer.writeByte('[');
                var wrote_cell = false;
                for (row.cells) |cell| {
                    if (cell.text.len == 0) continue;
                    if (wrote_cell) try writer.writeByte(',');
                    wrote_cell = true;
                    try writer.writeByte('{');
                    try writer.print(
                        "\"cell_id\":\"table-{d}-cell-{d}-{d}\",\"page\":{},\"page_index\":{},\"row\":{},\"column\":{},\"rowspan\":{},\"colspan\":{},\"role\":\"",
                        .{ table_index, cell.row_index, cell.column_index, cell.bounds.page_index, cell.bounds.page_index, cell.row_index, cell.column_index, cell.rowspan, cell.colspan },
                    );
                    try writer.writeAll(tableCellRoleName(cell.role));
                    try writer.writeAll("\",\"text\":\"");
                    try writeJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"raw_text\":\"");
                    try writeJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"normalized_text\":\"");
                    try writeNormalizedJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"numeric\":");
                    try writeNumericHint(writer, cell.text);
                    try writer.print(
                        ",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[]",
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

fn tableCellRoleName(role: TableCellRole) []const u8 {
    return switch (role) {
        .data => "data",
        .header => "header",
        .row_header => "row_header",
        .note => "note",
        .footer => "footer",
    };
}

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
    return analyzeLayoutWithRulings(allocator, spans, page_width, &.{});
}

pub fn analyzeLayoutWithRulings(
    allocator: std.mem.Allocator,
    spans: []const TextSpan,
    page_width: f64,
    ruling_lines: []const RulingLine,
) !LayoutResult {
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

    // Count visual line bands, then use whitespace occupancy to locate a real
    // gutter. A page midpoint is not evidence of a column boundary.
    var total_lines: usize = 1;
    var current_y: f64 = sorted[0].y0;
    for (sorted) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            total_lines += 1;
            current_y = span.y0;
        }
    }

    const table_like_rows = countTableLikeRowsInSpans(sorted, line_threshold);
    const table_heavy_page = table_like_rows >= 2 and table_like_rows * 2 >= total_lines;
    const gutter = if (table_heavy_page) null else detectSpanGutter(sorted, page_width, line_threshold);
    const is_two_column = gutter != null;

    var result_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len);

    if (is_two_column) {
        // Two-column layout: output left column first, then right column
        var left_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer left_spans.deinit(allocator);
        var right_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer right_spans.deinit(allocator);

        for (sorted) |span| {
            if (spanRegion(span, gutter.?) == 1) {
                try right_spans.append(allocator, span);
            } else {
                try left_spans.append(allocator, span);
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

    const body_font_size = try estimateBodyFontSize(allocator, result_spans.items);
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
                if (spanRegion(line.bounds, gutter.?) == 1) {
                    try right_lines.append(allocator, line);
                } else {
                    try left_lines.append(allocator, line);
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

    const tables = try buildTableGridsWithRulings(allocator, blocks.items, ruling_lines);
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

fn countTableLikeRowsInSpans(sorted: []const TextSpan, line_threshold: f64) usize {
    if (sorted.len == 0) return 0;
    var count: usize = 0;
    var row_start: usize = 0;
    var current_y = sorted[0].y0;
    for (sorted, 0..) |span, index| {
        if (@abs(span.y0 - current_y) <= line_threshold) continue;
        if (spanRowLooksLikeTable(sorted[row_start..index])) count += 1;
        row_start = index;
        current_y = span.y0;
    }
    if (spanRowLooksLikeTable(sorted[row_start..])) count += 1;
    return count;
}

const SpanGutter = struct { x0: f64, x1: f64 };

fn detectSpanGutter(spans: []const TextSpan, page_width: f64, line_threshold: f64) ?SpanGutter {
    if (spans.len < 4 or page_width <= 0) return null;
    const bin_count = 64;
    var occupancy: [bin_count]u32 = @splat(0);
    for (spans) |span| {
        const x0 = @max(0, @min(page_width, span.x0));
        const x1 = @max(0, @min(page_width, span.x1));
        const first: usize = @min(bin_count - 1, @as(usize, @intFromFloat(@floor(x0 / page_width * bin_count))));
        const last: usize = @min(bin_count - 1, @as(usize, @intFromFloat(@floor(x1 / page_width * bin_count))));
        var bin = first;
        while (bin <= last) : (bin += 1) occupancy[bin] += 1;
    }

    const search_start = bin_count / 4;
    const search_end = bin_count * 3 / 4;
    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: ?usize = null;
    for (search_start..search_end) |bin| {
        if (occupancy[bin] == 0) {
            if (run_start == null) run_start = bin;
        } else if (run_start) |start| {
            if (bin - start > best_len) {
                best_start = start;
                best_len = bin - start;
            }
            run_start = null;
        }
    }
    if (run_start) |start| {
        if (search_end - start > best_len) {
            best_start = start;
            best_len = search_end - start;
        }
    }
    if (best_len == 0) return null;
    const gutter = SpanGutter{
        .x0 = @as(f64, @floatFromInt(best_start)) / bin_count * page_width,
        .x1 = @as(f64, @floatFromInt(best_start + best_len)) / bin_count * page_width,
    };
    if (gutter.x1 - gutter.x0 < @max(12.0, page_width * 0.025)) return null;

    var left_count: usize = 0;
    var right_count: usize = 0;
    var left_bands: [32]f64 = undefined;
    var right_bands: [32]f64 = undefined;
    var left_band_count: usize = 0;
    var right_band_count: usize = 0;
    for (spans) |span| switch (spanRegion(span, gutter)) {
        0 => {
            left_count += 1;
            appendBaselineBand(&left_bands, &left_band_count, span.y0, line_threshold);
        },
        1 => {
            right_count += 1;
            appendBaselineBand(&right_bands, &right_band_count, span.y0, line_threshold);
        },
        else => {},
    };
    if (left_count < 2 or right_count < 2 or left_band_count < 2 or right_band_count < 2) return null;
    return gutter;
}

fn appendBaselineBand(bands: *[32]f64, count: *usize, baseline: f64, tolerance: f64) void {
    for (bands[0..count.*]) |existing| if (@abs(existing - baseline) <= tolerance) return;
    if (count.* == bands.len) return;
    bands[count.*] = baseline;
    count.* += 1;
}

fn spanRegion(span: TextSpan, gutter: SpanGutter) u32 {
    if (span.x1 <= gutter.x0) return 0;
    if (span.x0 >= gutter.x1) return 1;
    return 2;
}

fn spanRowLooksLikeTable(row: []const TextSpan) bool {
    if (row.len < 3) return false;
    var numeric_spans: usize = 0;
    var wide_gaps: usize = 0;
    var prev_x1 = row[0].x1;
    const font_size = @max(1.0, row[0].font_size);

    for (row, 0..) |span, index| {
        if (spanHasDigit(span)) numeric_spans += 1;
        if (index > 0) {
            const gap = span.x0 - prev_x1;
            if (gap > font_size * 1.8) wide_gaps += 1;
        }
        prev_x1 = span.x1;
    }

    return wide_gaps >= 2 or numeric_spans * 2 >= row.len;
}

fn spanHasDigit(span: TextSpan) bool {
    for (span.text) |byte| {
        if (std.ascii.isDigit(byte)) return true;
    }
    return false;
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

const FontSizeBucket = struct {
    key: i64,
    first_size: f64,
    weight: usize,
};

fn estimateBodyFontSize(allocator: std.mem.Allocator, spans: []const TextSpan) !f64 {
    if (spans.len == 0) return 12;

    var buckets = try std.ArrayList(FontSizeBucket).initCapacity(allocator, 8);
    defer buckets.deinit(allocator);

    for (spans) |span| {
        const key: i64 = @intFromFloat(@round(span.font_size * 2));
        for (buckets.items) |*bucket| {
            if (bucket.key == key) {
                bucket.weight += span.text.len;
                break;
            }
        } else {
            try buckets.append(allocator, .{
                .key = key,
                .first_size = span.font_size,
                .weight = span.text.len,
            });
        }
    }

    var best_size = spans[0].font_size;
    var best_weight: usize = 0;
    for (buckets.items) |bucket| {
        if (bucket.weight > best_weight) {
            best_weight = bucket.weight;
            best_size = bucket.first_size;
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

fn buildTableGridsWithRulings(
    allocator: std.mem.Allocator,
    blocks: []const LayoutBlock,
    ruling_lines: []const RulingLine,
) ![]TableGrid {
    if (try buildRuledTableGrid(allocator, blocks, ruling_lines)) |table| {
        const tables = try allocator.alloc(TableGrid, 1);
        tables[0] = table;
        return tables;
    }
    return buildTableGrids(allocator, blocks);
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

    assignPageLocalTableIds(tables.items);
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
        if (occupied_cells >= 2 or rows.items.len == 0 or rowIsNote(row)) {
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

    markFooterRows(rows.items);

    return TableGrid{
        .bounds = block.bounds,
        .block_index = block_index,
        .block_count = 1,
        .rows = try rows.toOwnedSlice(allocator),
        .column_count = column_count,
        .page_index = block.bounds.page_index,
        .confidence = block.confidence,
    };
}

const CellBucket = struct {
    text: std.ArrayList(u8) = .empty,
    bounds: ?TextSpan = null,
};

fn buildRuledTableGrid(
    allocator: std.mem.Allocator,
    blocks: []const LayoutBlock,
    ruling_lines: []const RulingLine,
) !?TableGrid {
    if (blocks.len == 0 or ruling_lines.len < 4) return null;

    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(allocator);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(allocator);

    for (ruling_lines) |line| {
        switch (line.orientation) {
            .vertical => try addCoord(allocator, &xs, (line.bbox.x0 + line.bbox.x1) / 2.0, 2.0),
            .horizontal => try addCoord(allocator, &ys, (line.bbox.y0 + line.bbox.y1) / 2.0, 2.0),
        }
    }
    if (xs.items.len < 2 or ys.items.len < 2) return null;

    std.mem.sort(f64, xs.items, {}, struct {
        fn cmp(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.cmp);
    std.mem.sort(f64, ys.items, {}, struct {
        fn cmp(_: void, a: f64, b: f64) bool {
            return a > b;
        }
    }.cmp);

    const column_count = xs.items.len - 1;
    const row_count = ys.items.len - 1;
    if (column_count < 2 or row_count < 1) return null;

    const grid_bbox = TextSpan.init(.{
        .page_index = blocks[0].bounds.page_index,
        .bbox = .{
            .x0 = xs.items[0],
            .y0 = ys.items[ys.items.len - 1],
            .x1 = xs.items[xs.items.len - 1],
            .y1 = ys.items[0],
        },
        .text = "",
        .source = .table_model,
        .confidence = 0.86,
        .font = .{},
    });

    var first_block_index: ?u32 = null;
    var block_count: usize = 0;
    for (blocks, 0..) |block, block_index| {
        if (!intersectsSpan(block.bounds, grid_bbox)) continue;
        if (first_block_index == null) first_block_index = @intCast(block_index);
        block_count += 1;
    }
    if (block_count == 0) return null;

    var rows = try allocator.alloc(TableRow, row_count);
    errdefer {
        for (rows[0..row_count]) |row| freeTableRow(allocator, row);
        allocator.free(rows);
    }

    for (0..row_count) |row_index| {
        const top = ys.items[row_index];
        const bottom = ys.items[row_index + 1];
        var buckets = try allocator.alloc(CellBucket, column_count);
        defer {
            for (buckets) |*bucket| bucket.text.deinit(allocator);
            allocator.free(buckets);
        }
        for (buckets) |*bucket| bucket.* = .{};

        for (blocks) |block| {
            if (!intersectsSpan(block.bounds, grid_bbox)) continue;
            for (block.lines) |line| {
                for (line.words) |word| {
                    const cx = (word.bounds.x0 + word.bounds.x1) / 2.0;
                    const cy = (word.bounds.y0 + word.bounds.y1) / 2.0;
                    if (cy > top + 1.0 or cy < bottom - 1.0) continue;
                    const col_index = columnForX(xs.items, cx) orelse continue;
                    if (buckets[col_index].text.items.len > 0) try buckets[col_index].text.append(allocator, ' ');
                    try appendWordText(allocator, &buckets[col_index].text, word);
                    buckets[col_index].bounds = if (buckets[col_index].bounds) |existing|
                        mergeTwoBounds(existing, word.bounds)
                    else
                        word.bounds;
                }
            }
        }

        const cells = try allocator.alloc(TableCell, column_count);
        errdefer {
            for (cells) |cell| allocator.free(cell.text);
            allocator.free(cells);
        }

        for (cells, 0..) |*cell, column_index| {
            const text = try buckets[column_index].text.toOwnedSlice(allocator);
            const cell_bbox = TextSpan.init(.{
                .page_index = grid_bbox.page_index,
                .bbox = .{
                    .x0 = xs.items[column_index],
                    .y0 = bottom,
                    .x1 = xs.items[column_index + 1],
                    .y1 = top,
                },
                .text = "",
                .source = .table_model,
                .confidence = 0.82,
                .font = .{},
            });
            cell.* = .{
                .bounds = buckets[column_index].bounds orelse cell_bbox,
                .text = text,
                .row_index = @intCast(row_index),
                .column_index = @intCast(column_index),
                .rowspan = if (text.len > 0) inferredRowspan(ruling_lines, ys.items, row_index, xs.items[column_index], xs.items[column_index + 1]) else 1,
                .colspan = inferredColspan(ruling_lines, xs.items, column_index, bottom, top),
                .role = ruledCellRole(@intCast(row_index), @intCast(column_index), text),
                .confidence = if (text.len > 0) 0.86 else 0.42,
            };
        }

        rows[row_index] = .{
            .bounds = TextSpan.init(.{
                .page_index = grid_bbox.page_index,
                .bbox = .{ .x0 = grid_bbox.x0, .y0 = bottom, .x1 = grid_bbox.x1, .y1 = top },
                .text = "",
                .source = .table_model,
                .confidence = 0.86,
                .font = .{},
            }),
            .cells = cells,
            .row_index = @intCast(row_index),
        };
    }

    markFooterRows(rows);

    return TableGrid{
        .bounds = grid_bbox,
        .block_index = first_block_index.?,
        .block_count = block_count,
        .rows = rows,
        .column_count = column_count,
        .page_index = grid_bbox.page_index,
        .confidence = 0.86,
    };
}

fn addCoord(allocator: std.mem.Allocator, coords: *std.ArrayList(f64), value: f64, tolerance: f64) !void {
    for (coords.items) |*coord| {
        if (@abs(coord.* - value) <= tolerance) {
            coord.* = (coord.* + value) / 2.0;
            return;
        }
    }
    try coords.append(allocator, value);
}

fn intersectsSpan(a: TextSpan, b: TextSpan) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
}

fn columnForX(xs: []const f64, x: f64) ?usize {
    if (xs.len < 2) return null;
    for (0..xs.len - 1) |index| {
        if (x >= xs[index] - 1.0 and x <= xs[index + 1] + 1.0) return index;
    }
    return null;
}

fn inferredColspan(ruling_lines: []const RulingLine, xs: []const f64, column_index: usize, bottom: f64, top: f64) u32 {
    var span: u32 = 1;
    var boundary_index = column_index + 1;
    while (boundary_index < xs.len - 1) : (boundary_index += 1) {
        if (verticalBoundaryCrossesRow(ruling_lines, xs[boundary_index], bottom, top)) break;
        span += 1;
    }
    return span;
}

fn inferredRowspan(ruling_lines: []const RulingLine, ys: []const f64, row_index: usize, left: f64, right: f64) u32 {
    var span: u32 = 1;
    var boundary_index = row_index + 1;
    while (boundary_index < ys.len - 1) : (boundary_index += 1) {
        if (horizontalBoundaryCrossesColumn(ruling_lines, ys[boundary_index], left, right)) break;
        span += 1;
    }
    return span;
}

fn verticalBoundaryCrossesRow(ruling_lines: []const RulingLine, x: f64, bottom: f64, top: f64) bool {
    const mid_y = (bottom + top) / 2.0;
    for (ruling_lines) |line| {
        if (line.orientation != .vertical) continue;
        const line_x = (line.bbox.x0 + line.bbox.x1) / 2.0;
        if (@abs(line_x - x) > 2.0) continue;
        if (line.bbox.y0 <= mid_y + 1.0 and line.bbox.y1 >= mid_y - 1.0) return true;
    }
    return false;
}

fn horizontalBoundaryCrossesColumn(ruling_lines: []const RulingLine, y: f64, left: f64, right: f64) bool {
    const mid_x = (left + right) / 2.0;
    for (ruling_lines) |line| {
        if (line.orientation != .horizontal) continue;
        const line_y = (line.bbox.y0 + line.bbox.y1) / 2.0;
        if (@abs(line_y - y) > 2.0) continue;
        if (line.bbox.x0 <= mid_x + 1.0 and line.bbox.x1 >= mid_x - 1.0) return true;
    }
    return false;
}

fn ruledCellRole(row_index: u32, column_index: u32, text: []const u8) TableCellRole {
    if (text.len > 0 and text[0] == '*') return .note;
    if (row_index == 0) return .header;
    if (column_index == 0) return .row_header;
    return .data;
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
            .role = heuristicCellRole(row_index, @intCast(column_index), text),
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
            .colspan = if (column_index == target_column and text.len > 0) @intCast(anchors.len - target_column) else 1,
            .role = heuristicCellRole(row_index, @intCast(column_index), text),
            .confidence = if (text.len > 0) 0.72 else 0.45,
        };
    }

    return .{
        .bounds = line.bounds,
        .cells = cells,
        .row_index = row_index,
    };
}

fn heuristicCellRole(row_index: u32, column_index: u32, text: []const u8) TableCellRole {
    if (text.len > 0 and text[0] == '*') return .note;
    if (row_index == 0) return .header;
    if (column_index == 0) return .row_header;
    return .data;
}

fn markFooterRows(rows: []TableRow) void {
    if (rows.len < 3) return;

    var row_index = rows.len;
    while (row_index > 0) {
        row_index -= 1;
        if (rowIsNote(rows[row_index])) continue;
        if (!rowLooksLikeFooter(rows[row_index])) return;
        for (rows[row_index].cells) |*cell| {
            if (cell.text.len > 0) cell.role = .footer;
        }
        return;
    }
}

fn rowLooksLikeFooter(row: TableRow) bool {
    var first_text: ?[]const u8 = null;
    var numeric_count: usize = 0;
    for (row.cells) |cell| {
        if (cell.text.len == 0) continue;
        if (first_text == null) first_text = cell.text;
        if (cellLooksNumeric(cell.text)) numeric_count += 1;
    }
    const label = first_text orelse return false;
    return numeric_count > 0 and startsWithFinancialFooterLabel(label);
}

fn startsWithFinancialFooterLabel(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return startsWithIgnoreCase(trimmed, "total") or
        startsWithIgnoreCase(trimmed, "subtotal") or
        startsWithIgnoreCase(trimmed, "net income") or
        startsWithIgnoreCase(trimmed, "net loss") or
        startsWithIgnoreCase(trimmed, "ending balance");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn cellLooksNumeric(text: []const u8) bool {
    var saw_digit = false;
    for (text) |byte| {
        if (std.ascii.isDigit(byte)) {
            saw_digit = true;
            continue;
        }
        switch (byte) {
            ' ', '\t', '\r', '\n', ',', '.', '-', '+', '(', ')', '$', '%' => {},
            else => return false,
        }
    }
    return saw_digit;
}

fn assignPageLocalTableIds(tables: []TableGrid) void {
    for (tables, 0..) |*table, index| {
        table.logical_table_index = @intCast(index);
        table.table_part_index = 0;
        table.continued_from_table_index = null;
        table.continued_to_table_index = null;
    }
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

fn rowIsNote(row: TableRow) bool {
    for (row.cells) |cell| {
        if (cell.text.len > 0 and cell.role == .note) return true;
    }
    return false;
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
        try writeJsonEscapedByte(writer, byte);
    }
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
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

fn writeOptionalTableId(writer: anytype, table_index: ?u32) !void {
    if (table_index) |index| {
        try writer.print("\"table-{d}\"", .{index});
    } else {
        try writer.writeAll("null");
    }
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
    if (parseNumericCell(text)) |numeric| {
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
    for (line.words) |word| {
        if (wordHasDigit(word)) numeric_words += 1;
    }

    return lineWideGapCount(line) >= 2 or numeric_words * 2 >= line.words.len;
}

fn lineWideGapCount(line: *const TextLine) usize {
    if (line.words.len < 2) return 0;
    var wide_gaps: usize = 0;
    var prev_x1 = line.words[0].bounds.x1;
    for (line.words[1..]) |word| {
        const gap = word.bounds.x0 - prev_x1;
        if (gap > line.bounds.font_size * 1.8) wide_gaps += 1;
        prev_x1 = word.bounds.x1;
    }
    return wide_gaps;
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

test "layout reconstruction does not split table-heavy rows into page columns" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Date", 76, 708, 104, 720),
        testSpan("Description", 132, 708, 206, 720),
        testSpan("Debit", 292, 708, 326, 720),
        testSpan("Credit", 372, 708, 414, 720),
        testSpan("Balance", 456, 708, 506, 720),
        testSpan("01/02", 76, 682, 116, 694),
        testSpan("Payroll", 132, 682, 182, 694),
        testSpan("ACME", 184, 682, 218, 694),
        testSpan("2,450", 372, 682, 412, 694),
        testSpan("4,100", 456, 682, 496, 694),
        testSpan("01/03", 76, 656, 116, 668),
        testSpan("Rent", 132, 656, 162, 668),
        testSpan("(1,200)", 292, 656, 342, 668),
        testSpan("2,900", 456, 656, 496, 668),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expect(result.lines[0].words.len >= 5);
    try std.testing.expect(result.tables.len >= 1);
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
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Subscriptions North America", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(35)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("Services*", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-250", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("12", table.rows[2].cells[2].text);
    try std.testing.expectEqualStrings("* excludes setup fees", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.note, table.rows[3].cells[0].role);
    try std.testing.expectEqual(@as(u32, 3), table.rows[3].cells[0].colspan);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Subscriptions North America 1,200 (35)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Services* -250 12\n* excludes setup fees") != null);
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
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Revenue", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Expense", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("Net", table.rows[0].cells[3].text);
    try std.testing.expectEqualStrings("Total revenue", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(950)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("250", table.rows[1].cells[3].text);
    try std.testing.expectEqualStrings("Services*", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-300", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("(450)", table.rows[2].cells[2].text);
    try std.testing.expectEqualStrings("(750)", table.rows[2].cells[3].text);
    try std.testing.expectEqualStrings("* excludes setup fees", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.note, table.rows[3].cells[0].role);
    try std.testing.expectEqual(@as(u32, 4), table.rows[3].cells[0].colspan);
}

test "table grid marks bottom financial total rows as footer" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Actual", 200, 720, 242, 732),
        testSpan("Budget", 300, 720, 346, 732),
        testSpan("Cash", 80, 700, 112, 712),
        testSpan("1,000", 200, 700, 240, 712),
        testSpan("900", 300, 700, 324, 712),
        testSpan("Debt", 80, 680, 112, 692),
        testSpan("(200)", 200, 680, 240, 692),
        testSpan("(175)", 300, 680, 340, 692),
        testSpan("Total assets", 80, 660, 154, 672),
        testSpan("800", 200, 660, 224, 672),
        testSpan("725", 300, 660, 324, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqualStrings("Total assets", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[0].role);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[1].role);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[2].role);
}
