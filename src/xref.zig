//! PDF Cross-Reference (XRef) Parser
//!
//! Handles both formats:
//! 1. Traditional XRef table (pre-1.5): "xref\n0 100\n0000000000 65535 f\n..."
//! 2. XRef stream (1.5+): Compressed stream with binary entries
//!
//! Key insight: Parse backwards from EOF to find startxref, then follow /Prev chain

const std = @import("std");
const parser = @import("parser.zig");
const decompress = @import("decompress.zig");
const simd = @import("simd.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;

pub const XRefEntry = struct {
    /// Byte offset in file (type 1) or object number of containing objstm (type 2)
    offset: u64,
    /// Generation number (type 1) or index within objstm (type 2)
    gen_or_index: u32,
    /// Entry type
    entry_type: EntryType,

    pub const EntryType = enum {
        free, // Type 0: free object
        in_use, // Type 1: normal object at offset
        compressed, // Type 2: in object stream
    };
};

pub const XRefTable = struct {
    entries: std.AutoHashMap(u32, XRefEntry),
    trailer: Object.Dict,
    /// Allocator for HashMap internals
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) XRefTable {
        return .{
            .entries = std.AutoHashMap(u32, XRefEntry).init(allocator),
            .trailer = Object.Dict{ .entries = &.{} },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *XRefTable) void {
        self.entries.deinit();
        // Note: trailer is allocated from parsing arena, freed separately
    }

    pub fn get(self: XRefTable, obj_num: u32) ?XRefEntry {
        return self.entries.get(obj_num);
    }
};

pub const XRefParseError = error{
    StartXrefNotFound,
    InvalidStartXrefValue,
    InvalidXrefOffset,
    XrefSectionNotFound,
    InvalidXrefTable,
    InvalidXrefStream,
    InvalidTrailer,
    UnsupportedXrefFormat,
    OutOfMemory,
};

/// Parse XRef from PDF data, starting from EOF
/// hash_allocator: used for XRefTable.entries HashMap
/// parse_allocator: used for parsing objects (can be arena)
pub fn parseXRef(hash_allocator: std.mem.Allocator, parse_allocator: std.mem.Allocator, data: []const u8) XRefParseError!XRefTable {
    // Prefer startxref, but recover by scanning for a traditional xref table
    // when the pointer is missing, corrupt, or points into unrelated bytes.
    const startxref_offset = readStartXref(data) catch |err| {
        const recovered = findRecoverableXrefOffset(data) orelse return err;
        return parseXRefFromOffset(hash_allocator, parse_allocator, data, recovered);
    };

    return parseXRefFromOffset(hash_allocator, parse_allocator, data, startxref_offset) catch |err| switch (err) {
        XRefParseError.InvalidXrefOffset,
        XRefParseError.XrefSectionNotFound,
        XRefParseError.InvalidXrefTable,
        XRefParseError.InvalidXrefStream,
        XRefParseError.InvalidTrailer,
        => {
            const recovered = findRecoverableXrefOffset(data) orelse return err;
            if (recovered == startxref_offset) return err;
            return parseXRefFromOffset(hash_allocator, parse_allocator, data, recovered);
        },
        else => return err,
    };
}

fn parseXRefFromOffset(hash_allocator: std.mem.Allocator, parse_allocator: std.mem.Allocator, data: []const u8, startxref_offset: u64) XRefParseError!XRefTable {
    var xref = XRefTable.init(hash_allocator);
    errdefer xref.deinit();

    // Parse XRef chain (following /Prev links for incremental updates)
    var current_offset: ?u64 = startxref_offset;

    while (current_offset) |offset| {
        if (offset >= data.len) return XRefParseError.InvalidXrefOffset;

        const xref_start = data[@intCast(offset)..];

        if (std.mem.startsWith(u8, xref_start, "xref")) {
            // Traditional xref table
            const trailer = try parseXrefTable(parse_allocator, data, offset, &xref);
            if (xref.trailer.entries.len == 0) {
                xref.trailer = trailer;
            }
            current_offset = getTrailerPrev(trailer);
        } else if (looksLikeIndirectObject(xref_start)) {
            // XRef stream (starts with object definition like "10 0 obj")
            const trailer = try parseXrefStream(parse_allocator, data, offset, &xref);
            if (xref.trailer.entries.len == 0) {
                xref.trailer = trailer;
            }
            current_offset = getTrailerPrev(trailer);
        } else {
            return XRefParseError.XrefSectionNotFound;
        }
    }

    return xref;
}

fn findRecoverableXrefOffset(data: []const u8) ?u64 {
    var search_end = data.len;

    while (search_end > 0) {
        const pos = std.mem.lastIndexOf(u8, data[0..search_end], "xref") orelse return null;
        search_end = pos;

        if (pos >= 5 and std.mem.eql(u8, data[pos - 5 .. pos], "start")) {
            continue;
        }

        if (looksLikeTraditionalXrefCandidate(data, pos)) return @intCast(pos);
    }

    return null;
}

fn looksLikeTraditionalXrefCandidate(data: []const u8, pos: usize) bool {
    const before_ok = pos == 0 or data[pos - 1] == '\n' or data[pos - 1] == '\r';
    const after = pos + 4;
    if (!before_ok or after > data.len or (after < data.len and !isWhitespace(data[after]))) {
        return false;
    }

    var scan = after;
    while (scan < data.len and isWhitespace(data[scan])) scan += 1;
    return scan < data.len and data[scan] >= '0' and data[scan] <= '9';
}

fn readStartXref(data: []const u8) XRefParseError!u64 {
    const marker = findStartXrefMarker(data) orelse return XRefParseError.StartXrefNotFound;
    var pos = marker + 9; // len("startxref")

    while (pos < data.len and isWhitespace(data[pos])) {
        pos += 1;
    }

    const start = pos;
    var offset: u64 = 0;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        offset = std.math.mul(u64, offset, 10) catch return XRefParseError.InvalidStartXrefValue;
        offset = std.math.add(u64, offset, data[pos] - '0') catch return XRefParseError.InvalidStartXrefValue;
        pos += 1;
    }

    if (pos == start) return XRefParseError.InvalidStartXrefValue;
    return offset;
}

/// Find "startxref" near end of file and parse the offset
/// For incremental updates, we need the LAST startxref (the most recent one)
fn findStartXref(data: []const u8) ?u64 {
    return readStartXref(data) catch null;
}

fn findStartXrefMarker(data: []const u8) ?usize {
    // PDF spec says startxref should be in last 1024 bytes
    const search_start = if (data.len > 1024) data.len - 1024 else 0;
    const search_region = data[search_start..];

    // Find the LAST occurrence of "startxref" for incremental updates
    var last_pos: ?usize = null;
    var search_pos: usize = 0;

    while (search_pos < search_region.len) {
        if (simd.findSubstring(search_region[search_pos..], "startxref")) |rel_pos| {
            last_pos = search_pos + rel_pos;
            search_pos = last_pos.? + 9; // Continue searching after this occurrence
        } else {
            break;
        }
    }

    const startxref_pos = last_pos orelse return null;
    return search_start + startxref_pos;
}

fn looksLikeIndirectObject(data: []const u8) bool {
    var pos: usize = 0;
    if (!scanUnsigned(data, &pos)) return false;
    while (pos < data.len and isWhitespace(data[pos])) pos += 1;
    if (!scanUnsigned(data, &pos)) return false;
    while (pos < data.len and isWhitespace(data[pos])) pos += 1;
    return pos + 3 <= data.len and std.mem.eql(u8, data[pos..][0..3], "obj");
}

fn scanUnsigned(data: []const u8, pos: *usize) bool {
    const start = pos.*;
    while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') {
        pos.* += 1;
    }
    return pos.* > start;
}

/// Parse traditional xref table format
fn parseXrefTable(
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: u64,
    xref: *XRefTable,
) XRefParseError!Object.Dict {
    var pos: usize = @intCast(offset);

    // Skip "xref" keyword
    if (pos + 4 > data.len or !std.mem.eql(u8, data[pos..][0..4], "xref")) {
        return XRefParseError.InvalidXrefTable;
    }
    pos += 4;

    // Parse subsections
    while (pos < data.len) {
        // Skip whitespace
        while (pos < data.len and isWhitespace(data[pos])) pos += 1;

        // Check for trailer
        if (pos + 7 <= data.len and std.mem.eql(u8, data[pos..][0..7], "trailer")) {
            pos += 7;
            while (pos < data.len and isWhitespace(data[pos])) pos += 1;

            var p = parser.Parser.initAt(allocator, data, pos);
            const trailer_obj = p.parseObject() catch return XRefParseError.InvalidTrailer;

            return switch (trailer_obj) {
                .dict => |d| d,
                else => XRefParseError.InvalidTrailer,
            };
        }

        // Parse subsection header: "first_obj count"
        const first_obj = parseUint(data, &pos) orelse break;
        while (pos < data.len and isWhitespace(data[pos])) pos += 1;
        const count = parseUint(data, &pos) orelse return XRefParseError.InvalidXrefTable;

        // Skip to first entry
        while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
        if (pos < data.len and data[pos] == '\r') pos += 1;
        if (pos < data.len and data[pos] == '\n') pos += 1;

        // Parse entries (each is 20 bytes: "oooooooooo ggggg n|f\r\n" or similar)
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            if (pos + 17 > data.len) break;

            // Parse 10-digit offset
            const entry_offset = parseFixedUint(data[pos..][0..10]) orelse {
                pos += 20;
                continue;
            };
            pos += 10;

            // Skip space
            if (pos < data.len and data[pos] == ' ') pos += 1;

            // Parse 5-digit generation
            const gen = parseFixedUint(data[pos..][0..5]) orelse {
                pos += 10;
                continue;
            };
            pos += 5;

            // Skip space
            if (pos < data.len and data[pos] == ' ') pos += 1;

            // Parse type (n or f)
            const entry_type: XRefEntry.EntryType = if (pos < data.len and data[pos] == 'n')
                .in_use
            else
                .free;
            pos += 1;

            // Skip EOL
            while (pos < data.len and (data[pos] == ' ' or data[pos] == '\r' or data[pos] == '\n')) {
                pos += 1;
            }

            const obj_num: u32 = @intCast(first_obj + i);

            // Only add if not already present (first occurrence wins for incremental updates)
            if (!xref.entries.contains(obj_num)) {
                xref.entries.put(obj_num, .{
                    .offset = entry_offset,
                    .gen_or_index = @intCast(gen),
                    .entry_type = entry_type,
                }) catch return XRefParseError.OutOfMemory;
            }
        }
    }

    return XRefParseError.InvalidXrefTable;
}

/// Parse XRef stream format (PDF 1.5+)
fn parseXrefStream(
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: u64,
    xref: *XRefTable,
) XRefParseError!Object.Dict {
    // Parse the stream object
    var p = parser.Parser.initAt(allocator, data, @intCast(offset));
    const indirect = p.parseIndirectObject() catch return XRefParseError.InvalidXrefStream;

    const stream = switch (indirect.obj) {
        .stream => |s| s,
        else => return XRefParseError.InvalidXrefStream,
    };

    const dict = stream.dict;

    // Verify it's an XRef stream
    const stream_type = dict.getName("Type") orelse return XRefParseError.InvalidXrefStream;
    if (!std.mem.eql(u8, stream_type, "XRef")) return XRefParseError.InvalidXrefStream;

    // Get /W array (field widths)
    const w_array = dict.getArray("W") orelse return XRefParseError.InvalidXrefStream;
    if (w_array.len != 3) return XRefParseError.InvalidXrefStream;

    const w0: usize = switch (w_array[0]) {
        .integer => |i| if (i >= 0) @intCast(i) else return XRefParseError.InvalidXrefStream,
        else => 1,
    };
    const w1: usize = switch (w_array[1]) {
        .integer => |i| if (i >= 0) @intCast(i) else return XRefParseError.InvalidXrefStream,
        else => 0,
    };
    const w2: usize = switch (w_array[2]) {
        .integer => |i| if (i >= 0) @intCast(i) else return XRefParseError.InvalidXrefStream,
        else => 0,
    };

    const entry_size = w0 + w1 + w2;
    if (entry_size == 0) return XRefParseError.InvalidXrefStream;

    // Decompress stream data (arena-allocated, no need to free)
    const decoded = decompress.decompressStream(
        allocator,
        stream.data,
        dict.get("Filter"),
        dict.get("DecodeParms"),
    ) catch return XRefParseError.InvalidXrefStream;

    // Get /Index array (object number ranges), default is [0 Size]
    const size = dict.getInt("Size") orelse return XRefParseError.InvalidXrefStream;
    const index_array = dict.getArray("Index");

    // Parse index pairs
    var ranges: std.ArrayList(struct { start: u64, count: u64 }) = .empty;
    defer ranges.deinit(allocator);

    if (index_array) |idx| {
        var j: usize = 0;
        while (j + 1 < idx.len) : (j += 2) {
            const start: u64 = switch (idx[j]) {
                .integer => |i| if (i >= 0) @intCast(i) else continue,
                else => continue,
            };
            const count: u64 = switch (idx[j + 1]) {
                .integer => |i| if (i >= 0) @intCast(i) else continue,
                else => continue,
            };
            ranges.append(allocator, .{ .start = start, .count = count }) catch return XRefParseError.OutOfMemory;
        }
    } else {
        if (size < 0) return XRefParseError.InvalidXrefStream;
        ranges.append(allocator, .{ .start = 0, .count = @intCast(size) }) catch return XRefParseError.OutOfMemory;
    }

    // Parse entries
    var data_pos: usize = 0;

    for (ranges.items) |range| {
        var obj_num = range.start;
        var count = range.count;

        while (count > 0) : ({
            count -= 1;
            obj_num += 1;
        }) {
            if (data_pos + entry_size > decoded.len) break;

            // Read type field (default 1 if w0 == 0)
            const entry_type_val: u64 = if (w0 > 0)
                readUintBE(decoded[data_pos..][0..w0])
            else
                1;

            // Read field2
            const field2: u64 = if (w1 > 0)
                readUintBE(decoded[data_pos + w0 ..][0..w1])
            else
                0;

            // Read field3
            const field3: u64 = if (w2 > 0)
                readUintBE(decoded[data_pos + w0 + w1 ..][0..w2])
            else
                0;

            data_pos += entry_size;

            const entry: XRefEntry = switch (entry_type_val) {
                0 => .{
                    .offset = field2, // Next free object
                    .gen_or_index = @intCast(field3), // Gen if reused
                    .entry_type = .free,
                },
                1 => .{
                    .offset = field2, // Byte offset
                    .gen_or_index = @intCast(field3), // Generation
                    .entry_type = .in_use,
                },
                2 => .{
                    .offset = field2, // Object stream number
                    .gen_or_index = @intCast(field3), // Index within stream
                    .entry_type = .compressed,
                },
                else => continue,
            };

            const num: u32 = @intCast(obj_num);
            if (!xref.entries.contains(num)) {
                xref.entries.put(num, entry) catch return XRefParseError.OutOfMemory;
            }
        }
    }

    return dict;
}

fn getTrailerPrev(trailer: Object.Dict) ?u64 {
    const prev = trailer.getInt("Prev") orelse return null;
    if (prev < 0) return null;
    return @intCast(prev);
}

fn parseUint(data: []const u8, pos: *usize) ?u64 {
    var value: u64 = 0;
    var found = false;

    while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') {
        value = value * 10 + (data[pos.*] - '0');
        pos.* += 1;
        found = true;
    }

    return if (found) value else null;
}

fn parseFixedUint(data: []const u8) ?u64 {
    var value: u64 = 0;

    for (data) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + (c - '0');
        } else if (c != ' ') {
            return null;
        }
    }

    return value;
}

fn readUintBE(data: []const u8) u64 {
    var value: u64 = 0;
    for (data) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

// ============================================================================
// TESTS
// ============================================================================

test "parse simple xref table" {
    const pdf_data =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog >>
        \\endobj
        \\xref
        \\0 2
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\trailer
        \\<< /Size 2 /Root 1 0 R >>
        \\startxref
        \\45
        \\%%EOF
    ;

    // Use arena for parsed objects (like real usage)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var xref = try parseXRef(std.testing.allocator, arena.allocator(), pdf_data);
    defer xref.deinit();

    // Should have 2 entries
    try std.testing.expect(xref.entries.contains(0));
    try std.testing.expect(xref.entries.contains(1));

    const entry1 = xref.get(1).?;
    try std.testing.expectEqual(XRefEntry.EntryType.in_use, entry1.entry_type);
    try std.testing.expectEqual(@as(u64, 9), entry1.offset);
}

test "find startxref" {
    const data = "lots of content here\nstartxref\n12345\n%%EOF";
    const offset = findStartXref(data);
    try std.testing.expectEqual(@as(u64, 12345), offset.?);
}

test "parse xref rejects non-numeric startxref deterministically" {
    const pdf_data =
        \\%PDF-1.4
        \\startxref
        \\not-a-number
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        XRefParseError.InvalidStartXrefValue,
        parseXRef(std.testing.allocator, arena.allocator(), pdf_data),
    );
}

test "parse xref reports offset that is not an xref section when unrecoverable" {
    const pdf_data =
        \\%PDF-1.4
        \\not an xref section
        \\startxref
        \\9
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        XRefParseError.XrefSectionNotFound,
        parseXRef(std.testing.allocator, arena.allocator(), pdf_data),
    );
}

test "parse xref recovers when startxref points at unrelated bytes" {
    const pdf_data =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog >>
        \\endobj
        \\xref
        \\0 2
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\trailer
        \\<< /Size 2 /Root 1 0 R >>
        \\startxref
        \\9
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var recovered = try parseXRef(std.testing.allocator, arena.allocator(), pdf_data);
    defer recovered.deinit();

    try std.testing.expect(recovered.entries.contains(1));
    try std.testing.expectEqual(@as(i64, 2), recovered.trailer.getInt("Size").?);
}

test "parse xref recovers when startxref is absent" {
    const pdf_data =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog >>
        \\endobj
        \\xref
        \\0 2
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\trailer
        \\<< /Size 2 /Root 1 0 R >>
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var recovered = try parseXRef(std.testing.allocator, arena.allocator(), pdf_data);
    defer recovered.deinit();

    try std.testing.expect(recovered.entries.contains(1));
    try std.testing.expectEqual(@as(i64, 2), recovered.trailer.getInt("Size").?);
}

test "parse xref rejects malformed trailer deterministically" {
    const pdf_data =
        \\%PDF-1.4
        \\xref
        \\0 1
        \\0000000000 65535 f
        \\trailer
        \\[ /not-a-dict ]
        \\startxref
        \\9
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        XRefParseError.InvalidTrailer,
        parseXRef(std.testing.allocator, arena.allocator(), pdf_data),
    );
}

test "parse xref reports invalid Prev offset deterministically" {
    const pdf_data =
        \\%PDF-1.4
        \\xref
        \\0 1
        \\0000000000 65535 f
        \\trailer
        \\<< /Size 1 /Prev 9999 >>
        \\startxref
        \\9
        \\%%EOF
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        XRefParseError.InvalidXrefOffset,
        parseXRef(std.testing.allocator, arena.allocator(), pdf_data),
    );
}
