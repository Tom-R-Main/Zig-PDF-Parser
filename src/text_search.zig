//! Deterministic normalized text search with reverse source mapping.
//!
//! `SearchTextView` borrows its source text and owns only the normalized bytes
//! and compact mapping runs. Callers must keep the source alive until all
//! matches and contexts have been copied.

const std = @import("std");
const layout = @import("layout.zig");

pub const BBox = layout.BBox;

pub const SourceKind = enum(u8) {
    native_reading,
    native_content,
    full_context_text,
    legacy_structured,
    poppler_text,
};

pub const Transform = struct {
    pub const ascii_case_fold: u32 = 1 << 0;
    pub const whitespace_collapse: u32 = 1 << 1;
    pub const compatibility_punctuation: u32 = 1 << 2;
    pub const ligature_expansion: u32 = 1 << 3;
    pub const line_end_dehyphenation: u32 = 1 << 4;
    pub const soft_hyphen_removal: u32 = 1 << 5;
    pub const format_control_removal: u32 = 1 << 6;
};

pub const Options = struct {
    case_sensitive: bool = false,
    collapse_whitespace: bool = true,
    fold_compatibility_punctuation: bool = true,
    expand_ligatures: bool = true,
    dehyphenate_line_breaks: bool = true,
    remove_soft_hyphens: bool = true,
    remove_format_controls: bool = true,

    pub fn richDefault() Options {
        return .{};
    }

    pub fn legacyCompat() Options {
        return .{
            .collapse_whitespace = false,
            .fold_compatibility_punctuation = false,
            .expand_ligatures = false,
            .dehyphenate_line_breaks = false,
            .remove_soft_hyphens = false,
            .remove_format_controls = false,
        };
    }
};

pub const SourceEvidence = struct {
    source_start: usize,
    source_end: usize,
    glyph_index: ?u32 = null,
    bbox: ?BBox = null,
};

pub const SourceMapRun = struct {
    normalized_start: usize,
    normalized_end: usize,
    source_start: usize,
    source_end: usize,
    first_glyph_index: ?u32 = null,
    last_glyph_index: ?u32 = null,
    bbox: ?BBox = null,
    transformations: u32 = 0,
};

pub const SourceRange = struct {
    source_start: usize,
    source_end: usize,
    first_glyph_index: ?u32 = null,
    last_glyph_index: ?u32 = null,
    bbox: ?BBox = null,
    transformations: u32 = 0,
};

pub const MatchLocation = struct {
    normalized_start: usize,
    normalized_end: usize,
    source: SourceRange,
};

pub const SearchTextView = struct {
    allocator: std.mem.Allocator,
    source_kind: SourceKind,
    source_text: []const u8,
    /// Borrowed exact source-to-glyph evidence. The caller must keep it alive
    /// for the lifetime of this view.
    evidence: []const SourceEvidence,
    normalized_text: []u8,
    runs: []SourceMapRun,
    /// Sorted normalized byte boundaries where a line-end hyphen and its
    /// following line break were removed. These boundaries let a hyphenated
    /// query prove that each omitted hyphen aligns with the source transform.
    dehyphenation_offsets: []usize,

    pub fn deinit(self: *SearchTextView) void {
        self.allocator.free(self.normalized_text);
        self.allocator.free(self.runs);
        self.allocator.free(self.dehyphenation_offsets);
        self.* = undefined;
    }

    pub fn findAll(
        self: *const SearchTextView,
        allocator: std.mem.Allocator,
        normalized_query: []const u8,
        max_results: ?usize,
    ) ![]MatchLocation {
        if (normalized_query.len == 0) return allocator.alloc(MatchLocation, 0);
        if (max_results != null and max_results.? == 0) return allocator.alloc(MatchLocation, 0);

        var matches: std.ArrayList(MatchLocation) = .empty;
        errdefer matches.deinit(allocator);
        try self.appendMatchesForQuery(allocator, &matches, normalized_query, null);

        if (std.mem.indexOfScalar(u8, normalized_query, '-') != null) {
            var dehyphenated_query: std.ArrayList(u8) = .empty;
            defer dehyphenated_query.deinit(allocator);
            var query_boundaries: std.ArrayList(usize) = .empty;
            defer query_boundaries.deinit(allocator);
            for (normalized_query) |byte| {
                if (byte == '-') {
                    try query_boundaries.append(allocator, dehyphenated_query.items.len);
                } else {
                    try dehyphenated_query.append(allocator, byte);
                }
            }
            if (dehyphenated_query.items.len > 0 and
                dehyphenated_query.items.len != normalized_query.len)
            {
                try self.appendMatchesForQuery(
                    allocator,
                    &matches,
                    dehyphenated_query.items,
                    query_boundaries.items,
                );
            }
        }

        std.mem.sort(MatchLocation, matches.items, {}, struct {
            fn lessThan(_: void, a: MatchLocation, b: MatchLocation) bool {
                if (a.normalized_start != b.normalized_start) {
                    return a.normalized_start < b.normalized_start;
                }
                return a.normalized_end < b.normalized_end;
            }
        }.lessThan);

        var write_index: usize = 0;
        for (matches.items) |match| {
            if (write_index > 0 and
                matches.items[write_index - 1].normalized_start == match.normalized_start and
                matches.items[write_index - 1].normalized_end == match.normalized_end)
            {
                continue;
            }
            matches.items[write_index] = match;
            write_index += 1;
        }
        matches.items.len = if (max_results) |limit|
            @min(limit, write_index)
        else
            write_index;
        return matches.toOwnedSlice(allocator);
    }

    fn appendMatchesForQuery(
        self: *const SearchTextView,
        allocator: std.mem.Allocator,
        matches: *std.ArrayList(MatchLocation),
        normalized_query: []const u8,
        query_dehyphenation_offsets: ?[]const usize,
    ) !void {
        var search_offset: usize = 0;
        while (search_offset + normalized_query.len <= self.normalized_text.len) {
            const relative = std.mem.indexOf(
                u8,
                self.normalized_text[search_offset..],
                normalized_query,
            ) orelse break;
            const normalized_start = search_offset + relative;
            const normalized_end = normalized_start + normalized_query.len;
            if (query_dehyphenation_offsets) |query_offsets| {
                if (!self.dehyphenationBoundariesMatch(
                    normalized_start,
                    normalized_end,
                    query_offsets,
                )) {
                    search_offset = normalized_end;
                    continue;
                }
            }
            const source = self.sourceRange(normalized_start, normalized_end) orelse {
                search_offset = normalized_end;
                continue;
            };
            try matches.append(allocator, .{
                .normalized_start = normalized_start,
                .normalized_end = normalized_end,
                .source = source,
            });
            search_offset = normalized_end;
        }
    }

    fn dehyphenationBoundariesMatch(
        self: *const SearchTextView,
        normalized_start: usize,
        normalized_end: usize,
        query_offsets: []const usize,
    ) bool {
        var source_index: usize = 0;
        while (source_index < self.dehyphenation_offsets.len and
            self.dehyphenation_offsets[source_index] < normalized_start)
        {
            source_index += 1;
        }
        for (query_offsets) |query_offset| {
            if (source_index >= self.dehyphenation_offsets.len) return false;
            const source_offset = self.dehyphenation_offsets[source_index];
            if (source_offset > normalized_end or
                source_offset - normalized_start != query_offset)
            {
                return false;
            }
            source_index += 1;
        }
        return source_index >= self.dehyphenation_offsets.len or
            self.dehyphenation_offsets[source_index] > normalized_end;
    }

    /// Return the sorted, unique physical glyph ids contributing to a source
    /// range. This exact set is used for cross-lane occurrence identity; the
    /// public min/max range remains presentation metadata only.
    pub fn glyphIdentity(
        self: *const SearchTextView,
        allocator: std.mem.Allocator,
        source_start: usize,
        source_end: usize,
    ) ![]u32 {
        var glyph_indices: std.ArrayList(u32) = .empty;
        errdefer glyph_indices.deinit(allocator);
        var low: usize = 0;
        var high = self.evidence.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.evidence[middle].source_end <= source_start) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        for (self.evidence[low..]) |item| {
            if (item.source_start >= source_end) break;
            if (item.source_end <= source_start) continue;
            const glyph_index = item.glyph_index orelse continue;
            try glyph_indices.append(allocator, glyph_index);
        }
        std.mem.sort(u32, glyph_indices.items, {}, comptime std.sort.asc(u32));
        var write_index: usize = 0;
        for (glyph_indices.items) |glyph_index| {
            if (write_index > 0 and glyph_indices.items[write_index - 1] == glyph_index) continue;
            glyph_indices.items[write_index] = glyph_index;
            write_index += 1;
        }
        glyph_indices.items.len = write_index;
        return glyph_indices.toOwnedSlice(allocator);
    }

    pub fn sourceRange(
        self: *const SearchTextView,
        normalized_start: usize,
        normalized_end: usize,
    ) ?SourceRange {
        if (normalized_start >= normalized_end or normalized_end > self.normalized_text.len) return null;
        var result: ?SourceRange = null;
        var low: usize = 0;
        var high = self.runs.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.runs[middle].normalized_end <= normalized_start) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        for (self.runs[low..]) |run| {
            if (run.normalized_start >= normalized_end) break;
            if (result) |*range| {
                range.source_start = @min(range.source_start, run.source_start);
                range.source_end = @max(range.source_end, run.source_end);
                range.first_glyph_index = minOptional(range.first_glyph_index, run.first_glyph_index);
                range.last_glyph_index = maxOptional(range.last_glyph_index, run.last_glyph_index);
                range.bbox = unionOptional(range.bbox, run.bbox);
                range.transformations |= run.transformations;
            } else {
                result = .{
                    .source_start = run.source_start,
                    .source_end = run.source_end,
                    .first_glyph_index = run.first_glyph_index,
                    .last_glyph_index = run.last_glyph_index,
                    .bbox = run.bbox,
                    .transformations = run.transformations,
                };
            }
        }
        return result;
    }
};

pub fn normalizeQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
    options: Options,
) ![]u8 {
    var view = try buildView(allocator, query, .legacy_structured, options, &.{});
    defer {
        allocator.free(view.runs);
        view.runs = &.{};
        allocator.free(view.dehyphenation_offsets);
        view.dehyphenation_offsets = &.{};
    }
    const normalized = view.normalized_text;
    view.normalized_text = &.{};
    return normalized;
}

pub fn buildView(
    allocator: std.mem.Allocator,
    source_text: []const u8,
    source_kind: SourceKind,
    options: Options,
    evidence: []const SourceEvidence,
) !SearchTextView {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var runs: std.ArrayList(SourceMapRun) = .empty;
    errdefer runs.deinit(allocator);
    var dehyphenation_offsets: std.ArrayList(usize) = .empty;
    errdefer dehyphenation_offsets.deinit(allocator);

    var source_index: usize = 0;
    var pending_source_start: ?usize = null;
    var pending_transformations: u32 = 0;
    var evidence_cursor: usize = 0;
    while (source_index < source_text.len) {
        const decoded = decodeCodepoint(source_text, source_index);
        const source_start = source_index;
        var source_end = source_index + decoded.byte_len;
        source_index = source_end;

        if (options.dehyphenate_line_breaks and isHyphenCodepoint(decoded.codepoint)) {
            if (lineEndContinuation(source_text, source_end)) |continuation| {
                source_end = continuation;
                source_index = continuation;
                if (pending_source_start == null) pending_source_start = source_start;
                pending_transformations |= Transform.line_end_dehyphenation;
                try dehyphenation_offsets.append(allocator, normalized.items.len);
                if (decoded.codepoint == 0x00ad) {
                    pending_transformations |= Transform.soft_hyphen_removal;
                }
                continue;
            }
        }

        if (decoded.codepoint == 0x00ad and options.remove_soft_hyphens) {
            if (pending_source_start == null) pending_source_start = source_start;
            pending_transformations |= Transform.soft_hyphen_removal;
            continue;
        }

        if (options.remove_format_controls and isSearchFormatControl(decoded.codepoint)) {
            if (pending_source_start == null) pending_source_start = source_start;
            pending_transformations |= Transform.format_control_removal;
            continue;
        }

        if (isWhitespaceCodepoint(decoded.codepoint)) {
            var whitespace_end = source_end;
            while (source_index < source_text.len) {
                const next = decodeCodepoint(source_text, source_index);
                if (!isWhitespaceCodepoint(next.codepoint)) break;
                source_index += next.byte_len;
                whitespace_end = source_index;
            }
            if (options.collapse_whitespace) {
                if (normalized.items.len > 0 and normalized.items[normalized.items.len - 1] != ' ') {
                    const normalized_start = normalized.items.len;
                    try normalized.append(allocator, ' ');
                    try appendRun(
                        allocator,
                        &runs,
                        normalized_start,
                        normalized.items.len,
                        pending_source_start orelse source_start,
                        whitespace_end,
                        Transform.whitespace_collapse | pending_transformations,
                        evidence,
                        &evidence_cursor,
                    );
                    pending_source_start = null;
                    pending_transformations = 0;
                }
            } else {
                const normalized_start = normalized.items.len;
                try normalized.appendSlice(allocator, source_text[source_start..whitespace_end]);
                try appendRun(
                    allocator,
                    &runs,
                    normalized_start,
                    normalized.items.len,
                    pending_source_start orelse source_start,
                    whitespace_end,
                    pending_transformations,
                    evidence,
                    &evidence_cursor,
                );
                pending_source_start = null;
                pending_transformations = 0;
            }
            continue;
        }

        var mapped_storage: [8]u8 = undefined;
        var mapped = source_text[source_start..source_end];
        var transformations: u32 = 0;
        if (options.expand_ligatures) {
            if (ligatureExpansion(decoded.codepoint)) |replacement| {
                mapped = replacement;
                transformations |= Transform.ligature_expansion;
            }
        }
        if (options.fold_compatibility_punctuation) {
            if (punctuationReplacement(decoded.codepoint)) |replacement| {
                mapped_storage[0] = replacement;
                mapped = mapped_storage[0..1];
                transformations |= Transform.compatibility_punctuation;
            }
        }

        const normalized_start = normalized.items.len;
        for (mapped) |byte| {
            const output_byte = if (!options.case_sensitive and std.ascii.isUpper(byte))
                std.ascii.toLower(byte)
            else
                byte;
            if (output_byte != byte) transformations |= Transform.ascii_case_fold;
            try normalized.append(allocator, output_byte);
        }
        try appendRun(
            allocator,
            &runs,
            normalized_start,
            normalized.items.len,
            pending_source_start orelse source_start,
            source_end,
            transformations | pending_transformations,
            evidence,
            &evidence_cursor,
        );
        pending_source_start = null;
        pending_transformations = 0;
    }

    if (options.collapse_whitespace and normalized.items.len > 0 and normalized.items[normalized.items.len - 1] == ' ') {
        normalized.items.len -= 1;
        while (runs.items.len > 0 and runs.items[runs.items.len - 1].normalized_start >= normalized.items.len) {
            _ = runs.pop();
        }
        if (runs.items.len > 0) {
            runs.items[runs.items.len - 1].normalized_end = @min(
                runs.items[runs.items.len - 1].normalized_end,
                normalized.items.len,
            );
        }
    }

    const owned_normalized = try normalized.toOwnedSlice(allocator);
    errdefer allocator.free(owned_normalized);
    const owned_runs = try runs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_runs);
    const owned_dehyphenation_offsets = try dehyphenation_offsets.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .source_kind = source_kind,
        .source_text = source_text,
        .evidence = evidence,
        .normalized_text = owned_normalized,
        .runs = owned_runs,
        .dehyphenation_offsets = owned_dehyphenation_offsets,
    };
}

pub fn contextBounds(
    text: []const u8,
    source_start: usize,
    source_end: usize,
    radius: usize,
) struct { start: usize, end: usize } {
    var start = source_start -| radius;
    while (start < source_start and start < text.len and isContinuationByte(text[start])) start += 1;
    var end = @min(text.len, source_end +| radius);
    while (end > source_end and end < text.len and isContinuationByte(text[end])) end -= 1;
    return .{ .start = start, .end = end };
}

const Decoded = struct {
    codepoint: u21,
    byte_len: usize,
};

fn decodeCodepoint(text: []const u8, index: usize) Decoded {
    const byte_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    if (index + byte_len > text.len) return .{ .codepoint = text[index], .byte_len = 1 };
    const codepoint = std.unicode.utf8Decode(text[index .. index + byte_len]) catch text[index];
    return .{ .codepoint = codepoint, .byte_len = byte_len };
}

fn lineEndContinuation(text: []const u8, after_hyphen: usize) ?usize {
    var index = after_hyphen;
    var saw_line_break = false;
    while (index < text.len) {
        const decoded = decodeCodepoint(text, index);
        if (!isWhitespaceCodepoint(decoded.codepoint)) break;
        if (decoded.codepoint == '\n' or decoded.codepoint == '\r' or decoded.codepoint == 0x2028 or decoded.codepoint == 0x2029) {
            saw_line_break = true;
        }
        index += decoded.byte_len;
    }
    if (!saw_line_break or index >= text.len) return null;
    const next = decodeCodepoint(text, index).codepoint;
    if ((next >= 'A' and next <= 'Z') or (next >= 'a' and next <= 'z') or next >= 0x80) return index;
    return null;
}

fn appendRun(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(SourceMapRun),
    normalized_start: usize,
    normalized_end: usize,
    source_start: usize,
    source_end: usize,
    transformations: u32,
    evidence: []const SourceEvidence,
    evidence_cursor: *usize,
) !void {
    if (normalized_start == normalized_end) return;
    var run = SourceMapRun{
        .normalized_start = normalized_start,
        .normalized_end = normalized_end,
        .source_start = source_start,
        .source_end = source_end,
        .transformations = transformations,
    };
    while (evidence_cursor.* < evidence.len and evidence[evidence_cursor.*].source_end <= source_start) {
        evidence_cursor.* += 1;
    }
    var evidence_index = evidence_cursor.*;
    while (evidence_index < evidence.len and evidence[evidence_index].source_start < source_end) : (evidence_index += 1) {
        const item = evidence[evidence_index];
        if (item.source_end <= source_start) continue;
        run.first_glyph_index = minOptional(run.first_glyph_index, item.glyph_index);
        run.last_glyph_index = maxOptional(run.last_glyph_index, item.glyph_index);
        run.bbox = unionOptional(run.bbox, item.bbox);
    }
    try runs.append(allocator, run);
}

fn minOptional(a: ?u32, b: ?u32) ?u32 {
    if (a) |left| {
        if (b) |right| return @min(left, right);
        return left;
    }
    return b;
}

fn maxOptional(a: ?u32, b: ?u32) ?u32 {
    if (a) |left| {
        if (b) |right| return @max(left, right);
        return left;
    }
    return b;
}

fn unionOptional(a: ?BBox, b: ?BBox) ?BBox {
    if (a) |left| {
        if (b) |right| return .{
            .x0 = @min(left.x0, right.x0),
            .y0 = @min(left.y0, right.y0),
            .x1 = @max(left.x1, right.x1),
            .y1 = @max(left.y1, right.y1),
        };
        return left;
    }
    return b;
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn isWhitespaceCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn isSearchFormatControl(codepoint: u21) bool {
    return switch (codepoint) {
        0x200b, 0x2060, 0xfeff => true,
        else => false,
    };
}

fn isHyphenCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        '-', 0x00ad, 0x2010 => true,
        else => false,
    };
}

fn punctuationReplacement(codepoint: u21) ?u8 {
    return switch (codepoint) {
        0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212 => '-',
        0x2018, 0x2019, 0x201a, 0x201b => '\'',
        0x201c, 0x201d, 0x201e, 0x201f => '"',
        else => null,
    };
}

fn ligatureExpansion(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0xfb00 => "ff",
        0xfb01 => "fi",
        0xfb02 => "fl",
        0xfb03 => "ffi",
        0xfb04 => "ffl",
        0xfb05, 0xfb06 => "st",
        else => null,
    };
}

test "rich normalization maps compatibility text back to source" {
    const allocator = std.testing.allocator;
    const source = "Evaluation\u{00a0}sum\u{2010}\nmary and \u{fb01}nal";
    var view = try buildView(allocator, source, .full_context_text, .richDefault(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("evaluation summary and final", view.normalized_text);

    const query = try normalizeQuery(allocator, "Evaluation summary", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings(
        "Evaluation\u{00a0}sum\u{2010}\nmary",
        source[matches[0].source.source_start..matches[0].source.source_end],
    );
    try std.testing.expect(matches[0].source.transformations & Transform.whitespace_collapse != 0);
    try std.testing.expect(matches[0].source.transformations & Transform.line_end_dehyphenation != 0);
}

test "semantic hyphen is retained" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "SWE-bench Pro", .legacy_structured, .richDefault(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("swe-bench pro", view.normalized_text);
}

test "hyphenated query finds an ASCII line-wrap dehyphenation" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "SWE-\nbench Pro", .full_context_text, .richDefault(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("swebench pro", view.normalized_text);

    const query = try normalizeQuery(allocator, "SWE-bench Pro", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expect(matches[0].source.transformations & Transform.line_end_dehyphenation != 0);
}

test "hyphenated query requires every hyphen at the source line-wrap boundary" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "a-\nbc", .full_context_text, .richDefault(), &.{});
    defer view.deinit();

    const query = try normalizeQuery(allocator, "a-b-c", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "hyphenated query rejects a line-wrap at a different boundary" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "a-\nbcd", .full_context_text, .richDefault(), &.{});
    defer view.deinit();

    const query = try normalizeQuery(allocator, "ab-cd", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "hyphenated query accepts multiple aligned line-wrap boundaries" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "a-\nb-\nc", .full_context_text, .richDefault(), &.{});
    defer view.deinit();

    const query = try normalizeQuery(allocator, "a-b-c", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
}

test "semantic dash at a line end is not dehyphenated" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "risk\u{2014}\nreward", .full_context_text, .richDefault(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("risk- reward", view.normalized_text);
}

test "line-end soft hyphen is removed with its line break" {
    const allocator = std.testing.allocator;
    const source = "Evaluation sum\u{00ad}\nmary";
    var view = try buildView(allocator, source, .full_context_text, .richDefault(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("evaluation summary", view.normalized_text);

    const query = try normalizeQuery(allocator, "evaluation summary", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expect(matches[0].source.transformations & Transform.line_end_dehyphenation != 0);
    try std.testing.expect(matches[0].source.transformations & Transform.soft_hyphen_removal != 0);
}

test "rich normalization removes zero-width PDF text controls" {
    const allocator = std.testing.allocator;
    var view = try buildView(
        allocator,
        "Evaluation\u{200b} summary\u{2060}",
        .full_context_text,
        .richDefault(),
        &.{},
    );
    defer view.deinit();
    try std.testing.expectEqualStrings("evaluation summary", view.normalized_text);
    var saw_removal = false;
    for (view.runs) |run| {
        if (run.transformations & Transform.format_control_removal != 0) saw_removal = true;
    }
    try std.testing.expect(saw_removal);
}

test "rich normalization preserves script-shaping join controls" {
    const allocator = std.testing.allocator;
    var view = try buildView(
        allocator,
        "a\u{200c}b a\u{200d}b",
        .full_context_text,
        .richDefault(),
        &.{},
    );
    defer view.deinit();
    try std.testing.expectEqualStrings("a\u{200c}b a\u{200d}b", view.normalized_text);
}

test "legacy profile changes only ASCII case" {
    const allocator = std.testing.allocator;
    var view = try buildView(allocator, "A\u{00a0}B\nC", .legacy_structured, .legacyCompat(), &.{});
    defer view.deinit();
    try std.testing.expectEqualStrings("a\u{00a0}b\nc", view.normalized_text);
}

test "source evidence supplies glyph range and geometry" {
    const allocator = std.testing.allocator;
    const evidence = [_]SourceEvidence{
        .{ .source_start = 0, .source_end = 5, .glyph_index = 8, .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 20, .y1 = 20 } },
        .{ .source_start = 6, .source_end = 10, .glyph_index = 4, .bbox = .{ .x0 = 22, .y0 = 10, .x1 = 32, .y1 = 20 } },
    };
    var view = try buildView(allocator, "Alpha Beta", .native_reading, .richDefault(), &evidence);
    defer view.deinit();
    const query = try normalizeQuery(allocator, "alpha beta", .richDefault());
    defer allocator.free(query);
    const matches = try view.findAll(allocator, query, null);
    defer allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(?u32, 4), matches[0].source.first_glyph_index);
    try std.testing.expectEqual(@as(?u32, 8), matches[0].source.last_glyph_index);
    try std.testing.expectEqual(@as(f64, 32), matches[0].source.bbox.?.x1);

    const glyph_identity = try view.glyphIdentity(
        allocator,
        matches[0].source.source_start,
        matches[0].source.source_end,
    );
    defer allocator.free(glyph_identity);
    try std.testing.expectEqualSlices(u32, &.{ 4, 8 }, glyph_identity);
}

test "context bounds do not split UTF-8" {
    const text = "prefix café suffix";
    const start = std.mem.indexOf(u8, text, "café").?;
    const bounds = contextBounds(text, start, start + "café".len, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text[bounds.start..bounds.end]));
}

fn buildViewAllocationProbe(allocator: std.mem.Allocator) !void {
    const evidence = [_]SourceEvidence{
        .{
            .source_start = 0,
            .source_end = 10,
            .glyph_index = 2,
            .bbox = .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
        },
    };
    var view = try buildView(
        allocator,
        "Evaluation sum\u{00ad}\nmary",
        .native_reading,
        .richDefault(),
        &evidence,
    );
    defer view.deinit();
}

test "search view ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildViewAllocationProbe,
        .{},
    );
}
