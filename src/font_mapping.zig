//! Independent PDF font mapping layers.
//!
//! Text extraction and rendering use related but distinct identifiers:
//! content bytes -> character code -> CID -> GID, while Unicode normally
//! comes from an explicit ToUnicode map or a documented fallback.

const std = @import("std");
const cff = @import("cff.zig");

pub const MappingSource = enum(u8) {
    explicit_to_unicode,
    actual_text,
    simple_encoding,
    adobe_collection,
    embedded_font_cmap,
    glyph_name,
    unresolved,

    pub fn name(self: MappingSource) []const u8 {
        return switch (self) {
            .explicit_to_unicode => "explicit_to_unicode",
            .actual_text => "actual_text",
            .simple_encoding => "simple_encoding",
            .adobe_collection => "adobe_collection",
            .embedded_font_cmap => "embedded_font_cmap",
            .glyph_name => "glyph_name",
            .unresolved => "unresolved",
        };
    }
};

pub const CodeSpace = struct {
    low: u32,
    high: u32,
    byte_count: u8,
};

pub const CodeToCidMap = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    usecmap_name: ?[]const u8 = null,
    codespaces: []const CodeSpace = &.{},
    singles: std.AutoHashMapUnmanaged(u32, u32) = .{},
    ranges: []const Range = &.{},
    notdef_singles: std.AutoHashMapUnmanaged(u32, u32) = .{},
    notdef_ranges: []const Range = &.{},
    bytes_per_char: u8 = 2,
    wmode: u8 = 0,
    identity: bool = false,
    unicode_coding: UnicodeCoding = .none,

    pub const UnicodeCoding = enum {
        none,
        ucs2,
        utf16,
    };

    pub const Range = struct {
        src_start: u32,
        src_end: u32,
        dst_start: u32,
    };

    pub const CharCode = struct {
        value: u32,
        bytes_consumed: u8,
    };

    pub fn init(allocator: std.mem.Allocator) CodeToCidMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CodeToCidMap) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.usecmap_name) |value| self.allocator.free(value);
        if (self.codespaces.len > 0) self.allocator.free(self.codespaces);
        if (self.ranges.len > 0) self.allocator.free(self.ranges);
        if (self.notdef_ranges.len > 0) self.allocator.free(self.notdef_ranges);
        self.singles.deinit(self.allocator);
        self.notdef_singles.deinit(self.allocator);
    }

    pub fn setName(self: *CodeToCidMap, value: []const u8) !void {
        if (self.name) |existing| self.allocator.free(existing);
        self.name = try self.allocator.dupe(u8, value);
    }

    pub fn setUseCMapName(self: *CodeToCidMap, value: []const u8) !void {
        if (self.usecmap_name) |existing| self.allocator.free(existing);
        self.usecmap_name = try self.allocator.dupe(u8, value);
    }

    pub fn lookup(self: *const CodeToCidMap, code: u32) ?u32 {
        if (self.singles.get(code)) |cid| return cid;
        if (lookupRange(self.ranges, code)) |cid| return cid;
        if (self.notdef_singles.get(code)) |cid| return cid;
        if (lookupRange(self.notdef_ranges, code)) |cid| return cid;
        if (self.identity) return code;
        return null;
    }

    pub fn readCharCode(self: *const CodeToCidMap, data: []const u8) ?CharCode {
        if (data.len == 0) return null;
        if (self.codespaces.len > 0) {
            var byte_count: u8 = 1;
            while (byte_count <= 4 and byte_count <= data.len) : (byte_count += 1) {
                const code = readCodeBE(data[0..byte_count]);
                for (self.codespaces) |space| {
                    if (space.byte_count == byte_count and code >= space.low and code <= space.high) {
                        return .{ .value = code, .bytes_consumed = byte_count };
                    }
                }
            }
            return null;
        }
        if (self.bytes_per_char > 1 and data.len >= self.bytes_per_char) {
            return .{
                .value = readCodeBE(data[0..self.bytes_per_char]),
                .bytes_consumed = self.bytes_per_char,
            };
        }
        return .{ .value = data[0], .bytes_consumed = 1 };
    }

    fn lookupRange(ranges: []const Range, code: u32) ?u32 {
        for (ranges) |range| {
            if (code >= range.src_start and code <= range.src_end) {
                return range.dst_start + (code - range.src_start);
            }
        }
        return null;
    }
};

pub const ToUnicodeMap = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    usecmap_name: ?[]const u8 = null,
    codespaces: []const CodeSpace = &.{},
    scalar_map: std.AutoHashMapUnmanaged(u32, u21) = .{},
    multi_map: std.AutoHashMapUnmanaged(u32, []const u8) = .{},
    ranges: []const Range = &.{},
    explicit: bool = false,

    pub const Range = struct {
        src_start: u32,
        src_end: u32,
        dst_start: u21,
    };

    pub fn init(allocator: std.mem.Allocator) ToUnicodeMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToUnicodeMap) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.usecmap_name) |value| self.allocator.free(value);
        if (self.codespaces.len > 0) self.allocator.free(self.codespaces);
        if (self.ranges.len > 0) self.allocator.free(self.ranges);
        var iterator = self.multi_map.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.scalar_map.deinit(self.allocator);
        self.multi_map.deinit(self.allocator);
    }

    pub fn setName(self: *ToUnicodeMap, value: []const u8) !void {
        if (self.name) |existing| self.allocator.free(existing);
        self.name = try self.allocator.dupe(u8, value);
    }

    pub fn setUseCMapName(self: *ToUnicodeMap, value: []const u8) !void {
        if (self.usecmap_name) |existing| self.allocator.free(existing);
        self.usecmap_name = try self.allocator.dupe(u8, value);
    }

    pub fn lookupScalar(self: *const ToUnicodeMap, code: u32) ?u21 {
        if (self.scalar_map.get(code)) |value| return value;
        for (self.ranges) |range| {
            if (code >= range.src_start and code <= range.src_end) {
                const value = @as(u32, range.dst_start) + (code - range.src_start);
                if (value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF)) {
                    return @intCast(value);
                }
                return null;
            }
        }
        return null;
    }
};

pub const SimpleEncoding = struct {
    codepoints: [256]u21,
    sources: [256]MappingSource,

    pub fn init(codepoints: [256]u21, source: MappingSource) SimpleEncoding {
        return .{
            .codepoints = codepoints,
            .sources = @splat(source),
        };
    }

    pub fn replace(self: *SimpleEncoding, codepoints: [256]u21, source: MappingSource) void {
        self.codepoints = codepoints;
        self.sources = @splat(source);
    }
};

pub const CidCollectionMap = struct {
    kind: Kind = .none,
    supplement: i32 = 0,

    pub const Kind = enum {
        none,
        identity,
        adobe_japan1,
        adobe_gb1,
        adobe_cns1,
        adobe_korea1,
    };

    pub fn name(self: CidCollectionMap) []const u8 {
        return switch (self.kind) {
            .none => "none",
            .identity => "Adobe-Identity",
            .adobe_japan1 => "Adobe-Japan1",
            .adobe_gb1 => "Adobe-GB1",
            .adobe_cns1 => "Adobe-CNS1",
            .adobe_korea1 => "Adobe-Korea1",
        };
    }

    /// Collection resources are intentionally separate from the mapping
    /// mechanism. Until a collection table is loaded, absence is explicit.
    pub fn lookup(_: CidCollectionMap, _: u32) ?u21 {
        return null;
    }
};

pub const CidToGidMap = struct {
    mapping: MappingType = .identity,

    pub const MappingType = union(enum) {
        identity: void,
        stream_map: []const u16,
    };

    pub fn getGid(self: *const CidToGidMap, cid: u32) u32 {
        return switch (self.mapping) {
            .identity => cid,
            .stream_map => |map| if (cid < map.len) map[cid] else cid,
        };
    }

    pub fn name(self: *const CidToGidMap) []const u8 {
        return switch (self.mapping) {
            .identity => "identity",
            .stream_map => "stream",
        };
    }

    pub fn deinit(self: *CidToGidMap, allocator: std.mem.Allocator) void {
        switch (self.mapping) {
            .identity => {},
            .stream_map => |map| allocator.free(map),
        }
    }
};

pub const EmbeddedFontMap = struct {
    allocator: std.mem.Allocator,
    kind: Kind = .none,
    gid_to_unicode: std.AutoHashMapUnmanaged(u32, u21) = .{},
    cff_parser: ?cff.CffParser = null,
    cff_data: ?[]const u8 = null,

    pub const Kind = enum {
        none,
        type1,
        cff,
        cid_cff,
        truetype,
        opentype,
        type3,
    };

    pub fn init(allocator: std.mem.Allocator) EmbeddedFontMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EmbeddedFontMap) void {
        self.gid_to_unicode.deinit(self.allocator);
        if (self.cff_parser) |*parser| parser.deinit();
        if (self.cff_data) |data| self.allocator.free(data);
    }

    pub fn name(self: *const EmbeddedFontMap) []const u8 {
        return switch (self.kind) {
            .none => "none",
            .type1 => "Type1",
            .cff => "Type1C",
            .cid_cff => "CIDFontType0C",
            .truetype => "TrueType",
            .opentype => "OpenType",
            .type3 => "Type3",
        };
    }

    pub fn lookupUnicode(self: *const EmbeddedFontMap, gid: u32) ?u21 {
        return self.gid_to_unicode.get(gid);
    }

    pub fn loadCff(self: *EmbeddedFontMap, data: []u8, kind: Kind) void {
        self.kind = kind;
        self.cff_data = data;
        self.cff_parser = cff.CffParser.init(self.allocator, data) catch null;
    }

    pub fn loadSfnt(self: *EmbeddedFontMap, data: []const u8, kind: Kind) !void {
        self.kind = kind;
        const cmap = findSfntTable(data, "cmap") orelse return;
        const maxp = findSfntTable(data, "maxp") orelse return;
        if (maxp.len < 6 or cmap.len < 4) return;
        const glyph_count = readU16(maxp, 4) orelse return;
        const subtable = selectUnicodeCmap(cmap) orelse return;
        const format = readU16(subtable, 0) orelse return;
        switch (format) {
            4 => try self.loadCmapFormat4(subtable, glyph_count),
            12 => try self.loadCmapFormat12(subtable, glyph_count),
            else => {},
        }
    }

    fn loadCmapFormat4(self: *EmbeddedFontMap, table: []const u8, glyph_count: u16) !void {
        if (table.len < 16) return;
        const declared_length = readU16(table, 2) orelse return;
        const data = table[0..@min(table.len, declared_length)];
        const seg_count = (readU16(data, 6) orelse return) / 2;
        if (seg_count == 0) return;
        const end_offset: usize = 14;
        const start_offset = end_offset + @as(usize, seg_count) * 2 + 2;
        const delta_offset = start_offset + @as(usize, seg_count) * 2;
        const range_offset = delta_offset + @as(usize, seg_count) * 2;
        if (range_offset + @as(usize, seg_count) * 2 > data.len) return;

        for (0..seg_count) |segment| {
            const end_code = readU16(data, end_offset + segment * 2) orelse continue;
            const start_code = readU16(data, start_offset + segment * 2) orelse continue;
            const delta = readU16(data, delta_offset + segment * 2) orelse continue;
            const range = readU16(data, range_offset + segment * 2) orelse continue;
            if (start_code > end_code) continue;
            var codepoint: u32 = start_code;
            while (codepoint <= end_code and codepoint != 0xFFFF) : (codepoint += 1) {
                var gid: u16 = 0;
                if (range == 0) {
                    gid = @truncate(codepoint +% delta);
                } else {
                    const word_offset = range_offset + segment * 2;
                    const glyph_offset = word_offset + range + (codepoint - start_code) * 2;
                    const raw_gid = readU16(data, glyph_offset) orelse continue;
                    if (raw_gid != 0) gid = raw_gid +% delta;
                }
                if (gid == 0 or gid >= glyph_count or self.gid_to_unicode.contains(gid)) continue;
                try self.gid_to_unicode.put(self.allocator, gid, @intCast(codepoint));
            }
        }
    }

    fn loadCmapFormat12(self: *EmbeddedFontMap, table: []const u8, glyph_count: u16) !void {
        if (table.len < 16) return;
        const declared_length = readU32(table, 4) orelse return;
        const data = table[0..@min(table.len, declared_length)];
        const group_count = readU32(data, 12) orelse return;
        var group_index: u32 = 0;
        while (group_index < group_count) : (group_index += 1) {
            const offset: usize = 16 + @as(usize, group_index) * 12;
            const start = readU32(data, offset) orelse break;
            const end = readU32(data, offset + 4) orelse break;
            const start_gid = readU32(data, offset + 8) orelse break;
            if (start > end) continue;
            const max_count = @min(end - start + 1, @as(u32, glyph_count));
            for (0..max_count) |delta| {
                const codepoint = start + @as(u32, @intCast(delta));
                const gid = start_gid + @as(u32, @intCast(delta));
                if (codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) continue;
                if (gid == 0 or gid >= glyph_count or self.gid_to_unicode.contains(gid)) continue;
                try self.gid_to_unicode.put(self.allocator, gid, @intCast(codepoint));
            }
        }
    }
};

fn findSfntTable(data: []const u8, tag: *const [4]u8) ?[]const u8 {
    if (data.len < 12) return null;
    const table_count = readU16(data, 4) orelse return null;
    for (0..table_count) |index| {
        const record_offset = 12 + index * 16;
        if (record_offset + 16 > data.len) return null;
        if (!std.mem.eql(u8, data[record_offset .. record_offset + 4], tag)) continue;
        const offset = readU32(data, record_offset + 8) orelse return null;
        const length = readU32(data, record_offset + 12) orelse return null;
        const end = std.math.add(usize, offset, length) catch return null;
        if (end > data.len) return null;
        return data[offset..end];
    }
    return null;
}

fn selectUnicodeCmap(cmap: []const u8) ?[]const u8 {
    const record_count = readU16(cmap, 2) orelse return null;
    var best: ?[]const u8 = null;
    var best_score: u8 = 0;
    for (0..record_count) |index| {
        const offset = 4 + index * 8;
        const platform = readU16(cmap, offset) orelse continue;
        const encoding = readU16(cmap, offset + 2) orelse continue;
        const subtable_offset = readU32(cmap, offset + 4) orelse continue;
        if (subtable_offset + 2 > cmap.len) continue;
        const subtable = cmap[subtable_offset..];
        const format = readU16(subtable, 0) orelse continue;
        const score: u8 = if (format == 12 and platform == 3 and encoding == 10)
            5
        else if (format == 12 and platform == 0)
            4
        else if (format == 4 and platform == 3 and encoding == 1)
            3
        else if (format == 4 and platform == 0)
            2
        else
            0;
        if (score > best_score) {
            best_score = score;
            best = subtable;
        }
    }
    return best;
}

fn readCodeBE(data: []const u8) u32 {
    var value: u32 = 0;
    for (data) |byte| value = (value << 8) | byte;
    return value;
}

fn readU16(data: []const u8, offset: usize) ?u16 {
    if (offset + 2 > data.len) return null;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readU32(data: []const u8, offset: usize) ?u32 {
    if (offset + 4 > data.len) return null;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

test "CID and embedded mappings remain independent" {
    var code_map = CodeToCidMap.init(std.testing.allocator);
    defer code_map.deinit();
    code_map.identity = true;
    try std.testing.expectEqual(@as(?u32, 41), code_map.lookup(41));

    var cid_to_gid: CidToGidMap = .{};
    try std.testing.expectEqual(@as(u32, 41), cid_to_gid.getGid(41));

    const collection = CidCollectionMap{ .kind = .identity };
    try std.testing.expectEqual(@as(?u21, null), collection.lookup(41));
}

test "embedded TrueType cmap validates GID to Unicode mapping" {
    const sfnt =
        "\x00\x01\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00" ++
        "cmap\x00\x00\x00\x00\x00\x00\x00\x2c\x00\x00\x00\x2c" ++
        "maxp\x00\x00\x00\x00\x00\x00\x00\x58\x00\x00\x00\x06" ++
        "\x00\x00\x00\x01\x00\x03\x00\x01\x00\x00\x00\x0c" ++
        "\x00\x04\x00\x20\x00\x00\x00\x04\x00\x04\x00\x01\x00\x00" ++
        "\x00\x41\xff\xff\x00\x00\x00\x41\xff\xff\xff\xc0\x00\x01\x00\x00\x00\x00" ++
        "\x00\x01\x00\x00\x00\x02";

    var embedded = EmbeddedFontMap.init(std.testing.allocator);
    defer embedded.deinit();
    try embedded.loadSfnt(sfnt, .truetype);
    try std.testing.expectEqual(@as(?u21, 'A'), embedded.lookupUnicode(1));
    try std.testing.expectEqual(@as(?u21, null), embedded.lookupUnicode(0));
}
