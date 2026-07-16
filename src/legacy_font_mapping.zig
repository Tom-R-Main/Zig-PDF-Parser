const std = @import("std");

/// Resolves private glyph names only when the PDF identifies a known legacy
/// font family. Private names such as H11022 are not globally meaningful and
/// must never be treated like Adobe Glyph List names.
pub fn glyphNameToUnicode(base_font: ?[]const u8, glyph_name: []const u8) ?u21 {
    const font_name = normalizedBaseFont(base_font orelse return null);
    if (!std.mem.eql(u8, font_name, "MathematicalPi-One")) return null;

    return mathematicalPiOneGlyphNameToUnicode(glyph_name);
}

fn normalizedBaseFont(base_font: []const u8) []const u8 {
    const name = if (base_font.len > 0 and base_font[0] == '/') base_font[1..] else base_font;
    if (name.len <= 7 or name[6] != '+') return name;

    for (name[0..6]) |byte| {
        if (byte < 'A' or byte > 'Z') return name;
    }
    return name[7..];
}

fn mathematicalPiOneGlyphNameToUnicode(glyph_name: []const u8) ?u21 {
    if (std.mem.eql(u8, glyph_name, "H11021")) return '<';
    if (std.mem.eql(u8, glyph_name, "H11022")) return '>';
    if (std.mem.eql(u8, glyph_name, "H11350")) return 0x2265;
    return null;
}

test "MathematicalPi-One private glyph names are family scoped" {
    try std.testing.expectEqual(@as(?u21, '<'), glyphNameToUnicode("ABCDEF+MathematicalPi-One", "H11021"));
    try std.testing.expectEqual(@as(?u21, '>'), glyphNameToUnicode("MathematicalPi-One", "H11022"));
    try std.testing.expectEqual(@as(?u21, 0x2265), glyphNameToUnicode("PLWVNJ+MathematicalPi-One", "H11350"));

    try std.testing.expectEqual(@as(?u21, null), glyphNameToUnicode("ABCDEF+UnrelatedFont", "H11022"));
    try std.testing.expectEqual(@as(?u21, null), glyphNameToUnicode("abc123+MathematicalPi-One", "H11022"));
    try std.testing.expectEqual(@as(?u21, null), glyphNameToUnicode(null, "H11022"));
}
