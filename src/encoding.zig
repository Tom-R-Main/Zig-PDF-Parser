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
const agl = @import("agl.zig");
const legacy_font_mapping = @import("legacy_font_mapping.zig");
const font_mapping = @import("font_mapping.zig");

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

pub const MappingSource = font_mapping.MappingSource;
pub const CodeToCidMap = font_mapping.CodeToCidMap;
pub const CodeToUnicodeMap = font_mapping.ToUnicodeMap;
pub const CidCollectionMap = font_mapping.CidCollectionMap;
pub const CidToGidMap = font_mapping.CidToGidMap;
pub const EmbeddedFontMap = font_mapping.EmbeddedFontMap;

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
    /// Independent mapping stages. Do not infer Unicode from a CID or GID.
    simple_encoding: font_mapping.SimpleEncoding,
    code_cmap: CodeToCidMap,
    to_unicode: CodeToUnicodeMap,
    cid_collection: ?CidCollectionMap = null,
    cid_to_gid: CidToGidMap = .{},
    embedded_font: ?EmbeddedFontMap = null,
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
    /// True when this font dictionary supplied an explicit ToUnicode CMap.
    has_to_unicode: bool = false,
    /// True for /Subtype /Type3 fonts. These rely on PDF glyph programs but
    /// can still expose deterministic widths, bboxes, encodings, and ToUnicode.
    is_type3: bool = false,

    /// Diagnostic identity copied from the font dictionary/cache seam.
    font_object_num: ?u32 = null,
    subtype: ?[]const u8 = null,
    base_font: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub const CMapRange = CodeToUnicodeMap.Range;
    pub const CMapCodeSpace = font_mapping.CodeSpace;

    pub const DecodedGlyph = struct {
        source_code: u32,
        source_bytes: []const u8,
        bytes_consumed: u8,
        utf8_text: []const u8,
        glyph_width: f64,
        cid: ?u32 = null,
        gid: ?u32 = null,
        mapping_source: MappingSource = .unresolved,
        unicode_map_error: bool = false,
        multi_char_mapping: bool = false,
        writing_mode: u8 = 0,
        ascender: f64 = 800,
        descender: f64 = -200,
    };

    pub fn init(allocator: std.mem.Allocator) FontEncoding {
        return .{
            .simple_encoding = font_mapping.SimpleEncoding.init(win_ansi_encoding, .simple_encoding),
            .code_cmap = CodeToCidMap.init(allocator),
            .to_unicode = CodeToUnicodeMap.init(allocator),
            .is_cid = false,
            .bytes_per_char = 1,
            .wmode = 0,
            .metrics = .{},
            .widths = GlyphWidths.init(allocator),
            .cid_system_info = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontEncoding) void {
        self.code_cmap.deinit();
        self.to_unicode.deinit();
        self.widths.deinit();
        self.cid_to_gid.deinit(self.allocator);
        if (self.embedded_font) |*embedded| embedded.deinit();
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
            if (self.to_unicode.multi_map.get(byte)) |utf8_str| {
                try sink.writeDecodedGlyph(.{
                    .source_code = byte,
                    .source_bytes = data[index .. index + 1],
                    .bytes_consumed = 1,
                    .utf8_text = utf8_str,
                    .glyph_width = self.widths.getWidth(byte),
                    .mapping_source = .explicit_to_unicode,
                    .multi_char_mapping = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
                continue;
            }

            const explicit = self.to_unicode.lookupScalar(byte);
            const codepoint = explicit orelse self.simple_encoding.codepoints[byte];
            const mapping_source = if (explicit != null)
                MappingSource.explicit_to_unicode
            else
                self.simple_encoding.sources[byte];
            var buf: [4]u8 = undefined;
            if (codepoint == 0) {
                // No mapping - output replacement character or space
                try sink.writeDecodedGlyph(.{
                    .source_code = byte,
                    .source_bytes = data[index .. index + 1],
                    .bytes_consumed = 1,
                    .utf8_text = " ",
                    .glyph_width = self.widths.getWidth(byte),
                    .mapping_source = .unresolved,
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
                    .mapping_source = mapping_source,
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
            const code = self.code_cmap.readCharCode(data[i..]) orelse {
                try sink.writeDecodedGlyph(.{
                    .source_code = data[i],
                    .source_bytes = data[i .. i + 1],
                    .bytes_consumed = 1,
                    .utf8_text = " ",
                    .glyph_width = self.widths.default_width,
                    .mapping_source = .unresolved,
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

            const cid = self.code_cmap.lookup(code.value);
            const metrics_cid = cid orelse code.value;
            const gid = if (cid) |resolved_cid| self.cid_to_gid.getGid(resolved_cid) else null;

            if (self.to_unicode.multi_map.get(code.value)) |utf8_str| {
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = code.bytes_consumed,
                    .utf8_text = utf8_str,
                    .glyph_width = self.widths.getCIDWidth(metrics_cid),
                    .cid = cid,
                    .gid = gid,
                    .mapping_source = .explicit_to_unicode,
                    .multi_char_mapping = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
                continue;
            }

            var codepoint = self.to_unicode.lookupScalar(code.value);
            var mapping_source: MappingSource = if (codepoint != null) .explicit_to_unicode else .unresolved;

            if (codepoint == null) {
                if (self.cid_collection) |collection| {
                    if (cid) |resolved_cid| {
                        if (collection.lookup(resolved_cid)) |value| {
                            codepoint = value;
                            mapping_source = .adobe_collection;
                        }
                    }
                }
            }
            if (codepoint == null) {
                if (self.embedded_font) |*embedded| {
                    if (gid) |resolved_gid| {
                        if (embedded.lookupUnicode(resolved_gid)) |value| {
                            codepoint = value;
                            mapping_source = .embedded_font_cmap;
                        } else if (embedded.cff_parser) |*cff_parser| {
                            if (resolved_gid <= std.math.maxInt(u16)) {
                                if (cff_parser.getGlyphName(@intCast(resolved_gid))) |name| {
                                    if (glyphNameToUnicodeForFont(self.base_font, name)) |value| {
                                        codepoint = value;
                                        mapping_source = .glyph_name;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (codepoint == null and self.code_cmap.unicode_coding != .none) {
                const value = code.value;
                if (self.code_cmap.unicode_coding == .utf16 and value >= 0xD800 and value <= 0xDBFF) {
                    if (self.code_cmap.readCharCode(data[i..])) |low_code| {
                        const low = low_code.value;
                        if (low >= 0xDC00 and low <= 0xDFFF) {
                            codepoint = @intCast(0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00));
                            mapping_source = .adobe_collection;
                            i += low_code.bytes_consumed;
                        }
                    }
                } else if (value > 0 and value <= 0x10FFFF and !(value >= 0xD800 and value <= 0xDFFF)) {
                    codepoint = @intCast(value);
                    mapping_source = .adobe_collection;
                }
            }

            var buf: [4]u8 = undefined;

            if (codepoint) |final_codepoint| {
                const len = std.unicode.utf8Encode(final_codepoint, &buf) catch 0;
                if (len == 0) {
                    try sink.writeDecodedGlyph(.{
                        .source_code = code.value,
                        .source_bytes = data[source_start..i],
                        .bytes_consumed = @intCast(i - source_start),
                        .utf8_text = " ",
                        .glyph_width = self.widths.getCIDWidth(metrics_cid),
                        .cid = cid,
                        .gid = gid,
                        .mapping_source = .unresolved,
                        .unicode_map_error = true,
                        .writing_mode = self.wmode,
                        .ascender = self.metrics.ascender,
                        .descender = self.metrics.descender,
                    });
                    continue;
                }
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = @intCast(i - source_start),
                    .utf8_text = buf[0..len],
                    .glyph_width = self.widths.getCIDWidth(metrics_cid),
                    .cid = cid,
                    .gid = gid,
                    .mapping_source = mapping_source,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            } else {
                try sink.writeDecodedGlyph(.{
                    .source_code = code.value,
                    .source_bytes = data[source_start..i],
                    .bytes_consumed = @intCast(i - source_start),
                    .utf8_text = " ",
                    .glyph_width = self.widths.getCIDWidth(metrics_cid),
                    .cid = cid,
                    .gid = gid,
                    .mapping_source = .unresolved,
                    .unicode_map_error = true,
                    .writing_mode = self.wmode,
                    .ascender = self.metrics.ascender,
                    .descender = self.metrics.descender,
                });
            }
        }
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
    errdefer encoding.deinit();
    var parsed_tounicode = false;

    // Detect font type first
    const subtype = font_dict.getName("Subtype");
    const is_type0 = subtype != null and std.mem.eql(u8, subtype.?, "Type0");
    const is_type3 = subtype != null and std.mem.eql(u8, subtype.?, "Type3");
    encoding.is_type3 = is_type3;
    encoding.subtype = subtype;
    encoding.base_font = font_dict.getName("BaseFont");
    if (is_type3) encoding.embedded_font = EmbeddedFontMap.init(allocator);
    if (encoding.embedded_font) |*embedded| embedded.kind = .type3;

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
                .name => |name| try applyPredefinedCMap(&encoding, name),
                .stream => |stream| try parseEncodingCMap(allocator, stream, &encoding),
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
                    if (!encoding.to_unicode.explicit) {
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
    encoding.to_unicode.explicit = parsed_tounicode;
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

    if (fd.get("FontFile") != null) {
        if (encoding.embedded_font == null) encoding.embedded_font = EmbeddedFontMap.init(encoding.allocator);
        encoding.embedded_font.?.kind = .type1;
    }

    if (fd.get("FontFile2")) |font_file_obj| {
        const resolved_font_file = resolve_fn(resolve_ctx, font_file_obj);
        if (resolved_font_file == .stream) {
            const stream = resolved_font_file.stream;
            const data = decompress.decompressStream(
                encoding.allocator,
                stream.data,
                stream.dict.get("Filter"),
                stream.dict.get("DecodeParms"),
            ) catch null;
            if (data) |font_data| {
                defer encoding.allocator.free(font_data);
                if (encoding.embedded_font == null) encoding.embedded_font = EmbeddedFontMap.init(encoding.allocator);
                try encoding.embedded_font.?.loadSfnt(font_data, .truetype);
            }
        }
    }

    // Parse FontFile3 (CFF/OpenType)
    if (fd.get("FontFile3")) |ff3_obj| {
        const resolved_ff3 = resolve_fn(resolve_ctx, ff3_obj);
        if (resolved_ff3 == .stream) {
            const stream = resolved_ff3.stream;
            const subtype = stream.dict.getName("Subtype");
            if (subtype) |st| {
                if (std.mem.eql(u8, st, "Type1C") or std.mem.eql(u8, st, "CIDFontType0C")) {
                    const data = decompress.decompressStream(
                        encoding.allocator,
                        stream.data,
                        stream.dict.get("Filter"),
                        stream.dict.get("DecodeParms"),
                    ) catch null;

                    if (data) |d| {
                        if (encoding.embedded_font == null) encoding.embedded_font = EmbeddedFontMap.init(encoding.allocator);
                        const kind: EmbeddedFontMap.Kind = if (std.mem.eql(u8, st, "CIDFontType0C")) .cid_cff else .cff;
                        encoding.embedded_font.?.loadCff(d, kind);
                    }
                } else if (std.mem.eql(u8, st, "OpenType")) {
                    const data = decompress.decompressStream(
                        encoding.allocator,
                        stream.data,
                        stream.dict.get("Filter"),
                        stream.dict.get("DecodeParms"),
                    ) catch null;
                    if (data) |font_data| {
                        defer encoding.allocator.free(font_data);
                        if (encoding.embedded_font == null) encoding.embedded_font = EmbeddedFontMap.init(encoding.allocator);
                        try encoding.embedded_font.?.loadSfnt(font_data, .opentype);
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
    for (&encoding.simple_encoding.codepoints) |*cp| cp.* = 0;
    encoding.simple_encoding.sources = @splat(.unresolved);
    setSimpleCodepoint(encoding, ' ', ' ', .simple_encoding);
    setSimpleCodepoint(encoding, 'A', 0x0391, .simple_encoding);
    setSimpleCodepoint(encoding, 'B', 0x0392, .simple_encoding);
    setSimpleCodepoint(encoding, 'G', 0x0393, .simple_encoding);
    setSimpleCodepoint(encoding, 'D', 0x0394, .simple_encoding);
    setSimpleCodepoint(encoding, 'P', 0x03A0, .simple_encoding);
    setSimpleCodepoint(encoding, 'S', 0x03A3, .simple_encoding);
    setSimpleCodepoint(encoding, 'W', 0x03A9, .simple_encoding);
    setSimpleCodepoint(encoding, 'a', 0x03B1, .simple_encoding);
    setSimpleCodepoint(encoding, 'b', 0x03B2, .simple_encoding);
    setSimpleCodepoint(encoding, 'g', 0x03B3, .simple_encoding);
    setSimpleCodepoint(encoding, 'd', 0x03B4, .simple_encoding);
    setSimpleCodepoint(encoding, 'p', 0x03C0, .simple_encoding);
    setSimpleCodepoint(encoding, 's', 0x03C3, .simple_encoding);
    setSimpleCodepoint(encoding, 'w', 0x03C9, .simple_encoding);
    setSimpleCodepoint(encoding, '-', 0x2212, .simple_encoding);
    setSimpleCodepoint(encoding, '=', '=', .simple_encoding);
}

fn applyZapfDingbatsEncoding(encoding: *FontEncoding) void {
    for (&encoding.simple_encoding.codepoints) |*cp| cp.* = 0;
    encoding.simple_encoding.sources = @splat(.unresolved);
    setSimpleCodepoint(encoding, ' ', ' ', .simple_encoding);
    setSimpleCodepoint(encoding, '!', 0x2701, .simple_encoding);
    setSimpleCodepoint(encoding, '"', 0x2702, .simple_encoding);
    setSimpleCodepoint(encoding, '#', 0x2703, .simple_encoding);
    setSimpleCodepoint(encoding, '(', 0x260E, .simple_encoding);
    setSimpleCodepoint(encoding, ')', 0x2706, .simple_encoding);
    setSimpleCodepoint(encoding, '*', 0x261B, .simple_encoding);
    setSimpleCodepoint(encoding, '4', 0x2714, .simple_encoding);
    setSimpleCodepoint(encoding, '8', 0x2720, .simple_encoding);
}

fn setSimpleCodepoint(encoding: *FontEncoding, code: u8, value: u21, source: MappingSource) void {
    encoding.simple_encoding.codepoints[code] = value;
    encoding.simple_encoding.sources[code] = source;
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

    const kind: CidCollectionMap.Kind = if (encoding.cid_system_info.isAdobeJapan())
        .adobe_japan1
    else if (encoding.cid_system_info.isAdobeGB())
        .adobe_gb1
    else if (encoding.cid_system_info.isAdobeCNS())
        .adobe_cns1
    else if (encoding.cid_system_info.isAdobeKorea())
        .adobe_korea1
    else if (encoding.cid_system_info.isIdentity())
        .identity
    else
        .none;
    encoding.cid_collection = .{ .kind = kind, .supplement = encoding.cid_system_info.supplement };
}

/// Parse CIDToGIDMap from CIDFont dictionary
fn parseCIDToGIDMap(allocator: std.mem.Allocator, cid_font: Object.Dict, resolve_fn: *const fn (ctx: *const anyopaque, Object) Object, resolve_ctx: *const anyopaque, encoding: *FontEncoding) !void {
    const map_obj = cid_font.get("CIDToGIDMap") orelse return;
    const resolved = resolve_fn(resolve_ctx, map_obj);

    switch (resolved) {
        .name => |name| {
            if (std.mem.eql(u8, name, "Identity")) {
                encoding.cid_to_gid.mapping = .identity;
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
            encoding.cid_to_gid.mapping = .{ .stream_map = gid_map };
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
fn applyPredefinedCMap(encoding: *FontEncoding, name: []const u8) !void {
    try encoding.code_cmap.setName(name);
    // Detect vertical writing mode from CMap name suffix
    // Names ending in "-V" indicate vertical writing (WMode=1)
    if (name.len >= 2 and name[name.len - 2] == '-' and name[name.len - 1] == 'V') {
        encoding.wmode = 1;
        encoding.code_cmap.wmode = 1;
    }

    // Identity CMaps - CID = Unicode (common for CJK fonts with ToUnicode)
    if (std.mem.eql(u8, name, "Identity-H") or std.mem.eql(u8, name, "Identity-V")) {
        // Identity mapping: the character codes are CIDs
        // Actual Unicode comes from ToUnicode CMap
        encoding.bytes_per_char = 2;
        encoding.code_cmap.bytes_per_char = 2;
        encoding.code_cmap.identity = true;
        return;
    }

    if (std.mem.indexOf(u8, name, "Adobe-Japan1") != null or
        std.mem.indexOf(u8, name, "Adobe-GB1") != null or
        std.mem.indexOf(u8, name, "Adobe-CNS1") != null or
        std.mem.indexOf(u8, name, "Adobe-Korea1") != null)
    {
        encoding.bytes_per_char = 2;
        encoding.code_cmap.bytes_per_char = 2;
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
        encoding.bytes_per_char = 2;
        encoding.code_cmap.bytes_per_char = 2;
        if (std.mem.indexOf(u8, name, "UCS2") != null) encoding.code_cmap.unicode_coding = .ucs2;
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
        encoding.code_cmap.bytes_per_char = 2;
        if (std.mem.indexOf(u8, name, "UCS2") != null) encoding.code_cmap.unicode_coding = .ucs2;
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
        encoding.code_cmap.bytes_per_char = 2;
        encoding.code_cmap.unicode_coding = .utf16;
        return;
    }

    // Default for unknown predefined CMaps - assume 2-byte
    encoding.bytes_per_char = 2;
    encoding.code_cmap.bytes_per_char = 2;
}

pub fn applyNamedEncoding(encoding: *FontEncoding, name: []const u8) void {
    if (std.mem.eql(u8, name, "WinAnsiEncoding")) {
        encoding.simple_encoding.replace(win_ansi_encoding, .simple_encoding);
    } else if (std.mem.eql(u8, name, "MacRomanEncoding")) {
        encoding.simple_encoding.replace(mac_roman_encoding, .simple_encoding);
    } else if (std.mem.eql(u8, name, "StandardEncoding")) {
        encoding.simple_encoding.replace(standard_encoding, .simple_encoding);
    } else if (std.mem.eql(u8, name, "PDFDocEncoding")) {
        encoding.simple_encoding.replace(pdf_doc_encoding, .simple_encoding);
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
                    encoding.simple_encoding.codepoints[code] = glyphNameToUnicodeForFont(encoding.base_font, name) orelse 0;
                    encoding.simple_encoding.sources[code] = if (encoding.simple_encoding.codepoints[code] == 0) .unresolved else .glyph_name;
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

    encoding.to_unicode.explicit = true;
    if (findCMapName(data)) |name| try encoding.to_unicode.setName(name);
    if (findUseCMapName(data)) |name| try encoding.to_unicode.setUseCMapName(name);

    var ranges: std.ArrayList(FontEncoding.CMapRange) = .empty;
    errdefer ranges.deinit(allocator);
    var code_spaces: std.ArrayList(FontEncoding.CMapCodeSpace) = .empty;
    errdefer code_spaces.deinit(allocator);

    var pos: usize = 0;
    var max_source_bytes: u8 = if (encoding.is_cid) encoding.bytes_per_char else 1;
    var max_mapping_source_bytes: u8 = if (encoding.is_cid) encoding.bytes_per_char else 1;

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
            try parseBfChar(allocator, data, &pos, &ranges, encoding, &max_source_bytes, &max_mapping_source_bytes);
        } else if (matchAt(data, pos, "beginbfrange")) {
            pos += 12;
            try parseBfRange(allocator, data, &pos, &ranges, encoding, &max_source_bytes, &max_mapping_source_bytes);
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
    if (encoding.to_unicode.ranges.len > 0) allocator.free(encoding.to_unicode.ranges);
    encoding.to_unicode.ranges = owned_ranges;

    const owned_code_spaces = try code_spaces.toOwnedSlice(allocator);
    std.mem.sort(FontEncoding.CMapCodeSpace, owned_code_spaces, {}, struct {
        fn lessThan(_: void, a: FontEncoding.CMapCodeSpace, b: FontEncoding.CMapCodeSpace) bool {
            if (a.byte_count != b.byte_count) return a.byte_count < b.byte_count;
            return a.low < b.low;
        }
    }.lessThan);
    if (encoding.to_unicode.codespaces.len > 0) allocator.free(encoding.to_unicode.codespaces);
    encoding.to_unicode.codespaces = owned_code_spaces;
}

/// Parse a Type0 /Encoding CMap. This grammar is deliberately independent
/// from ToUnicode: its destinations are CIDs, never Unicode scalar values.
pub fn parseEncodingCMap(allocator: std.mem.Allocator, stream: Object.Stream, encoding: *FontEncoding) !void {
    const data = decompress.decompressStream(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
    ) catch return;
    defer allocator.free(data);

    if (findCMapName(data)) |name| try encoding.code_cmap.setName(name);
    if (findUseCMapName(data)) |name| {
        try encoding.code_cmap.setUseCMapName(name);
        if (std.mem.eql(u8, name, "Identity-H") or std.mem.eql(u8, name, "Identity-V")) {
            encoding.code_cmap.identity = true;
        }
    }
    setUnicodeCodingFromName(&encoding.code_cmap, encoding.code_cmap.name);
    setUnicodeCodingFromName(&encoding.code_cmap, encoding.code_cmap.usecmap_name);

    var code_spaces: std.ArrayList(font_mapping.CodeSpace) = .empty;
    errdefer code_spaces.deinit(allocator);
    var ranges: std.ArrayList(CodeToCidMap.Range) = .empty;
    errdefer ranges.deinit(allocator);
    var notdef_ranges: std.ArrayList(CodeToCidMap.Range) = .empty;
    errdefer notdef_ranges.deinit(allocator);
    var max_source_bytes: u8 = 1;
    var pos: usize = 0;

    while (pos < data.len) {
        skipWhitespaceAndComments(data, &pos);
        if (pos >= data.len) break;
        if (matchAt(data, pos, "/WMode")) {
            pos += 6;
            if (parseUnsignedToken(data, &pos)) |value| {
                encoding.code_cmap.wmode = @intCast(@min(value, 1));
                encoding.wmode = encoding.code_cmap.wmode;
            }
        } else if (matchAt(data, pos, "begincodespacerange")) {
            pos += 19;
            try parseCodeSpaceRange(allocator, data, &pos, &max_source_bytes, &code_spaces);
        } else if (matchAt(data, pos, "begincidchar")) {
            pos += 12;
            try parseCodeToCidChars(allocator, data, &pos, "endcidchar", &encoding.code_cmap.singles);
        } else if (matchAt(data, pos, "begincidrange")) {
            pos += 13;
            try parseCodeToCidRanges(allocator, data, &pos, "endcidrange", &ranges);
        } else if (matchAt(data, pos, "beginnotdefchar")) {
            pos += 15;
            try parseCodeToCidChars(allocator, data, &pos, "endnotdefchar", &encoding.code_cmap.notdef_singles);
        } else if (matchAt(data, pos, "beginnotdefrange")) {
            pos += 16;
            try parseCodeToCidRanges(allocator, data, &pos, "endnotdefrange", &notdef_ranges);
        } else {
            pos += 1;
        }
    }

    encoding.code_cmap.codespaces = try code_spaces.toOwnedSlice(allocator);
    encoding.code_cmap.ranges = try ranges.toOwnedSlice(allocator);
    encoding.code_cmap.notdef_ranges = try notdef_ranges.toOwnedSlice(allocator);
    encoding.code_cmap.bytes_per_char = max_source_bytes;
    encoding.bytes_per_char = max_source_bytes;
    encoding.wmode = encoding.code_cmap.wmode;
}

fn parseCodeToCidChars(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    end_keyword: []const u8,
    map: *std.AutoHashMapUnmanaged(u32, u32),
) !void {
    while (pos.* < data.len) {
        skipWhitespaceAndComments(data, pos);
        if (matchAt(data, pos.*, end_keyword)) {
            pos.* += end_keyword.len;
            return;
        }
        const src = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        const cid = parseUnsignedToken(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        try map.put(allocator, src.value, cid);
    }
}

fn parseCodeToCidRanges(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    end_keyword: []const u8,
    ranges: *std.ArrayList(CodeToCidMap.Range),
) !void {
    while (pos.* < data.len) {
        skipWhitespaceAndComments(data, pos);
        if (matchAt(data, pos.*, end_keyword)) {
            pos.* += end_keyword.len;
            return;
        }
        const start = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        skipWhitespaceAndComments(data, pos);
        const end = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        const cid = parseUnsignedToken(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        try ranges.append(allocator, .{ .src_start = start.value, .src_end = end.value, .dst_start = cid });
    }
}

fn skipWhitespaceAndComments(data: []const u8, pos: *usize) void {
    while (pos.* < data.len) {
        if (isWhitespace(data[pos.*])) {
            pos.* += 1;
        } else if (data[pos.*] == '%') {
            while (pos.* < data.len and data[pos.*] != '\n' and data[pos.*] != '\r') pos.* += 1;
        } else {
            return;
        }
    }
}

fn parseUnsignedToken(data: []const u8, pos: *usize) ?u32 {
    skipWhitespaceAndComments(data, pos);
    const start = pos.*;
    var value: u32 = 0;
    while (pos.* < data.len and std.ascii.isDigit(data[pos.*])) : (pos.* += 1) {
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, data[pos.*] - '0') catch return null;
    }
    return if (pos.* > start) value else null;
}

fn findCMapName(data: []const u8) ?[]const u8 {
    const key = "/CMapName";
    const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
    var pos = key_pos + key.len;
    skipWhitespaceAndComments(data, &pos);
    return parseNameToken(data, &pos);
}

fn findUseCMapName(data: []const u8) ?[]const u8 {
    const keyword = "usecmap";
    const keyword_pos = std.mem.indexOf(u8, data, keyword) orelse return null;
    var pos = keyword_pos;
    while (pos > 0 and isWhitespace(data[pos - 1])) pos -= 1;
    var start = pos;
    while (start > 0 and data[start - 1] != '/' and !isWhitespace(data[start - 1])) start -= 1;
    if (start == 0 or data[start - 1] != '/') return null;
    start -= 1;
    return parseNameToken(data, &start);
}

fn parseNameToken(data: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= data.len or data[pos.*] != '/') return null;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < data.len and !isWhitespace(data[pos.*]) and
        data[pos.*] != '/' and data[pos.*] != '[' and data[pos.*] != ']' and
        data[pos.*] != '<' and data[pos.*] != '>' and data[pos.*] != '(' and data[pos.*] != ')')
    {
        pos.* += 1;
    }
    return if (pos.* > start) data[start..pos.*] else null;
}

fn setUnicodeCodingFromName(code_cmap: *CodeToCidMap, maybe_name: ?[]const u8) void {
    const name = maybe_name orelse return;
    if (std.mem.indexOf(u8, name, "UTF16") != null) {
        code_cmap.unicode_coding = .utf16;
    } else if (std.mem.indexOf(u8, name, "UCS2") != null) {
        code_cmap.unicode_coding = .ucs2;
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

fn parseBfChar(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    _: *std.ArrayList(FontEncoding.CMapRange),
    encoding: *FontEncoding,
    max_source_bytes: *u8,
    max_mapping_source_bytes: *u8,
) !void {
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
        max_mapping_source_bytes.* = @max(max_mapping_source_bytes.*, src.byte_count);

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
            try encoding.to_unicode.multi_map.put(allocator, src.value, utf8_str);
        } else {
            // Single character mapping
            var dst: u32 = 0;
            for (dst_buf[0..dst_result.byte_count]) |b| {
                dst = (dst << 8) | b;
            }

            if (dst <= 0x10FFFF and !(dst >= 0xD800 and dst <= 0xDFFF)) {
                try encoding.to_unicode.scalar_map.put(allocator, src.value, @intCast(dst));
            }
        }
    }
}

fn parseBfRange(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    ranges: *std.ArrayList(FontEncoding.CMapRange),
    encoding: *FontEncoding,
    max_source_bytes: *u8,
    max_mapping_source_bytes: *u8,
) !void {
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
        max_mapping_source_bytes.* = @max(max_mapping_source_bytes.*, src_start.byte_count);
        skipWhitespace(data, pos);
        const src_end = parseHexTokenDetailed(data, pos) orelse {
            skipToNextEntry(data, pos);
            continue;
        };
        max_source_bytes.* = @max(max_source_bytes.*, src_end.byte_count);
        max_mapping_source_bytes.* = @max(max_mapping_source_bytes.*, src_end.byte_count);
        skipWhitespace(data, pos);

        // Destination can be a hex value or an array
        if (pos.* < data.len and data[pos.*] == '<') {
            const dst_start = parseHexToken(data, pos) orelse {
                skipToNextEntry(data, pos);
                continue;
            };
            if (dst_start > 0x10FFFF or (dst_start >= 0xD800 and dst_start <= 0xDFFF)) {
                skipToNextEntry(data, pos);
                continue;
            }
            try ranges.append(allocator, .{
                .src_start = src_start.value,
                .src_end = src_end.value,
                .dst_start = @intCast(dst_start),
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
                    try encoding.to_unicode.multi_map.put(allocator, src, utf8_str);
                } else {
                    var dst: u32 = 0;
                    for (dst_buf[0..dst_result.byte_count]) |b| {
                        dst = (dst << 8) | b;
                    }
                    if (dst <= 0x10FFFF and !(dst >= 0xD800 and dst <= 0xDFFF)) {
                        try encoding.to_unicode.scalar_map.put(allocator, src, @intCast(dst));
                    }
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
    return glyphNameToUnicodeForFont(null, name) orelse 0;
}

fn glyphNameToUnicodeForFont(base_font: ?[]const u8, name: []const u8) ?u21 {
    if (agl.glyphNameToUnicode(name)) |unicode| return unicode;
    return legacy_font_mapping.glyphNameToUnicode(base_font, name);
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
    enc.code_cmap.bytes_per_char = 2;
    enc.code_cmap.unicode_coding = .ucs2;

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
    enc.code_cmap.bytes_per_char = 2;
    enc.code_cmap.unicode_coding = .ucs2;

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
    };
    enc.to_unicode.ranges = ranges;
    enc.is_cid = true;
    enc.bytes_per_char = 2;
    enc.code_cmap.bytes_per_char = 2;

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
    enc.code_cmap.bytes_per_char = 2;
    enc.code_cmap.unicode_coding = .utf16;

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
    enc.simple_encoding.codepoints[65] = 'B';

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{65}, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("B", output.items);
}

test "CID identity without Unicode evidence is unresolved" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;
    enc.code_cmap.bytes_per_char = 2;
    enc.code_cmap.identity = true;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    // 0x0041 = 'A' in Unicode
    try enc.decode(&[_]u8{ 0x00, 0x41 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings(" ", output.items);
}

test "CMap range mapping" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();

    enc.is_cid = true;
    enc.bytes_per_char = 2;

    // Add a range: codes 0x0100-0x0102 map to 'X', 'Y', 'Z'
    var ranges: std.ArrayList(FontEncoding.CMapRange) = .empty;
    try ranges.append(std.testing.allocator, .{ .src_start = 0x0100, .src_end = 0x0102, .dst_start = 'X' });
    enc.to_unicode.ranges = try ranges.toOwnedSlice(std.testing.allocator);
    enc.code_cmap.bytes_per_char = 2;

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

test "simple font stays one-byte when ToUnicode codespace is over-wide" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\2 beginbfchar
        \\<41> <0041>
        \\<42> <0042>
        \\endbfchar
        \\endcmap
        \\end
        \\end
    ;

    var entries = [_]Object.Dict.Entry{
        .{ .key = "Subtype", .value = .{ .name = "Type1" } },
        .{ .key = "Encoding", .value = .{ .name = "WinAnsiEncoding" } },
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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try enc.decode("AB", runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings("AB", output.items);
}

test "ToUnicode two-byte codespace does not promote a simple font" {
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

    try std.testing.expect(!enc.is_cid);
    try std.testing.expectEqual(@as(u8, 1), enc.bytes_per_char);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(&[_]u8{ 0x00, 0x41 }, runtime.arrayListWriter(&output, std.testing.allocator));
    try std.testing.expectEqualStrings(" B", output.items);
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

    enc.is_cid = true;
    enc.code_cmap.codespaces = try std.testing.allocator.dupe(font_mapping.CodeSpace, enc.to_unicode.codespaces);
    enc.code_cmap.bytes_per_char = 2;
    try std.testing.expectEqual(@as(usize, 2), enc.to_unicode.codespaces.len);

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
    enc.is_cid = true;
    enc.code_cmap.bytes_per_char = 2;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try enc.decode(
        &[_]u8{ 0x01, 0x00, 0x01, 0x01, 0x01, 0x02, 0x02, 0x00 },
        runtime.arrayListWriter(&output, std.testing.allocator),
    );
    try std.testing.expectEqualStrings("XYZfi", output.items);
}

test "Encoding CMap grammar parses CID and notdef mappings independently" {
    const cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapName /Fixture-V def
        \\/WMode 1 def
        \\/Identity-H usecmap
        \\2 begincodespacerange
        \\<00> <7F>
        \\<8100> <81FF>
        \\endcodespacerange
        \\1 begincidchar
        \\<41> 7
        \\endcidchar
        \\1 begincidrange
        \\<8100> <8102> 20
        \\endcidrange
        \\1 beginnotdefchar
        \\<7F> 99
        \\endnotdefchar
        \\1 beginnotdefrange
        \\<8170> <8172> 120
        \\endnotdefrange
        \\endcmap
        \\end
        \\end
    ;
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();
    enc.is_cid = true;
    try parseEncodingCMap(std.testing.allocator, .{
        .dict = .{ .entries = &.{} },
        .data = cmap,
    }, &enc);

    try std.testing.expectEqualStrings("Fixture-V", enc.code_cmap.name.?);
    try std.testing.expectEqualStrings("Identity-H", enc.code_cmap.usecmap_name.?);
    try std.testing.expectEqual(@as(u8, 1), enc.code_cmap.wmode);
    try std.testing.expectEqual(@as(usize, 2), enc.code_cmap.codespaces.len);
    try std.testing.expectEqual(@as(?u32, 7), enc.code_cmap.lookup(0x41));
    try std.testing.expectEqual(@as(?u32, 21), enc.code_cmap.lookup(0x8101));
    try std.testing.expectEqual(@as(?u32, 99), enc.code_cmap.lookup(0x7F));
    try std.testing.expectEqual(@as(?u32, 121), enc.code_cmap.lookup(0x8171));
    try std.testing.expectEqual(@as(usize, 0), enc.to_unicode.scalar_map.count());
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
    enc.simple_encoding.codepoints[0] = 0;
    enc.simple_encoding.sources[0] = .unresolved;

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
    try enc.to_unicode.multi_map.put(allocator, 'f', ligature);

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
    cid.code_cmap.bytes_per_char = 2;
    cid.code_cmap.identity = true;
    cid.wmode = 1;
    try cid.to_unicode.scalar_map.put(allocator, 0x0041, 'A');
    cid.widths.default_width = 880;

    var cid_sink = struct {
        text: std.ArrayList(u8) = .empty,
        width: f64 = 0,
        cid_value: ?u32 = null,
        writing_mode: u8 = 0,

        fn writeDecodedGlyph(self: *@This(), glyph: FontEncoding.DecodedGlyph) !void {
            self.width = glyph.glyph_width;
            self.cid_value = glyph.cid;
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
    try std.testing.expectEqual(@as(u21, 0x03A9), symbol.simple_encoding.codepoints['W']);
    try std.testing.expectEqual(@as(u21, 0x03C0), symbol.simple_encoding.codepoints['p']);
}

test "predefined CJK CMaps set width and writing mode conservatively" {
    var enc = FontEncoding.init(std.testing.allocator);
    defer enc.deinit();
    try applyPredefinedCMap(&enc, "Adobe-Japan1-UCS2-V");
    try std.testing.expectEqual(@as(u8, 2), enc.bytes_per_char);
    try std.testing.expectEqual(@as(u8, 1), enc.wmode);

    var gb = FontEncoding.init(std.testing.allocator);
    defer gb.deinit();
    try applyPredefinedCMap(&gb, "GBK-EUC-H");
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
