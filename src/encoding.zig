//! PDF Font Encoding
//!
//! Handles conversion from PDF glyph codes to Unicode.
//!
//! Encoding precedence:
//! 1. /ToUnicode CMap (best - explicit mapping)
//! 2. /Encoding (name or dict with /Differences)
//! 3. Built-in encoding from font type
//!
//! Standard encodings: WinAnsiEncoding, MacRomanEncoding, MacExpertEncoding
//! CID fonts use CIDToGIDMap instead

const std = @import("std");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const decompress = @import("decompress.zig");
const cff = @import("cff.zig");
const agl = @import("agl.zig");

const Object = parser.Object;

/// Font metrics from FontDescriptor
pub const FontMetrics = struct {
    /// Ascender height (in glyph space units, typically 1000 units = 1 em)
    ascender: f64 = 800,
    /// Descender depth (negative value)
    descender: f64 = -200,
    /// Cap height
    cap_height: f64 = 700,
    /// X-height (height of lowercase 'x')
    x_height: f64 = 500,
    /// Font bounding box [llx, lly, urx, ury]
    bbox: [4]f64 = .{ 0, -200, 1000, 800 },
    /// Default glyph width
    default_width: f64 = 600,
    /// Italic angle (negative = right-leaning)
    italic_angle: f64 = 0,
    /// Missing width (for undefined glyphs)
    missing_width: f64 = 0,
};

/// CID System Info - identifies the character collection
pub const CIDSystemInfo = struct {
    registry: []const u8 = "Adobe",
    ordering: []const u8 = "Identity",
    supplement: i32 = 0,

    pub fn isAdobeJapan(self: *const CIDSystemInfo) bool {
        return std.mem.eql(u8, self.registry, "Adobe") and
            std.mem.eql(u8, self.ordering, "Japan1");
    }

    pub fn isAdobeGB(self: *const CIDSystemInfo) bool {
        return std.mem.eql(u8, self.registry, "Adobe") and
            std.mem.eql(u8, self.ordering, "GB1");
    }

    pub fn isAdobeCNS(self: *const CIDSystemInfo) bool {
        return std.mem.eql(u8, self.registry, "Adobe") and
            std.mem.eql(u8, self.ordering, "CNS1");
    }

    pub fn isAdobeKorea(self: *const CIDSystemInfo) bool {
        return std.mem.eql(u8, self.registry, "Adobe") and
            std.mem.eql(u8, self.ordering, "Korea1");
    }

    pub fn isIdentity(self: *const CIDSystemInfo) bool {
        return std.mem.eql(u8, self.ordering, "Identity");
    }
};

/// CID to GID mapping for TrueType-based CID fonts
pub const CIDToGIDMap = struct {
    /// Mapping type
    mapping: MappingType,

    pub const MappingType = union(enum) {
        /// Identity mapping: CID = GID
        identity: void,
        /// Explicit mapping from stream
        stream_map: []const u16,
    };

    pub fn init() CIDToGIDMap {
        return .{ .mapping = .identity };
    }

    pub fn getGID(self: *const CIDToGIDMap, cid: u32) u32 {
        return switch (self.mapping) {
            .identity => cid,
            .stream_map => |map| blk: {
                if (cid < map.len) {
                    break :blk map[cid];
                }
                break :blk cid;
            },
        };
    }
};

/// Glyph widths for accurate positioning
pub const GlyphWidths = struct {
    /// Simple font: widths indexed by character code (0-255)
    simple_widths: [256]f64,
    /// CID font: widths mapped from CID ranges
    cid_widths: []const CIDWidthEntry,
    /// Default width for CID fonts
    default_width: f64,
    /// First character code (for simple fonts)
    first_char: u16,
    /// Last character code (for simple fonts)
    last_char: u16,
    allocator: std.mem.Allocator,

    pub const CIDWidthEntry = struct {
        cid_start: u32,
        cid_end: u32,
        width: f64,
    };

    pub fn init(allocator: std.mem.Allocator) GlyphWidths {
        var widths = GlyphWidths{
            .simple_widths = undefined,
            .cid_widths = &.{},
            .default_width = 1000,
            .first_char = 0,
            .last_char = 255,
            .allocator = allocator,
        };
        // Simple base fonts often omit /Widths. Use the historical 0.5em
        // extraction fallback until a PDF supplies explicit widths.
        for (&widths.simple_widths) |*w| {
            w.* = 500;
        }
        return widths;
    }

    pub fn deinit(self: *GlyphWidths) void {
        if (self.cid_widths.len > 0) {
            self.allocator.free(self.cid_widths);
        }
    }

    /// Get width for a character code (simple font)
    pub fn getWidth(self: *const GlyphWidths, char_code: u8) f64 {
        if (char_code < self.first_char or char_code > self.last_char) {
            return self.default_width;
        }
        return self.simple_widths[char_code];
    }

    /// Get width for a CID
    pub fn getCIDWidth(self: *const GlyphWidths, cid: u32) f64 {
        for (self.cid_widths) |entry| {
            if (cid >= entry.cid_start and cid <= entry.cid_end) {
                return entry.width;
            }
        }
        return self.default_width;
    }
};

/// Font encoding for character code to Unicode mapping
pub const FontEncoding = struct {
    /// Unicode codepoints indexed by character code (0-255 for simple fonts)
    codepoint_map: [256]u21,
    /// ToUnicode CMap ranges (for CID fonts or complex mappings)
    cmap_ranges: []const CMapRange,
    /// Valid source code spaces from begincodespacerange.
    cmap_codespaces: []const CMapCodeSpace,
    /// Fast lookup hash map for individual CMap entries (bfchar)
    cmap_hash: std.AutoHashMapUnmanaged(u32, u32),
    /// Multi-character ToUnicode mappings (for ligatures like fi, fl, ffi, ffl)
    cmap_multi: std.AutoHashMapUnmanaged(u32, []const u8),
    /// Is this a simple 8-bit encoding or complex CID encoding?
    is_cid: bool,
    /// Bytes per character (1 for simple, 1-4 for CID)
    bytes_per_char: u8,
    /// Writing mode: 0 = horizontal (default), 1 = vertical (East Asian)
    wmode: u8,
    /// Font metrics from FontDescriptor
    metrics: FontMetrics,
    /// Glyph widths
    widths: GlyphWidths,
    /// CID system info (for CID fonts)
    cid_system_info: CIDSystemInfo,
    /// CID to GID mapping (for CIDFontType2)
    cid_to_gid_map: CIDToGIDMap,
    /// CFF Parser for Type1/Type1C/CIDFontType0C
    cff_parser: ?cff.CffParser = null,
    /// Underlying CFF data (owned)
    cff_data: ?[]const u8 = null,
    /// True when this font dictionary supplied an explicit ToUnicode CMap.
    has_to_unicode: bool = false,
    /// True for /Subtype /Type3 fonts. These rely on PDF glyph programs but
    /// can still expose deterministic widths, bboxes, encodings, and ToUnicode.
    is_type3: bool = false,

    allocator: std.mem.Allocator,

    pub const CMapRange = struct {
        src_start: u32,
        src_end: u32,
        dst_start: u32,
        is_range: bool, // true = range mapping (bfrange)
    };

    pub const CMapCodeSpace = struct {
        low: u32,
        high: u32,
        byte_count: u8,
    };

    const CharCode = struct {
        value: u32,
        bytes_consumed: u8,
    };

    pub const DecodedGlyph = struct {
        source_code: u32,
        source_bytes: []const u8,
        bytes_consumed: u8,
        utf8_text: []const u8,
        glyph_width: f64,
        cid_or_gid: ?u32 = null,
        unicode_map_error: bool = false,
        multi_char_mapping: bool = false,
        writing_mode: u8 = 0,
        ascender: f64 = 800,
        descender: f64 = -200,
    };

    pub fn init(allocator: std.mem.Allocator) FontEncoding {
        var enc = FontEncoding{
            .codepoint_map = undefined,
            .cmap_ranges = &.{},
            .cmap_codespaces = &.{},
            .cmap_hash = .{},
            .cmap_multi = .{},
            .is_cid = false,
            .bytes_per_char = 1,
            .wmode = 0,
            .metrics = .{},
            .widths = GlyphWidths.init(allocator),
            .cid_system_info = .{},
            .cid_to_gid_map = CIDToGIDMap.init(),
            .allocator = allocator,
        };

        // Default to WinAnsi
        enc.codepoint_map = win_ansi_encoding;

        return enc;
    }

    pub fn deinit(self: *FontEncoding) void {
        if (self.cmap_ranges.len > 0) {
            self.allocator.free(self.cmap_ranges);
        }
        if (self.cmap_codespaces.len > 0) {
            self.allocator.free(self.cmap_codespaces);
        }
        self.cmap_hash.deinit(self.allocator);
        // Free multi-character mapping strings
        var it = self.cmap_multi.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.cmap_multi.deinit(self.allocator);
        self.widths.deinit();
        // Free CIDToGIDMap stream data if present
        switch (self.cid_to_gid_map.mapping) {
            .stream_map => |map| self.allocator.free(map),
            .identity => {},
        }
        if (self.cff_parser) |*parser_inst| {
            parser_inst.deinit();
        }
        if (self.cff_data) |data| {
            self.allocator.free(data);
        }
    }

    /// Decode a string to Unicode using this encoding
    pub fn decode(self: *const FontEncoding, data: []const u8, writer: anytype) !void {
        var sink = DecodeWriter(@TypeOf(writer)){ .writer = writer };
        try self.decodeRecords(data, &sink);
    }

    pub fn decodeRecords(self: *const FontEncoding, data: []const u8, sink: anytype) !void {
        if (self.is_cid) {
            try self.decodeCIDRecords(data, sink);
        } else {
            try self.decodeSimpleRecords(data, sink);
        }
    }

    fn DecodeWriter(comptime Writer: type) type {
        return struct {
            writer: Writer,

            pub fn writeDecodedGlyph(self: *@This(), glyph: DecodedGlyph) !void {
                try self.writer.writeAll(glyph.utf8_text);
            }
        };
    }

    fn decodeSimpleRecords(self: *const FontEncoding, data: []const u8, sink: anytype) !void {
        for (data, 0..) |byte, index| {
            // Check for multi-character mapping first (ligatures)
            if (self.cmap_multi.get(byte)) |utf8_str| {
                try sink.writeDecodedGlyph(.{
                    .source_code = byte,
                    .source_bytes = data[index .. index + 1],
                    .bytes_consumed = 1,
                    .utf8_text = utf8_str,
                    .glyph_width = self.widths.getWidth(byte),
                    .multi_char_mapping = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
                continue;
            }

            const codepoint = self.codepoint_map[byte];
            var buf: [4]u8 = undefined;
            if (codepoint == 0) {
                // No mapping - output replacement character or space
                try sink.writeDecodedGlyph(.{
                    .source_code = byte,
                    .source_bytes = data[index .. index + 1],
                    .bytes_consumed = 1,
                    .utf8_text = " ",
                    .glyph_width = self.widths.getWidth(byte),
                    .unicode_map_error = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            } else {
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                try sink.writeDecodedGlyph(.{
                    .source_code = byte,
                    .source_bytes = data[index .. index + 1],
                    .bytes_consumed = 1,
                    .utf8_text = buf[0..len],
                    .glyph_width = self.widths.getWidth(byte),
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            }
        }
    }

    fn decodeCIDRecords(self: *const FontEncoding, data: []const u8, sink: anytype) !void {
        var i: usize = 0;

        while (i < data.len) {
            // Try to read character code (1-4 bytes depending on font)
            const code = self.readCharCode(data[i..]) orelse {
                try sink.writeDecodedGlyph(.{
                    .source_code = data[i],
                    .source_bytes = data[i .. i + 1],
                    .bytes_consumed = 1,
                    .utf8_text = " ",
                    .glyph_width = self.widths.default_width,
                    .unicode_map_error = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
                i += 1;
                continue;
            };

            const source_start = i;
            i += code.bytes_consumed;

            // Check for multi-character mapping first (ligatures)
            if (self.cmap_multi.get(code.value)) |utf8_str| {
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = code.bytes_consumed,
                    .utf8_text = utf8_str,
                    .glyph_width = self.widths.getCIDWidth(code.value),
                    .cid_or_gid = code.value,
                    .multi_char_mapping = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
                continue;
            }

            // Look up in CMap ranges first
            var codepoint = self.lookupCMap(code.value);
            var unicode_map_error = false;

            // If no CMap mapping, try CFF lookup if available
            if (codepoint == null) {
                if (self.cff_parser) |*cff_p| {
                    const gid = @as(u16, @intCast(code.value & 0xFFFF));
                    if (cff_p.getGlyphName(gid)) |name| {
                        if (agl.glyphNameToUnicode(name)) |u| {
                            codepoint = u;
                        }
                    }
                }
            }

            // If no CMap mapping, try Identity interpretation
            if (codepoint == null) {
                // For Identity-H/Identity-V, the code might be UTF-16BE
                if (code.bytes_consumed == 2) {
                    const potential_unicode = code.value;
                    // Check if it's a valid Unicode codepoint
                    if (potential_unicode > 0 and potential_unicode <= 0x10FFFF) {
                        // Check if it's a surrogate pair (UTF-16)
                        if (potential_unicode >= 0xD800 and potential_unicode <= 0xDBFF) {
                            // High surrogate - need to read low surrogate
                            if (i + 2 <= data.len) {
                                const low: u32 = (@as(u32, data[i]) << 8) | data[i + 1];
                                if (low >= 0xDC00 and low <= 0xDFFF) {
                                    // Valid surrogate pair
                                    codepoint = 0x10000 + ((potential_unicode - 0xD800) << 10) + (low - 0xDC00);
                                    i += 2;
                                }
                            }
                        } else if (potential_unicode < 0xD800 or potential_unicode > 0xDFFF) {
                            // Not a surrogate - direct BMP character
                            codepoint = potential_unicode;
                        }
                    }
                }
            }

            if (codepoint == null and !self.cid_system_info.isIdentity()) {
                unicode_map_error = true;
            }

            const final_codepoint = codepoint orelse code.value;
            var buf: [4]u8 = undefined;

            if (final_codepoint == 0) {
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = @intCast(i - source_start),
                    .utf8_text = " ",
                    .glyph_width = self.widths.getCIDWidth(code.value),
                    .cid_or_gid = code.value,
                    .unicode_map_error = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            } else if (final_codepoint <= 0x10FFFF) {
                const suspicious_identity = self.is_cid and
                    self.cid_system_info.isIdentity() and
                    !self.has_to_unicode and
                    (final_codepoint < 0x20 or (final_codepoint >= 0x7F and final_codepoint <= 0x9F));
                const len = std.unicode.utf8Encode(@intCast(final_codepoint), &buf) catch 1;
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = @intCast(i - source_start),
                    .utf8_text = buf[0..len],
                    .glyph_width = self.widths.getCIDWidth(code.value),
                    .cid_or_gid = code.value,
                    .unicode_map_error = unicode_map_error or suspicious_identity,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            } else {
                // Invalid codepoint
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = @intCast(i - source_start),
                    .utf8_text = " ",
                    .glyph_width = self.widths.getCIDWidth(code.value),
                    .cid_or_gid = code.value,
                    .unicode_map_error = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            }
        }
    }

    fn readCharCode(self: *const FontEncoding, data: []const u8) ?CharCode {
        if (data.len == 0) return null;

        // For simple fonts, 1 byte
        if (!self.is_cid or self.bytes_per_char == 1) {
            return .{ .value = data[0], .bytes_consumed = 1 };
        }

        if (self.cmap_codespaces.len > 0) {
            return self.readCharCodeFromCodeSpaces(data);
        }

        // For CID fonts, always read bytes_per_char bytes
        if (self.bytes_per_char == 2 and data.len >= 2) {
            const code = (@as(u32, data[0]) << 8) | data[1];
            return .{ .value = code, .bytes_consumed = 2 };
        }

        // Fall back to 1 byte only if we don't have enough data
        return .{ .value = data[0], .bytes_consumed = 1 };
    }

    fn readCharCodeFromCodeSpaces(self: *const FontEncoding, data: []const u8) ?CharCode {
        var byte_count: u8 = 1;
        while (byte_count <= 4 and byte_count <= data.len) : (byte_count += 1) {
            const code = readCodeBE(data[0..byte_count]);
            for (self.cmap_codespaces) |space| {
                if (space.byte_count == byte_count and code >= space.low and code <= space.high) {
                    return .{ .value = code, .bytes_consumed = byte_count };
                }
            }
        }

        return null;
    }

    fn codeInRanges(self: *const FontEncoding, code: u32) bool {
        if (self.cmap_hash.contains(code)) return true;
        return self.binarySearchRange(code) != null;
    }

    fn lookupCMap(self: *const FontEncoding, code: u32) ?u32 {
        // Fast O(1) lookup in hash map first (for bfchar entries)
        if (self.cmap_hash.get(code)) |dst| {
            return dst;
        }
        // Binary search through sorted ranges (for bfrange entries)
        if (self.binarySearchRange(code)) |range| {
            return range.dst_start + (code - range.src_start);
        }
        return null;
    }

    /// Binary search for a range containing the given code.
    /// Ranges must be sorted by src_start (done during parsing).
    fn binarySearchRange(self: *const FontEncoding, code: u32) ?CMapRange {
        const ranges = self.cmap_ranges;
        if (ranges.len == 0) return null;

        var left: usize = 0;
        var right: usize = ranges.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const range = ranges[mid];

            if (code < range.src_start) {
                right = mid;
            } else if (code > range.src_end) {
                left = mid + 1;
            } else {
                // code is within this range
                if (range.is_range) {
                    return range;
                }
                return null;
            }
        }
        return null;
    }
};

/// Parse font encoding from font dictionary
pub fn parseFontEncoding(
    allocator: std.mem.Allocator,
    font_dict: Object.Dict,
    resolve_fn: *const fn (ctx: *const anyopaque, Object) Object,
    resolve_ctx: *const anyopaque,
) !FontEncoding {
    var encoding = FontEncoding.init(allocator);
    var parsed_tounicode = false;

    // Detect font type first
    const subtype = font_dict.getName("Subtype");
    const is_type0 = subtype != null and std.mem.eql(u8, subtype.?, "Type0");
    const is_type3 = subtype != null and std.mem.eql(u8, subtype.?, "Type3");
    encoding.is_type3 = is_type3;

    if (font_dict.getName("BaseFont")) |base_font| {
        applyBase14FallbackMetrics(&encoding, base_font);
    }

    // For Type0 (composite) fonts, check DescendantFonts
    if (is_type0) {
        encoding.is_cid = true;
        encoding.bytes_per_char = 2;

        // Parse CMap encoding for Type0 fonts
        if (font_dict.get("Encoding")) |enc_obj| {
            const resolved = resolve_fn(resolve_ctx, enc_obj);
            switch (resolved) {
                .name => |name| applyPredefinedCMap(&encoding, name),
                .stream => |stream| try parseToUnicodeCMap(allocator, stream, &encoding),
                else => {},
            }
        }

        // Get CIDFont from DescendantFonts array
        if (font_dict.getArray("DescendantFonts")) |descendants| {
            if (descendants.len > 0) {
                const cid_font_obj = resolve_fn(resolve_ctx, descendants[0]);
                if (cid_font_obj == .dict) {
                    const cid_font = cid_font_obj.dict;

                    // Parse CIDSystemInfo
                    parseCIDSystemInfo(cid_font, resolve_fn, resolve_ctx, &encoding);

                    // Check CIDFont subtype for additional info
                    const cid_subtype = cid_font.getName("Subtype");
                    if (cid_subtype) |cst| {
                        if (std.mem.eql(u8, cst, "CIDFontType2")) {
                            // TrueType-based CID font - parse CIDToGIDMap
                            try parseCIDToGIDMap(allocator, cid_font, resolve_fn, resolve_ctx, &encoding);
                        }
                    }

                    // Check for ToUnicode in CIDFont (rare but possible)
                    if (encoding.cmap_ranges.len == 0 and encoding.cmap_hash.count() == 0) {
                        if (cid_font.get("ToUnicode")) |tounicode| {
                            const tu_resolved = resolve_fn(resolve_ctx, tounicode);
                            if (tu_resolved == .stream) {
                                try parseToUnicodeCMap(allocator, tu_resolved.stream, &encoding);
                                parsed_tounicode = true;
                            }
                        }
                    }
                }
            }
        }
    }

    // For non-Type0 fonts, check standard Encoding
    if (!is_type0) {
        if (font_dict.get("Encoding")) |enc| {
            const resolved = resolve_fn(resolve_ctx, enc);

            switch (resolved) {
                .name => |name| {
                    applyNamedEncoding(&encoding, name);
                },
                .dict => |dict| {
                    // Encoding dictionary with /BaseEncoding and /Differences
                    if (dict.getName("BaseEncoding")) |base| {
                        applyNamedEncoding(&encoding, base);
                    }

                    if (dict.getArray("Differences")) |diffs| {
                        try applyDifferences(&encoding, diffs);
                    }
                },
                else => {},
            }
        }

        // Check if it's a CID font type directly (rare without Type0 wrapper)
        if (subtype) |st| {
            if (std.mem.eql(u8, st, "CIDFontType0") or
                std.mem.eql(u8, st, "CIDFontType2"))
            {
                encoding.is_cid = true;
                encoding.bytes_per_char = 2;
            }
        }
    }

    // Check for ToUnicode CMap after the base encoding so explicit mappings
    // override /Encoding while preserving widths and metrics below.
    if (!parsed_tounicode) {
        if (font_dict.get("ToUnicode")) |tounicode| {
            const resolved = resolve_fn(resolve_ctx, tounicode);
            if (resolved == .stream) {
                try parseToUnicodeCMap(allocator, resolved.stream, &encoding);
                parsed_tounicode = true;
            }
        }
    }

    // Parse FontDescriptor for metrics
    try parseFontDescriptor(font_dict, resolve_fn, resolve_ctx, &encoding);
    if (is_type3) parseType3Metrics(font_dict, &encoding);

    // Parse glyph widths
    try parseWidths(allocator, font_dict, resolve_fn, resolve_ctx, &encoding);

    // For Type0 fonts, also check DescendantFonts for widths
    if (is_type0) {
        if (font_dict.getArray("DescendantFonts")) |descendants| {
            if (descendants.len > 0) {
                const cid_font_obj = resolve_fn(resolve_ctx, descendants[0]);
                if (cid_font_obj == .dict) {
                    try parseCIDWidths(allocator, cid_font_obj.dict, resolve_fn, resolve_ctx, &encoding);
                    try parseFontDescriptor(cid_font_obj.dict, resolve_fn, resolve_ctx, &encoding);
                }
            }
        }
    }

    encoding.has_to_unicode = parsed_tounicode;
    return encoding;
}

/// Parse FontDescriptor for font metrics
fn parseFontDescriptor(font_dict: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) !void {
    const fd_obj = font_dict.get("FontDescriptor") orelse return;
    const resolved = resolve_fn(resolve_ctx, fd_obj);
    if (resolved != .dict) return;

    const fd = resolved.dict;

    // Parse metrics
    if (fd.getNumber("Ascent")) |v| encoding.metrics.ascender = v;
    if (fd.getNumber("Descent")) |v| encoding.metrics.descender = v;
    if (fd.getNumber("CapHeight")) |v| encoding.metrics.cap_height = v;
    if (fd.getNumber("XHeight")) |v| encoding.metrics.x_height = v;
    if (fd.getNumber("ItalicAngle")) |v| encoding.metrics.italic_angle = v;
    if (fd.getNumber("MissingWidth")) |v| encoding.metrics.missing_width = v;

    // Parse FontBBox
    if (fd.getArray("FontBBox")) |bbox_arr| {
        if (bbox_arr.len >= 4) {
            for (0..4) |i| {
                if (getNumber(bbox_arr[i])) |v| {
                    encoding.metrics.bbox[i] = v;
                }
            }
        }
    }

    // Parse FontFile3 (CFF)
    if (fd.get("FontFile3")) |ff3_obj| {
        const resolved_ff3 = resolve_fn(resolve_ctx, ff3_obj);
        if (resolved_ff3 == .stream) {
            const stream = resolved_ff3.stream;
            const subtype = stream.dict.getName("Subtype");
            // Check if it's CFF (Type1C or CIDFontType0C)
            if (subtype) |st| {
                if (std.mem.eql(u8, st, "Type1C") or std.mem.eql(u8, st, "CIDFontType0C")) {
                    const data = decompress.decompressStream(
                        encoding.allocator,
                        stream.data,
                        stream.dict.get("Filter"),
                        stream.dict.get("DecodeParms"),
                    ) catch null;

                    if (data) |d| {
                        encoding.cff_data = d;
                        if (cff.CffParser.init(encoding.allocator, d)) |parser_inst| {
                            encoding.cff_parser = parser_inst;
                        } else |_| {
                            // If parsing fails, we still own the data so keep cff_data set to free it later
                            // but cff_parser remains null
                        }
                    }
                }
            }
        }
    }
}

fn parseType3Metrics(font_dict: Object.Dict, encoding: *FontEncoding) void {
    if (font_dict.getArray("FontBBox")) |bbox_arr| {
        if (bbox_arr.len >= 4) {
            for (0..4) |i| {
                if (getNumber(bbox_arr[i])) |v| {
                    encoding.metrics.bbox[i] = v;
                }
            }
            encoding.metrics.descender = encoding.metrics.bbox[1];
            encoding.metrics.ascender = encoding.metrics.bbox[3];
        }
    }

    if (font_dict.getArray("FontMatrix")) |matrix| {
        if (matrix.len >= 6) {
            // Most Type3 fonts use [0.001 0 0 0.001 0 0]. If a document uses
            // normalized 1-em glyph coordinates, keep bboxes useful by scaling
            // them into the same 1000-unit space as other PDF font metrics.
            const sx = getNumber(matrix[0]) orelse 0.001;
            const sy = getNumber(matrix[3]) orelse sx;
            if (@abs(sx) > 0 and @abs(sx) < 0.01 and @abs(sy) > 0 and @abs(sy) < 0.01) {
                const scale_y = 0.001 / @abs(sy);
                encoding.metrics.ascender *= scale_y;
                encoding.metrics.descender *= scale_y;
                encoding.metrics.bbox[1] *= scale_y;
                encoding.metrics.bbox[3] *= scale_y;
            }
        }
    }
}

/// Parse /Widths array for simple fonts
fn parseWidths(allocator: std.mem.Allocator, font_dict: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) !void {
    _ = allocator;
    _ = resolve_ctx;
    _ = resolve_fn;

    // Get FirstChar and LastChar
    const first_char: u16 = if (font_dict.getNumber("FirstChar")) |v|
        @intFromFloat(@max(0, @min(255, v)))
    else
        0;
    const last_char: u16 = if (font_dict.getNumber("LastChar")) |v|
        @intFromFloat(@max(0, @min(255, v)))
    else
        255;

    encoding.widths.first_char = first_char;
    encoding.widths.last_char = last_char;

    // Parse Widths array
    if (font_dict.getArray("Widths")) |widths_arr| {
        for (widths_arr, 0..) |w, i| {
            const char_code = first_char + @as(u16, @intCast(i));
            if (char_code > 255) break;

            if (getNumber(w)) |width| {
                encoding.widths.simple_widths[char_code] = width;
            }
        }
    }
}

fn applyBase14FallbackMetrics(encoding: *FontEncoding, base_font_raw: []const u8) void {
    const base_font = stripSubsetPrefix(base_font_raw);
    if (fontNameContains(base_font, "Courier")) {
        for (&encoding.widths.simple_widths) |*width| width.* = 600;
        encoding.widths.default_width = 600;
        encoding.metrics.ascender = 629;
        encoding.metrics.descender = -157;
        return;
    }

    if (fontNameContains(base_font, "Times")) {
        fillRepresentativeWidths(&encoding.widths.simple_widths, .times);
        encoding.widths.default_width = 500;
        encoding.metrics.ascender = 683;
        encoding.metrics.descender = -217;
        return;
    }

    if (fontNameContains(base_font, "Helvetica")) {
        fillRepresentativeWidths(&encoding.widths.simple_widths, .helvetica);
        encoding.widths.default_width = 556;
        encoding.metrics.ascender = 718;
        encoding.metrics.descender = -207;
        return;
    }

    if (fontNameContains(base_font, "Symbol")) {
        fillRepresentativeWidths(&encoding.widths.simple_widths, .symbol);
        encoding.widths.default_width = 600;
        encoding.metrics.ascender = 700;
        encoding.metrics.descender = -200;
        applySymbolEncoding(encoding);
        return;
    }

    if (fontNameContains(base_font, "ZapfDingbats")) {
        fillRepresentativeWidths(&encoding.widths.simple_widths, .zapf_dingbats);
        encoding.widths.default_width = 700;
        encoding.metrics.ascender = 820;
        encoding.metrics.descender = -143;
        applyZapfDingbatsEncoding(encoding);
    }
}

const Base14Kind = enum { helvetica, times, symbol, zapf_dingbats };

fn fillRepresentativeWidths(widths: *[256]f64, kind: Base14Kind) void {
    switch (kind) {
        .helvetica => {
            widths[' '] = 278;
            widths['i'] = 222;
            widths['l'] = 222;
            widths['m'] = 833;
            widths['w'] = 722;
            widths['A'] = 667;
            widths['M'] = 833;
            widths['W'] = 944;
            widths['0'] = 556;
            widths['1'] = 556;
            widths['.'] = 278;
            widths[','] = 278;
            widths['-'] = 333;
        },
        .times => {
            widths[' '] = 250;
            widths['i'] = 278;
            widths['l'] = 278;
            widths['m'] = 778;
            widths['w'] = 722;
            widths['A'] = 722;
            widths['M'] = 889;
            widths['W'] = 944;
            widths['0'] = 500;
            widths['1'] = 500;
            widths['.'] = 250;
            widths[','] = 250;
            widths['-'] = 333;
        },
        .symbol => {
            widths[' '] = 250;
            widths['A'] = 722;
            widths['B'] = 667;
            widths['a'] = 631;
            widths['b'] = 549;
            widths['p'] = 549;
            widths['m'] = 576;
        },
        .zapf_dingbats => {
            widths[' '] = 278;
            widths['!'] = 974;
            widths['"'] = 961;
            widths['#'] = 974;
            widths['('] = 789;
            widths[')'] = 790;
            widths['*'] = 788;
        },
    }
}

fn stripSubsetPrefix(name: []const u8) []const u8 {
    if (name.len > 7 and name[6] == '+') {
        var all_caps = true;
        for (name[0..6]) |c| {
            all_caps = all_caps and c >= 'A' and c <= 'Z';
        }
        if (all_caps) return name[7..];
    }
    return name;
}

fn fontNameContains(name: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, needle) != null;
}

fn applySymbolEncoding(encoding: *FontEncoding) void {
    for (&encoding.codepoint_map) |*cp| cp.* = 0;
    encoding.codepoint_map[' '] = ' ';
    encoding.codepoint_map['A'] = 0x0391;
    encoding.codepoint_map['B'] = 0x0392;
    encoding.codepoint_map['G'] = 0x0393;
    encoding.codepoint_map['D'] = 0x0394;
    encoding.codepoint_map['P'] = 0x03A0;
    encoding.codepoint_map['S'] = 0x03A3;
    encoding.codepoint_map['W'] = 0x03A9;
    encoding.codepoint_map['a'] = 0x03B1;
    encoding.codepoint_map['b'] = 0x03B2;
    encoding.codepoint_map['g'] = 0x03B3;
    encoding.codepoint_map['d'] = 0x03B4;
    encoding.codepoint_map['p'] = 0x03C0;
    encoding.codepoint_map['s'] = 0x03C3;
    encoding.codepoint_map['w'] = 0x03C9;
    encoding.codepoint_map['-'] = 0x2212;
    encoding.codepoint_map['='] = '=';
}

fn applyZapfDingbatsEncoding(encoding: *FontEncoding) void {
    for (&encoding.codepoint_map) |*cp| cp.* = 0;
    encoding.codepoint_map[' '] = ' ';
    encoding.codepoint_map['!'] = 0x2701;
    encoding.codepoint_map['"'] = 0x2702;
    encoding.codepoint_map['#'] = 0x2703;
    encoding.codepoint_map['('] = 0x260E;
    encoding.codepoint_map[')'] = 0x2706;
    encoding.codepoint_map['*'] = 0x261B;
    encoding.codepoint_map['4'] = 0x2714;
    encoding.codepoint_map['8'] = 0x2720;
}

/// Parse /W and /DW for CID fonts
fn parseCIDWidths(allocator: std.mem.Allocator, cid_font: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) !void {
    _ = resolve_ctx;
    _ = resolve_fn;

    // Default width
    if (cid_font.getNumber("DW")) |dw| {
        encoding.widths.default_width = dw;
    }

    // Width array /W
    const w_arr = cid_font.getArray("W") orelse return;

    var cid_widths: std.ArrayList(GlyphWidths.CIDWidthEntry) = .empty;
    errdefer cid_widths.deinit(allocator);

    var i: usize = 0;
    while (i < w_arr.len) {
        // Each entry is either:
        // c [w1 w2 w3 ...] - individual widths starting at CID c
        // c_first c_last w - range of CIDs with same width
        const first_obj = w_arr[i];
        const first_cid = getNumberU32(first_obj) orelse {
            i += 1;
            continue;
        };

        if (i + 1 >= w_arr.len) break;

        const second = w_arr[i + 1];
        switch (second) {
            .array => |arr| {
                // Individual widths
                for (arr, 0..) |w, j| {
                    if (getNumber(w)) |width| {
                        try cid_widths.append(allocator, .{
                            .cid_start = first_cid + @as(u32, @intCast(j)),
                            .cid_end = first_cid + @as(u32, @intCast(j)),
                            .width = width,
                        });
                    }
                }
                i += 2;
            },
            .integer, .real => {
                // Range: c_first c_last w
                if (i + 2 >= w_arr.len) break;
                const last_cid = getNumberU32(second) orelse {
                    i += 1;
                    continue;
                };
                const width = getNumber(w_arr[i + 2]) orelse {
                    i += 3;
                    continue;
                };
                try cid_widths.append(allocator, .{
                    .cid_start = first_cid,
                    .cid_end = last_cid,
                    .width = width,
                });
                i += 3;
            },
            else => {
                i += 1;
            },
        }
    }

    if (cid_widths.items.len > 0) {
        encoding.widths.cid_widths = try cid_widths.toOwnedSlice(allocator);
    }
}

/// Parse CIDSystemInfo from CIDFont dictionary
fn parseCIDSystemInfo(cid_font: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) void {
    const csi_obj = cid_font.get("CIDSystemInfo") orelse return;
    const resolved = resolve_fn(resolve_ctx, csi_obj);
    if (resolved != .dict) return;

    const csi = resolved.dict;

    if (csi.getString("Registry")) |registry| {
        encoding.cid_system_info.registry = registry;
    }
    if (csi.getString("Ordering")) |ordering| {
        encoding.cid_system_info.ordering = ordering;
    }
    if (csi.getNumber("Supplement")) |supplement| {
        encoding.cid_system_info.supplement = @intFromFloat(supplement);
    }
}

/// Parse CIDToGIDMap from CIDFont dictionary
fn parseCIDToGIDMap(allocator: std.mem.Allocator, cid_font: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) !void {
    const map_obj = cid_font.get("CIDToGIDMap") orelse return;
    const resolved = resolve_fn(resolve_ctx, map_obj);

    switch (resolved) {
        .name => |name| {
            if (std.mem.eql(u8, name, "Identity")) {
                encoding.cid_to_gid_map.mapping = .identity;
            }
        },
        .stream => |stream| {
            // Parse the stream - each entry is a 2-byte big-endian GID
            const data = decompress.decompressStream(
                allocator,
                stream.data,
                stream.dict.get("Filter"),
                stream.dict.get("DecodeParms"),
            ) catch return;

            // Convert to u16 array
            const num_entries = data.len / 2;
            const gid_map = try allocator.alloc(u16, num_entries);

            for (0..num_entries) |i| {
                gid_map[i] = (@as(u16, data[i * 2]) << 8) | data[i * 2 + 1];
            }

            allocator.free(data);
            encoding.cid_to_gid_map.mapping = .{ .stream_map = gid_map };
        },
        else => {},
    }
}

fn getNumber(obj: Object) ?f64 {
    return switch (obj) {
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        else => null,
    };
}

fn getNumberU32(obj: Object) ?u32 {
    return switch (obj) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .real => |r| if (r >= 0) @intFromFloat(r) else null,
        else => null,
    };
}

/// Apply predefined CMap encoding for CID fonts
fn applyPredefinedCMap(encoding: *FontEncoding, name: []const u8) void {
    // Detect vertical writing mode from CMap name suffix
    // Names ending in "-V" indicate vertical writing (WMode=1)
    if (name.len >= 2 and name[name.len - 2] == '-' and name[name.len - 1] == 'V') {
        encoding.wmode = 1;
    }

    // Identity CMaps - CID = Unicode (common for CJK fonts with ToUnicode)
    if (std.mem.eql(u8, name, "Identity-H") or std.mem.eql(u8, name, "Identity-V")) {
        // Identity mapping: the character codes are CIDs
        // Actual Unicode comes from ToUnicode CMap
        encoding.bytes_per_char = 2;
        return;
    }

    if (std.mem.indexOf(u8, name, "Adobe-Japan1") != null or
        std.mem.indexOf(u8, name, "Adobe-GB1") != null or
        std.mem.indexOf(u8, name, "Adobe-CNS1") != null or
        std.mem.indexOf(u8, name, "Adobe-Korea1") != null)
    {
        encoding.bytes_per_char = 2;
        return;
    }

    // Horizontal variants (commonly used)
    if (std.mem.eql(u8, name, "UniGB-UCS2-H") or
        std.mem.eql(u8, name, "UniCNS-UCS2-H") or
        std.mem.eql(u8, name, "UniJIS-UCS2-H") or
        std.mem.eql(u8, name, "UniKS-UCS2-H") or
        std.mem.eql(u8, name, "GB-EUC-H") or
        std.mem.eql(u8, name, "GBK-EUC-H") or
        std.mem.eql(u8, name, "CNS-EUC-H") or
        std.mem.eql(u8, name, "ETen-B5-H") or
        std.mem.eql(u8, name, "UniJIS-UTF8-H") or
        std.mem.eql(u8, name, "KSC-EUC-H"))
    {
        // These map CID directly to Unicode - identity-like
        encoding.bytes_per_char = 2;
        return;
    }

    // Vertical variants
    if (std.mem.eql(u8, name, "UniGB-UCS2-V") or
        std.mem.eql(u8, name, "UniCNS-UCS2-V") or
        std.mem.eql(u8, name, "UniJIS-UCS2-V") or
        std.mem.eql(u8, name, "UniKS-UCS2-V") or
        std.mem.eql(u8, name, "GB-EUC-V") or
        std.mem.eql(u8, name, "GBK-EUC-V") or
        std.mem.eql(u8, name, "CNS-EUC-V") or
        std.mem.eql(u8, name, "ETen-B5-V") or
        std.mem.eql(u8, name, "UniJIS-UTF8-V") or
        std.mem.eql(u8, name, "KSC-EUC-V"))
    {
        encoding.bytes_per_char = 2;
        return;
    }

    // UTF-16 variants (horizontal and vertical)
    if (std.mem.eql(u8, name, "UniGB-UTF16-H") or
        std.mem.eql(u8, name, "UniCNS-UTF16-H") or
        std.mem.eql(u8, name, "UniJIS-UTF16-H") or
        std.mem.eql(u8, name, "UniKS-UTF16-H") or
        std.mem.eql(u8, name, "UniGB-UTF16-V") or
        std.mem.eql(u8, name, "UniCNS-UTF16-V") or
        std.mem.eql(u8, name, "UniJIS-UTF16-V") or
        std.mem.eql(u8, name, "UniKS-UTF16-V"))
    {
        encoding.bytes_per_char = 2;
        return;
    }

    // Default for unknown predefined CMaps - assume 2-byte
    encoding.bytes_per_char = 2;
}

pub fn applyNamedEncoding(encoding: *FontEncoding, name: []const u8) void {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) {
        encoding.codepoint_map = win_ansi_encoding;
    } else if (std.mem.eql(u8, name, "MacRomanEncoding")) {
        encoding.codepoint_map = mac_roman_encoding;
    } else if (std.mem.eql(u8, name, "StandardEncoding")) {
        encoding.codepoint_map = standard_encoding;
    } else if (std.mem.eql(u8, name, "PDFDocEncoding")) {
        encoding.codepoint_map = pdf_doc_encoding;
    }
    // MacExpertEncoding omitted - rarely used
}

pub fn applyDifferences(encoding: *FontEncoding, diffs: []Object) !void {
    var code: u16 = 0;

    for (diffs) |item| {
        switch (item) {
            .integer => |i| {
                code = @intCast(@max(0, @min(255, i)));
            },
            .name => |name| {
                if (code < 256) {
                    encoding.codepoint_map[code] = glyphNameToUnicode(name);
                    code += 1;
                }
            },
            else => {},
        }
    }
}

/// Parse ToUnicode CMap stream
pub fn parseToUnicodeCMap(allocator: std.mem.Allocator, stream: Object.Stream, encoding: *FontEncoding) !void {
    // Decompress stream
    const data = decompress.decompressStream(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
    ) catch return;
    defer allocator.free(data);

    var ranges: std.ArrayList(FontEncoding.CMapRange) = .empty;
    errdefer ranges.deinit(allocator);
    var code_spaces: std.ArrayList(FontEncoding.CMapCodeSpace) = .empty;
    errdefer code_spaces.deinit(allocator);

    var pos: usize = 0;
    var max_source_bytes: u8 = if (encoding.is_cid) encoding.bytes_per_char else 1;

    while (pos < data.len) {
        // Skip whitespace and comments
        while (pos < data.len and (isWhitespace(data[pos]) or data[pos] == '%')) {
            if (data[pos] == '%') {
                while (pos < data.len and data[pos] != '\n') pos += 1;
            } else {
                pos += 1;
            }
        }

        if (pos >= data.len) break;

        // Look for WMode definition: /WMode 1 def
        if (matchAt(data, pos, "/WMode")) {
            pos += 6;
            skipWhitespace(data, &pos);
            if (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
                encoding.wmode = data[pos] - '0';
            }
            pos += 1;
            continue;
        }

        // Look for code spaces and mappings.
        if (matchAt(data, pos, "begincodespacerange")) {
            pos += 19;
            try parseCodeSpaceRange(allocator, data, &pos, &max_source_bytes, &code_spaces);
        } else if (matchAt(data, pos, "beginbfchar")) {
            pos += 11;
            try parseBfChar(allocator, data, &pos, &ranges, encoding, &max_source_bytes);
        } else if (matchAt(data, pos, "beginbfrange")) {
            pos += 12;
            try parseBfRange(allocator, data, &pos, &ranges, encoding, &max_source_bytes);
        } else {
            pos += 1;
        }
    }

    // Sort ranges by src_start for binary search
    const owned_ranges = try ranges.toOwnedSlice(allocator);
    std.mem.sort(FontEncoding.CMapRange, owned_ranges, {}, struct {
        fn lessThan(_: void, a: FontEncoding.CMapRange, b: FontEncoding.CMapRange) bool {
            return a.src_start < b.src_start;
        }
    }.lessThan);
    encoding.cmap_ranges = owned_ranges;

    const owned_code_spaces = try code_spaces.toOwnedSlice(allocator);
    std.mem.sort(FontEncoding.CMapCodeSpace, owned_code_spaces, {}, struct {
        fn lessThan(_: void, a: FontEncoding.CMapCodeSpace, b: FontEncoding.CMapCodeSpace) bool {
            if (a.byte_count != b.byte_count) return a.byte_count < b.byte_count;
            return a.low < b.low;
        }
    }.lessThan);
    encoding.cmap_codespaces = owned_code_spaces;

    if (encoding.is_cid or max_source_bytes > 1) {
        encoding.is_cid = true;
        encoding.bytes_per_char = @max(encoding.bytes_per_char, max_source_bytes);
    }
}

fn parseCodeSpaceRange(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    max_source_bytes: *u8,
    code_spaces: *std.ArrayList(FontEncoding.CMapCodeSpace),
) !void {
    while (pos.* < data.len) {
        skipWhitespace(data, pos);

        if (matchAt(data, pos.*, "endcodespacerange")) {
            pos.* += 17;
            return;
        }

        const low = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        skipWhitespace(data, pos);
        const high = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };

        max_source_bytes.* = @max(max_source_bytes.*, low.byte_count);
        max_source_bytes.* = @max(max_source_bytes.*, high.byte_count);
        if (low.byte_count == high.byte_count) {
            try code_spaces.append(allocator, .{
                .low = low.value,
                .high = high.value,
                .byte_count = low.byte_count,
            });
        }
    }
}

fn parseBfChar(allocator: std.mem.Allocator, data: []const u8, pos: *usize, _: *std.ArrayList(FontEncoding.CMapRange), encoding: *FontEncoding, max_source_bytes: *u8) !void {
    while (pos.* < data.len) {
        skipWhitespace(data, pos);

        if (matchAt(data, pos.*, "endbfchar")) {
            pos.* += 9;
            return;
        }

        // Parse source code: <XXXX>
        const src = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        max_source_bytes.* = @max(max_source_bytes.*, src.byte_count);

        skipWhitespace(data, pos);

        // Parse destination: <XXXX> (Unicode) - can be multi-byte for ligatures
        var dst_buf: [16]u8 = undefined;
        const dst_result = parseHexTokenRaw(data, pos, &dst_buf) orelse {
            skipToNextEntry(data, pos);
            continue;
        };

        // Check if this is a multi-character mapping (> 2 bytes = multiple UTF-16BE code units)
        if (dst_result.byte_count > 2) {
            // Multi-character mapping (ligatures like fi, fl, ffi, ffl)
            // Convert UTF-16BE to UTF-8 and store in cmap_multi
            const utf8_str = utf16beToUtf8(allocator, dst_buf[0..dst_result.byte_count]) catch continue;
            try encoding.cmap_multi.put(allocator, src.value, utf8_str);
        } else {
            // Single character mapping
            var dst: u32 = 0;
            for (dst_buf[0..dst_result.byte_count]) |b| {
                dst = (dst << 8) | b;
            }

            // For simple 1-byte codes, update the direct map
            if (src.value <= 255 and dst <= 0x10FFFF) {
                encoding.codepoint_map[@intCast(src.value)] = @intCast(dst);
            }

            // Add to hash map for O(1) lookup
            try encoding.cmap_hash.put(allocator, src.value, dst);
        }
    }
}

fn parseBfRange(allocator: std.mem.Allocator, data: []const u8, pos: *usize, ranges: *std.ArrayList(FontEncoding.CMapRange), encoding: *FontEncoding, max_source_bytes: *u8) !void {
    while (pos.* < data.len) {
        skipWhitespace(data, pos);

        if (matchAt(data, pos.*, "endbfrange")) {
            pos.* += 10;
            return;
        }

        // Parse: <start> <end> <dst_start> or <start> <end> [array]
        const src_start = parseHexTokenDetailed(data, pos) orelse {
            // Can't parse - skip to next line or next '<'
            skipToNextEntry(data, pos);
            continue;
        };
        max_source_bytes.* = @max(max_source_bytes.*, src_start.byte_count);
        skipWhitespace(data, pos);
        const src_end = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        max_source_bytes.* = @max(max_source_bytes.*, src_end.byte_count);
        skipWhitespace(data, pos);

        // Destination can be a hex value or an array
        if (pos.* < data.len and data[pos.*] == '<') {
            const dst_start = parseHexToken(data, pos) orelse {
                skipToNextEntry(data, pos);
                continue;
            };
            try ranges.append(allocator, .{
                .src_start = src_start.value,
                .src_end = src_end.value,
                .dst_start = dst_start,
                .is_range = true,
            });
        } else if (pos.* < data.len and data[pos.*] == '[') {
            // Array of mappings - add to hash map for O(1) lookup
            pos.* += 1;
            var src = src_start.value;
            while (src <= src_end.value and pos.* < data.len) {
                skipWhitespace(data, pos);
                if (pos.* < data.len and data[pos.*] == ']') {
                    pos.* += 1;
                    break;
                }
                var dst_buf: [16]u8 = undefined;
                const dst_result = parseHexTokenRaw(data, pos, &dst_buf) orelse break;
                if (dst_result.byte_count > 2) {
                    const utf8_str = utf16beToUtf8(allocator, dst_buf[0..dst_result.byte_count]) catch {
                        src += 1;
                        continue;
                    };
                    try encoding.cmap_multi.put(allocator, src, utf8_str);
                } else {
                    var dst: u32 = 0;
                    for (dst_buf[0..dst_result.byte_count]) |b| {
                        dst = (dst << 8) | b;
                    }
                    if (src <= 255 and dst <= 0x10FFFF) {
                        encoding.codepoint_map[@intCast(src)] = @intCast(dst);
                    }
                    try encoding.cmap_hash.put(allocator, src, dst);
                }
                src += 1;
            }
        } else {
            // Unknown format - skip to next entry
            skipToNextEntry(data, pos);
        }
    }
}

fn parseHexToken(data: []const u8, pos: *usize) ?u32 {
    const token = parseHexTokenDetailed(data, pos) orelse return null;
    return token.value;
}

fn parseHexTokenDetailed(data: []const u8, pos: *usize) ?struct { value: u32, byte_count: u8 } {
    if (pos.* >= data.len or data[pos.*] != '<') return null;
    pos.* += 1;

    var value: u32 = 0;
    var nibble_count: u16 = 0;

    while (pos.* < data.len and data[pos.*] != '>') {
        const c = data[pos.*];
        pos.* += 1;

        const nibble: u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            continue;

        value = (value << 4) | nibble;
        nibble_count += 1;
    }

    if (pos.* < data.len and data[pos.*] == '>') {
        pos.* += 1;
    }

    return .{
        .value = value,
        .byte_count = @intCast(@max(@as(u16, 1), (nibble_count + 1) / 2)),
    };
}

fn readCodeBE(data: []const u8) u32 {
    var value: u32 = 0;
    for (data) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

/// Parse a hex token and return the raw bytes plus the byte count
/// Returns null if no valid hex token found
fn parseHexTokenRaw(data: []const u8, pos: *usize, out_buf: *[16]u8) ?struct { byte_count: usize } {
    if (pos.* >= data.len or data[pos.*] != '<') return null;
    pos.* += 1;

    var byte_count: usize = 0;
    var nibble_count: usize = 0;
    var current_byte: u8 = 0;

    while (pos.* < data.len and data[pos.*] != '>') {
        const c = data[pos.*];
        pos.* += 1;

        const nibble: u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            continue;

        if (nibble_count % 2 == 0) {
            current_byte = @as(u8, nibble) << 4;
        } else {
            current_byte |= nibble;
            if (byte_count < out_buf.len) {
                out_buf[byte_count] = current_byte;
                byte_count += 1;
            }
        }
        nibble_count += 1;
    }

    // Handle odd nibble count (implicit trailing 0)
    if (nibble_count % 2 == 1 and byte_count < out_buf.len) {
        out_buf[byte_count] = current_byte;
        byte_count += 1;
    }

    if (pos.* < data.len and data[pos.*] == '>') {
        pos.* += 1;
    }

    return .{ .byte_count = byte_count };
}

/// Decode UTF-16BE bytes to UTF-8
fn utf16beToUtf8(allocator: std.mem.Allocator, utf16_bytes: []const u8) ![]u8 {
    var utf8_list: std.ArrayList(u8) = .empty;
    errdefer utf8_list.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < utf16_bytes.len) {
        const code_unit: u16 = (@as(u16, utf16_bytes[i]) << 8) | utf16_bytes[i + 1];
        i += 2;

        var codepoint: u21 = undefined;

        // Check for surrogate pairs
        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            // High surrogate - read low surrogate
            if (i + 1 < utf16_bytes.len) {
                const low: u16 = (@as(u16, utf16_bytes[i]) << 8) | utf16_bytes[i + 1];
                if (low >= 0xDC00 and low <= 0xDFFF) {
                    codepoint = 0x10000 + (@as(u21, code_unit - 0xD800) << 10) + (low - 0xDC00);
                    i += 2;
                } else {
                    codepoint = 0xFFFD; // Replacement character
                }
            } else {
                codepoint = 0xFFFD;
            }
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            // Orphan low surrogate
            codepoint = 0xFFFD;
        } else {
            codepoint = code_unit;
        }

        // Encode to UTF-8
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
        try utf8_list.appendSlice(allocator, buf[0..len]);
    }

    return utf8_list.toOwnedSlice(allocator);
}

fn skipWhitespace(data: []const u8, pos: *usize) void {
    while (pos.* < data.len and isWhitespace(data[pos.*])) {
        pos.* += 1;
    }
}

/// Skip to next valid entry (newline or '<') when parsing fails
fn skipToNextEntry(data: []const u8, pos: *usize) void {
    while (pos.* < data.len) {
        const c = data[pos.*];
        // Stop at newline or start of hex token
        if (c == '\n' or c == '\r' or c == '<') return;
        // Also stop if we hit "end" keyword
        if (matchAt(data, pos.*, "end")) return;
        pos.* += 1;
    }
}

fn matchAt(data: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > data.len) return false;
    return std.mem.eql(u8, data[pos..][0..needle.len], needle);
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

/// Map glyph name to Unicode (common subset)
fn glyphNameToUnicode(name: []const u8) u21 {
    if (agl.glyphNameToUnicode(name)) |u| {
        return u;
    }
    return 0;
}

// ============================================================================
// STANDARD ENCODING TABLES
// ============================================================================

pub const win_ansi_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Windows-1252 extensions
    table[128] = 0x20AC; // Euro sign
    table[129] = 0;
    table[130] = 0x201A; // Single low-9 quotation mark
    table[131] = 0x0192; // Latin small letter f with hook
    table[132] = 0x201E; // Double low-9 quotation mark
    table[133] = 0x2026; // Horizontal ellipsis
    table[134] = 0x2020; // Dagger
    table[135] = 0x2021; // Double dagger
    table[136] = 0x02C6; // Modifier letter circumflex accent
    table[137] = 0x2030; // Per mille sign
    table[138] = 0x0160; // Latin capital letter S with caron
    table[139] = 0x2039; // Single left-pointing angle quotation mark
    table[140] = 0x0152; // Latin capital ligature OE
    table[141] = 0;
    table[142] = 0x017D; // Latin capital letter Z with caron
    table[143] = 0;
    table[144] = 0;
    table[145] = 0x2018; // Left single quotation mark
    table[146] = 0x2019; // Right single quotation mark
    table[147] = 0x201C; // Left double quotation mark
    table[148] = 0x201D; // Right double quotation mark
    table[149] = 0x2022; // Bullet
    table[150] = 0x2013; // En dash
    table[151] = 0x2014; // Em dash
    table[152] = 0x02DC; // Small tilde
    table[153] = 0x2122; // Trade mark sign
    table[154] = 0x0161; // Latin small letter s with caron
    table[155] = 0x203A; // Single right-pointing angle quotation mark
    table[156] = 0x0153; // Latin small ligature oe
    table[157] = 0;
    table[158] = 0x017E; // Latin small letter z with caron
    table[159] = 0x0178; // Latin capital letter Y with diaeresis

    // Latin-1 Supplement (160-255)
    for (160..256) |i| {
        table[i] = @intCast(i);
    }

    break :blk table;
};

const mac_roman_encoding = blk: {
    var table: [256]u21 = undefined;

    // ASCII range
    for (0..128) |i| {
        table[i] = @intCast(i);
    }

    // Mac Roman extensions (128-255)
    const mac_ext = [_]u21{
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    };

    for (0..128) |i| {
        table[128 + i] = mac_ext[i];
    }

    break :blk table;
};

const standard_encoding = blk: {
    var table: [256]u21 = undefined;

    // Initialize all to 0
    for (&table) |*t| {
        t.* = 0;
    }

    // ASCII letters and digits
    for ('A'..('Z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('a'..('z' + 1)) |i| {
        table[i] = @intCast(i);
    }
    for ('0'..('9' + 1)) |i| {
        table[i] = @intCast(i);
    }

    // Common punctuation
    table[' '] = ' ';
    table['!'] = '!';
    table['"'] = '"';
    table['#'] = '#';
    table['$'] = '$';
    table['%'] = '%';
    table['&'] = '&';
    table['\''] = 0x2019; // quoteright
    table['('] = '(';
    table[')'] = ')';
    table['*'] = '*';
    table['+'] = '+';
    table[','] = ',';
    table['-'] = '-';
    table['.'] = '.';
    table['/'] = '/';
    table[':'] = ':';
    table[';'] = ';';
    table['<'] = '<';
    table['='] = '=';
    table['>'] = '>';
    table['?'] = '?';
    table['@'] = '@';
    table['['] = '[';
    table['\\'] = '\\';
    table[']'] = ']';
    table['^'] = '^';
    table['_'] = '_';
    table['`'] = 0x2018; // quoteleft
    table['{'] = '{';
    table['|'] = '|';
    table['}'] = '}';
    table['~'] = '~';

    break :blk table;
};

const pdf_doc_encoding = blk: {
    var table: [256]u21 = undefined;

    // Start with WinAnsi
    table = win_ansi_encoding;

    // PDFDocEncoding differs in a few places
    table[0x18] = 0x02D8; // breve
    table[0x19] = 0x02C7; // caron
    table[0x1A] = 0x02C6; // circumflex
    table[0x1B] = 0x02D9; // dotaccent
    table[0x1C] = 0x02DD; // hungarumlaut
    table[0x1D] = 0x02DB; // ogonek
    table[0x1E] = 0x02DA; // ring
    table[0x1F] = 0x02DC; // tilde

    break :blk table;
};

// ============================================================================
// TESTS
// ============================================================================

test "WinAnsi decode ASCII" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode("Hello", runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("Hello", output.items);
}

test "WinAnsi decode extended" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // 0x93 = left double quote, 0x94 = right double quote
    try enc.decode(&[_]u8{ 0x93, 'H', 'i', 0x94 }, runtime.arrayListWriter(&output, std.testing.allocator));

    // Should be "Hi" with smart quotes
    try std.testing.expectEqualStrings("\xe2\x80\x9cHi\xe2\x80\x9d", output.items);
}

test "glyph name to unicode" {
    try std.testing.expectEqual(@as(u21, 'A'), glyphNameToUnicode("A"));
    try std.testing.expectEqual(@as(u21, 0x2022), glyphNameToUnicode("bullet"));
    try std.testing.expectEqual(@as(u21, 0xFB01), glyphNameToUnicode("fi"));
    try std.testing.expectEqual(@as(u21, 0x0041), glyphNameToUnicode("uni0041"));
}

test "CID font decode UTF-16BE" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // UTF-16BE for "A" (0x0041)
    try enc.decode(&[_]u8{ 0x00, 0x41 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("A", output.items);
}

test "CID font decode CJK character" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // UTF-16BE for Chinese character "中" (U+4E2D)
    try enc.decode(&[_]u8{ 0x4E, 0x2D }, runtime.arrayListWriter(&output, std.testing.allocator));
    // Should output UTF-8 encoding of U+4E2D = 0xE4 0xB8 0xAD
    try std.testing.expectEqualStrings("中", output.items);
}

test "CID font with CMap ranges" {
    var enc = FontEncoding.init(std.testing.allocator);

    // Add a CMap range mapping 0x0001-0x0003 to 'A'-'C'
    const ranges = try std.testing.allocator.alloc(FontEncoding.CMapRange, 1);
    ranges[0] = .{
        .src_start = 0x0001,
        .src_end = 0x0003,
        .dst_start = 'A',
        .is_range = true,
    };
    enc.cmap_ranges = ranges;
    enc.is_cid = true;
    enc.bytes_per_char = 2;

    defer enc.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // Character code 0x0002 should map to 'B'
    try enc.decode(&[_]u8{ 0x00, 0x02 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("B", output.items);
}

test "CID font decode surrogate pairs" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // UTF-16BE surrogate pair for U+1F600 (😀)
    // High surrogate: 0xD83D, Low surrogate: 0xDE00
    try enc.decode(&[_]u8{ 0xD8, 0x3D, 0xDE, 0x00 }, runtime.arrayListWriter(&output, std.testing.allocator));
    // Should output UTF-8 encoding of U+1F600 = 0xF0 0x9F 0x98 0x80
    try std.testing.expectEqualStrings("😀", output.items);
}

test "MacRoman encoding" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    // Apply MacRoman encoding
    applyNamedEncoding(&enc, "MacRomanEncoding");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // 0xCA in MacRoman is a non-breaking space
    try enc.decode(&[_]u8{0xCA}, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 2), output.items.len); // UTF-8 NBSP is 2 bytes
}

test "encoding differences array" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    // Simulate a /Differences array that maps code 65 to 'B' instead of 'A'
    enc.codepoint_map[65] = 'B';

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{65}, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("B", output.items);
}

test "CID identity mapping" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;
    // No CMap ranges - should use identity mapping (UTF-16BE)

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // 0x0041 = 'A' in Unicode
    try enc.decode(&[_]u8{ 0x00, 0x41 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("A", output.items);
}

test "CMap range mapping" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;

    // Add a range: codes 0x0100-0x0102 map to 'X', 'Y', 'Z'
    var ranges: std.ArrayList(FontEncoding.CMapRange) = .empty;
    try ranges.append(std.testing.allocator, .{ .src_start = 0x0100, .src_end = 0x0102, .dst_start = 'X', .is_range = true });
    enc.cmap_ranges = try ranges.toOwnedSlice(std.testing.allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{ 0x01, 0x00 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("X", output.items);

    output.clearRetainingCapacity();
    try enc.decode(&[_]u8{ 0x01, 0x01 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("Y", output.items);

    output.clearRetainingCapacity();
    try enc.decode(&[_]u8{ 0x01, 0x02 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("Z", output.items);
}

test "ToUnicode simple font preserves widths and stays one-byte" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<00> <FF>
        \\endcodespacerange
        \\1 beginbfchar
        \\<41> <03A9>
        \\endbfchar
        \\endcmap
        \\end
        \\end
    ;

    var widths = [_]Object{.{ .integer = 777 }};
    var entries = [_]Object.Dict.Entry{
        .{ .key = "Subtype", .value = .{ .name = "Type1" } },
        .{ .key = "Encoding", .value = .{ .name = "WinAnsiEncoding" } },
        .{ .key = "FirstChar", .value = .{ .integer = 65 } },
        .{ .key = "LastChar", .value = .{ .integer = 65 } },
        .{ .key = "Widths", .value = .{ .array = &widths } },
        .{
            .key = "ToUnicode",
            .value = .{ .stream = .{
                .dict = .{ .entries = &.{} },
                .data = cmap,
            } },
        },
    };

    const dummy_ctx: u8 = 0;
    var enc = try parseFontEncoding(
        std.testing.allocator,
        .{ .entries = &entries },
        struct {
            fn resolve(_: *const anyopaque, obj: Object) Object {
                return obj;
            }
        }.resolve,
        &dummy_ctx,
    );
    defer enc.deinit();

    try std.testing.expect(!enc.is_cid);
    try std.testing.expectEqual(@as(u8, 1), enc.bytes_per_char);
    try std.testing.expectEqual(@as(f64, 777), enc.widths.getWidth(65));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{'A'}, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("Ω", output.items);
}

test "ToUnicode two-byte codespace promotes CID decoding" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\1 beginbfchar
        \\<0041> <0042>
        \\endbfchar
        \\endcmap
        \\end
        \\end
    ;

    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    try parseToUnicodeCMap(std.testing.allocator, .{
        .dict = .{ .entries = &.{} },
        .data = cmap,
    }, &enc);

    try std.testing.expect(enc.is_cid);
    try std.testing.expectEqual(@as(u8, 2), enc.bytes_per_char);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{ 0x00, 0x41 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("B", output.items);
}

test "ToUnicode mixed code spaces decode variable-width CID codes" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\2 begincodespacerange
        \\<00> <7F>
        \\<8100> <81FF>
        \\endcodespacerange
        \\2 beginbfchar
        \\<41> <0041>
        \\<8101> <03A9>
        \\endbfchar
        \\endcmap
        \\end
        \\end
    ;

    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    try parseToUnicodeCMap(std.testing.allocator, .{
        .dict = .{ .entries = &.{} },
        .data = cmap,
    }, &enc);

    try std.testing.expect(enc.is_cid);
    try std.testing.expectEqual(@as(u8, 2), enc.bytes_per_char);
    try std.testing.expectEqual(@as(usize, 2), enc.cmap_codespaces.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{ 0x41, 0x81, 0x01 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("AΩ", output.items);
}

test "ToUnicode bfrange arrays map explicit and multi-codepoint destinations" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\2 beginbfrange
        \\<0100> <0102> [<0058> <0059> <005A>]
        \\<0200> <0200> [<00660069>]
        \\endbfrange
        \\endcmap
        \\end
        \\end
    ;

    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    try parseToUnicodeCMap(std.testing.allocator, .{
        .dict = .{ .entries = &.{} },
        .data = cmap,
    }, &enc);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(
        &[_]u8{ 0x01, 0x00, 0x01, 0x01, 0x01, 0x02, 0x02, 0x00 },
        runtime.arrayListWriter(&output, std.testing.allocator),
    );
    try std.testing.expectEqualStrings("XYZfi", output.items);
}

test "glyph widths" {
    var widths = GlyphWidths.init(std.testing.allocator);
    defer widths.deinit();

    widths.first_char = 32;
    widths.last_char = 127;
    widths.simple_widths[65] = 750; // 'A'
    widths.simple_widths[32] = 250; // space

    try std.testing.expectEqual(@as(f64, 750), widths.getWidth(65));
    try std.testing.expectEqual(@as(f64, 250), widths.getWidth(32));
}

test "decode records expose simple glyph widths and unicode map errors" {
    const allocator = std.testing.allocator;
    var enc = FontEncoding.init(allocator);
    defer enc.deinit();
    enc.widths.simple_widths['A'] = 750;
    enc.codepoint_map[0] = 0;

    var sink = struct {
        count: usize = 0,
        text: std.ArrayList(u8) = .empty,
        first_width: f64 = 0,
        saw_map_error: bool = false,

        fn writeDecodedGlyph(self: *@This(), glyph: FontEncoding.DecodedGlyph) !void {
            if (self.count == 0) self.first_width = glyph.glyph_width;
            self.saw_map_error = self.saw_map_error or glyph.unicode_map_error;
            self.count += 1;
            try self.text.appendSlice(std.testing.allocator, glyph.utf8_text);
        }
    }{};
    defer sink.text.deinit(allocator);

    try enc.decodeRecords(&[_]u8{ 'A', 0 }, &sink);

    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(@as(f64, 750), sink.first_width);
    try std.testing.expect(sink.saw_map_error);
    try std.testing.expectEqualStrings("A ", sink.text.items);
}

test "decode records preserve ligature and CID metadata" {
    const allocator = std.testing.allocator;
    var enc = FontEncoding.init(allocator);
    defer enc.deinit();
    const ligature = try allocator.dupe(u8, "fi");
    try enc.cmap_multi.put(allocator, 'f', ligature);

    var simple_sink = struct {
        count: usize = 0,
        multi: bool = false,
        text: std.ArrayList(u8) = .empty,

        fn writeDecodedGlyph(self: *@This(), glyph: FontEncoding.DecodedGlyph) !void {
            self.count += 1;
            self.multi = self.multi or glyph.multi_char_mapping;
            try self.text.appendSlice(std.testing.allocator, glyph.utf8_text);
        }
    }{};
    defer simple_sink.text.deinit(allocator);
    try enc.decodeRecords(&[_]u8{'f'}, &simple_sink);
    try std.testing.expectEqual(@as(usize, 1), simple_sink.count);
    try std.testing.expect(simple_sink.multi);
    try std.testing.expectEqualStrings("fi", simple_sink.text.items);

    var cid = FontEncoding.init(allocator);
    defer cid.deinit();
    cid.is_cid = true;
    cid.bytes_per_char = 2;
    cid.wmode = 1;
    try cid.cmap_hash.put(allocator, 0x0041, 'A');
    cid.widths.default_width = 880;

    var cid_sink = struct {
        text: std.ArrayList(u8) = .empty,
        width: f64 = 0,
        cid_value: ?u32 = null,
        writing_mode: u8 = 0,

        fn writeDecodedGlyph(self: *@This(), glyph: FontEncoding.DecodedGlyph) !void {
            self.width = glyph.glyph_width;
            self.cid_value = glyph.cid_or_gid;
            self.writing_mode = glyph.writing_mode;
            try self.text.appendSlice(std.testing.allocator, glyph.utf8_text);
        }
    }{};
    defer cid_sink.text.deinit(allocator);

    try cid.decodeRecords(&[_]u8{ 0x00, 0x41 }, &cid_sink);
    try std.testing.expectEqualStrings("A", cid_sink.text.items);
    try std.testing.expectEqual(@as(f64, 880), cid_sink.width);
    try std.testing.expectEqual(@as(?u32, 0x0041), cid_sink.cid_value);
    try std.testing.expectEqual(@as(u8, 1), cid_sink.writing_mode);
}

test "font metrics defaults" {
    const metrics = FontMetrics{};
    try std.testing.expectEqual(@as(f64, 800), metrics.ascender);
    try std.testing.expectEqual(@as(f64, -200), metrics.descender);
    try std.testing.expectEqual(@as(f64, 700), metrics.cap_height);
}

fn resolveEncodingTestObject(_: *const anyopaque, obj: Object) Object {
    return obj;
}

test "Type3 font honors widths font bbox and ToUnicode" {
    const allocator = std.testing.allocator;
    const widths = [_]Object{ .{ .integer = 400 }, .{ .integer = 700 } };
    const bbox = [_]Object{ .{ .integer = 0 }, .{ .integer = -120 }, .{ .integer = 900 }, .{ .integer = 760 } };
    const matrix = [_]Object{ .{ .real = 0.001 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .real = 0.001 }, .{ .integer = 0 }, .{ .integer = 0 } };
    const entries = [_]Object.Dict.Entry{
        .{ .key = "Subtype", .value = .{ .name = "Type3" } },
        .{ .key = "FirstChar", .value = .{ .integer = 65 } },
        .{ .key = "LastChar", .value = .{ .integer = 66 } },
        .{ .key = "Widths", .value = .{ .array = @constCast(widths[0..]) } },
        .{ .key = "FontBBox", .value = .{ .array = @constCast(bbox[0..]) } },
        .{ .key = "FontMatrix", .value = .{ .array = @constCast(matrix[0..]) } },
    };
    var enc = try parseFontEncoding(allocator, .{ .entries = @constCast(entries[0..]) }, resolveEncodingTestObject, undefined);
    defer enc.deinit();

    try std.testing.expect(enc.is_type3);
    try std.testing.expectEqual(@as(f64, 400), enc.widths.getWidth('A'));
    try std.testing.expectEqual(@as(f64, 700), enc.widths.getWidth('B'));
    try std.testing.expectEqual(@as(f64, -120), enc.metrics.descender);
    try std.testing.expectEqual(@as(f64, 760), enc.metrics.ascender);
}

test "Base14 fallback metrics and symbolic encodings" {
    var helvetica = FontEncoding.init(std.testing.allocator);
    defer helvetica.deinit();
    applyBase14FallbackMetrics(&helvetica, "ABCDEE+Helvetica-Bold");
    try std.testing.expectEqual(@as(f64, 278), helvetica.widths.getWidth(' '));
    try std.testing.expectEqual(@as(f64, 944), helvetica.widths.getWidth('W'));

    var courier = FontEncoding.init(std.testing.allocator);
    defer courier.deinit();
    applyBase14FallbackMetrics(&courier, "Courier");
    try std.testing.expectEqual(@as(f64, 600), courier.widths.getWidth('i'));
    try std.testing.expectEqual(@as(f64, 600), courier.widths.getWidth('W'));

    var symbol = FontEncoding.init(std.testing.allocator);
    defer symbol.deinit();
    applyBase14FallbackMetrics(&symbol, "Symbol");
    try std.testing.expectEqual(@as(u21, 0x03A9), symbol.codepoint_map['W']);
    try std.testing.expectEqual(@as(u21, 0x03C0), symbol.codepoint_map['p']);
}

test "predefined CJK CMaps set width and writing mode conservatively" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();
    applyPredefinedCMap(&enc, "Adobe-Japan1-UCS2-V");
    try std.testing.expectEqual(@as(u8, 2), enc.bytes_per_char);
    try std.testing.expectEqual(@as(u8, 1), enc.wmode);

    var gb = FontEncoding.init(std.testing.allocator);
    defer gb.deinit();
    applyPredefinedCMap(&gb, "GBK-EUC-H");
    try std.testing.expectEqual(@as(u8, 2), gb.bytes_per_char);
    try std.testing.expectEqual(@as(u8, 0), gb.wmode);
}

test "broken Identity CID without ToUnicode reports map error" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();
    enc.is_cid = true;
    enc.bytes_per_char = 2;
    enc.cid_system_info = .{ .registry = "Adobe", .ordering = "Identity", .supplement = 0 };
    enc.has_to_unicode = false;

    var sink = struct {
        saw_map_error: bool = false,
        fn writeDecodedGlyph(self: *@This(), glyph: FontEncoding.DecodedGlyph) !void {
            self.saw_map_error = self.saw_map_error or glyph.unicode_map_error;
        }
    }{};
    try enc.decodeRecords(&[_]u8{ 0x00, 0x01 }, &sink);
    try std.testing.expect(sink.saw_map_error);
}
