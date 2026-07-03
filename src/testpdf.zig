//! Test PDF Generator
//!
//! Creates minimal valid PDFs for testing the parser.
//! These are hand-crafted PDFs that exercise specific features.

const std = @import("std");
const runtime = @import("runtime.zig");

/// Generate a minimal PDF with plain text
pub fn generateMinimalPdf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    // Header
    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n"); // Binary marker

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n");
    try writer.writeAll("<< /Type /Catalog /Pages 2 0 R >>\n");
    try writer.writeAll("endobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n");
    try writer.writeAll("<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n");
    try writer.writeAll("endobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    // Object 4: Content stream
    const obj4_offset = pdf.items.len;

    // Build content stream
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    const cw = runtime.arrayListWriter(&content, allocator);

    try cw.writeAll("BT\n");
    try cw.writeAll("/F1 12 Tf\n");
    try cw.writeAll("100 700 Td\n");
    try cw.print("({s}) Tj\n", .{text});
    try cw.writeAll("ET\n");

    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\n");
    try writer.writeAll("endobj\n");

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n");
    try writer.writeAll("0 6\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    // Trailer
    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n", .{xref_offset});
    try writer.writeAll("%%EOF\n");

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with a stroked rectangle that should be detected as rulings.
pub fn generateRulingLinesPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n");
    try writer.writeAll("<< /Type /Catalog /Pages 2 0 R >>\n");
    try writer.writeAll("endobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n");
    try writer.writeAll("<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n");
    try writer.writeAll("endobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>\n");
    try writer.writeAll("endobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    const cw = runtime.arrayListWriter(&content, allocator);
    try cw.writeAll("1 w\n");
    try cw.writeAll("100 600 200 80 re\n");
    try cw.writeAll("S\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n");
    try writer.writeAll("0 5\n");
    try writer.print("{d:0>10} 65535 f \n", .{@as(u64, 0)});
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});

    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 5 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n", .{xref_offset});
    try writer.writeAll("%%EOF\n");

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with multiple pages
pub fn generateMultiPagePdf(allocator: std.mem.Allocator, pages_text: []const []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);
    var offsets: std.ArrayList(u64) = .empty;
    defer offsets.deinit(allocator);

    // Header
    try writer.writeAll("%PDF-1.4\n");
    try writer.writeAll("%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages - build kids array dynamically
    // Object layout: 1=Catalog, 2=Pages, 3=Font, then pairs of (Page, Content)
    // So pages are at 4, 6, 8, ... (4 + i*2)
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [");
    for (0..pages_text.len) |i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.print("{} 0 R", .{4 + i * 2}); // Page objects at 4, 6, 8, ...
    }
    try writer.print("] /Count {} >>\nendobj\n", .{pages_text.len});

    // Object 3: Font (shared)
    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page objects and content streams
    const base_obj = 4;
    for (pages_text, 0..) |text, i| {
        const page_obj = base_obj + i * 2;
        const content_obj = page_obj + 1;

        // Page object
        try offsets.append(allocator, pdf.items.len);
        try writer.print("{} 0 obj\n", .{page_obj});
        try writer.writeAll("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 3 0 R >> >> >>\n", .{content_obj});
        try writer.writeAll("endobj\n");

        // Content stream
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var cw = runtime.arrayListWriter(&content, allocator);
        try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try cw.print("({s}) Tj\n", .{text});
        try cw.writeAll("ET\n");

        try offsets.append(allocator, pdf.items.len);
        try writer.print("{} 0 obj\n<< /Length {} >>\nstream\n", .{ content_obj, content.items.len });
        try writer.writeAll(content.items);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    // XRef table
    const xref_offset = pdf.items.len;
    const total_objects = offsets.items.len + 1; // +1 for object 0
    try writer.writeAll("xref\n");
    try writer.print("0 {}\n", .{total_objects});
    try writer.writeAll("0000000000 65535 f \n");

    for (offsets.items) |offset| {
        try writer.print("{d:0>10} 00000 n \n", .{offset});
    }

    // Trailer
    try writer.writeAll("trailer\n");
    try writer.print("<< /Size {} /Root 1 0 R >>\n", .{total_objects});
    try writer.print("startxref\n{}\n", .{xref_offset});
    try writer.writeAll("%%EOF\n");

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with TJ operator (array-based text)
pub fn generateTJPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Content with TJ operator
    const content = "BT\n/F1 12 Tf\n100 700 Td\n[(Hello) -200 (World)] TJ\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF that exercises text-object state and line operators.
pub fn generateTextStatePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content =
        "BT\n" ++
        "/F1 12 Tf\n" ++
        "14 TL\n" ++
        "100 700 Td\n" ++
        "(Line1) Tj\n" ++
        "T*\n" ++
        "(Line2) Tj\n" ++
        "(Line3) '\n" ++
        "0 0 (Line4) \"\n" ++
        "ET\n" ++
        "(Outside) Tj\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}endstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a simple 8-bit font PDF whose ToUnicode CMap remaps 0x41 to U+03A9.
pub fn generateSimpleToUnicodePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n<41> Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}endstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>\nendobj\n");

    const tounicode_cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /SimpleToUnicode def
        \\1 begincodespacerange
        \\<00> <FF>
        \\endcodespacerange
        \\1 beginbfchar
        \\<41> <03A9>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;

    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ tounicode_cmap.len, tounicode_cmap });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a dense born-digital page with an ASCII ToUnicode CMap.
pub fn generateCleanNativePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = runtime.arrayListWriter(&content, allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n");
    const lines = [_][]const u8{
        "Clean born digital text has enough native glyph coverage for extraction.",
        "The page is deliberately dense so sparse text does not dominate routing.",
        "Unicode metadata is present through a ToUnicode map for the font.",
        "Normal top to bottom ordering keeps reading order confidence high.",
        "This fixture should remain on the native fast path without OCR.",
        "Additional words add page coverage and realistic paragraph length.",
        "Adaptive routing should report use native for this document page.",
    };
    for (lines, 0..) |line, index| {
        try cw.print("1 0 0 1 72 {} Tm\n({s}) Tj\n", .{ 720 - index * 20, line });
    }
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>\nendobj\n");

    const tounicode_cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /AsciiToUnicode def
        \\1 begincodespacerange
        \\<00> <FF>
        \\endcodespacerange
        \\1 beginbfrange
        \\<20> <7E> <0020>
        \\endbfrange
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;

    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ tounicode_cmap.len, tounicode_cmap });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with a CID font (Type0 composite font with ToUnicode)
/// Uses UTF-16BE encoded text and a ToUnicode CMap for mapping
pub fn generateCIDFontPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream with UTF-16BE encoded text
    // "Hello" in UTF-16BE: 0048 0065 006C 006C 006F
    // Plus "中" (U+4E2D) in UTF-16BE: 4E2D
    const content = "BT\n/F1 12 Tf\n100 700 Td\n<00480065006C006C006F20004E2D> Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Type0 Font (Composite font)
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /Type0 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /Encoding /Identity-H\n");
    try writer.writeAll("   /DescendantFonts [6 0 R]\n");
    try writer.writeAll("   /ToUnicode 7 0 R >>\n");
    try writer.writeAll("endobj\n");

    // Object 6: CIDFont
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n");
    try writer.writeAll("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /TestCIDFont\n");
    try writer.writeAll("   /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n");
    try writer.writeAll("   /W [0 [500]] >>\n"); // Simple width array
    try writer.writeAll("endobj\n");

    // Object 7: ToUnicode CMap
    const tounicode_cmap =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /TestCMap def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\7 beginbfchar
        \\<0048> <0048>
        \\<0065> <0065>
        \\<006C> <006C>
        \\<006F> <006F>
        \\<0020> <0020>
        \\<0000> <0000>
        \\<4E2D> <4E2D>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;

    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ tounicode_cmap.len, tounicode_cmap });

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn generateSinglePageFontFixturePdf(
    allocator: std.mem.Allocator,
    font_resources: []const u8,
    content: []const u8,
    extra_objects: []const []const u8,
) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    try offsets.append(allocator, pdf.items.len);
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << ");
    try writer.writeAll(font_resources);
    try writer.writeAll(" >> >> >>\nendobj\n");

    try offsets.append(allocator, pdf.items.len);
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    for (extra_objects) |object| {
        try offsets.append(allocator, pdf.items.len);
        try writer.writeAll(object);
        if (!std.mem.endsWith(u8, object, "\n")) try writer.writeByte('\n');
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n");
    try writer.print("0 {}\n", .{offsets.items.len + 1});
    try writer.writeAll("0000000000 65535 f \n");
    for (offsets.items) |offset| {
        try writer.print("{d:0>10} 00000 n \n", .{offset});
    }
    try writer.writeAll("trailer\n");
    try writer.print("<< /Size {} /Root 1 0 R >>\n", .{offsets.items.len + 1});
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn repeatedWidths(allocator: std.mem.Allocator, count: usize, width_value: []const u8) ![]u8 {
    var widths: std.ArrayList(u8) = .empty;
    errdefer widths.deinit(allocator);
    var writer = runtime.arrayListWriter(&widths, allocator);
    for (0..count) |index| {
        if (index > 0) try writer.writeByte(' ');
        try writer.writeAll(width_value);
    }
    return widths.toOwnedSlice(allocator);
}

/// Generate a fixture where /ActualText repairs intentionally bad visible text.
pub fn generateActualTextRepairPdf(allocator: std.mem.Allocator) ![]u8 {
    const content =
        "BT\n" ++
        "/F1 12 Tf\n" ++
        "100 700 Td\n" ++
        "/Span << /ActualText (Correct ActualText replacement) /MCID 0 >> BDC\n" ++
        "(WRONGVISIBLE) Tj\n" ++
        "EMC\n" ++
        "ET\n";
    const font =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n" ++
        "endobj\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{font});
}

/// Generate a page-level rotation fixture for render-backed geometry checks.
pub fn generateRotatedPageTextPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 18 Tf\n100 100 Td\n(Rotated page text) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a page with a clipping path that hides part of extractable text.
pub fn generateClippedTextPdf(allocator: std.mem.Allocator) ![]u8 {
    const content =
        "BT\n/F1 12 Tf\n72 740 Td\n(Clipped fixture) Tj\nET\n" ++
        "q\n100 690 50 24 re W n\n" ++
        "BT\n/F1 18 Tf\n100 700 Td\n(Clipped hidden tail) Tj\nET\n" ++
        "Q\n";
    const font =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n" ++
        "endobj\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{font});
}

/// Generate white-on-white text that mimics a hidden OCR layer.
pub fn generateInvisibleOcrLayerPdf(allocator: std.mem.Allocator) ![]u8 {
    const content =
        "BT\n/F1 12 Tf\n72 740 Td\n(Visible anchor) Tj\nET\n" ++
        "1 1 1 rg\n" ++
        "BT\n/F1 14 Tf\n72 700 Td\n(Invisible OCR Layer) Tj\nET\n" ++
        "0 0 0 rg\n";
    const font =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n" ++
        "endobj\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{font});
}

/// Generate a deterministic Type3 font fixture using WinAnsi text mapping.
pub fn generateType3SimplePdf(allocator: std.mem.Allocator) ![]u8 {
    const widths = try repeatedWidths(allocator, 91, "600");
    defer allocator.free(widths);
    const font = try std.fmt.allocPrint(
        allocator,
        "5 0 obj\n" ++
            "<< /Type /Font /Subtype /Type3 /Name /F1 /FontBBox [0 -200 1000 900] " ++
            "/FontMatrix [0.001 0 0 0.001 0 0] /FirstChar 32 /LastChar 122 " ++
            "/Widths [{s}] /Encoding /WinAnsiEncoding /Resources << >> /CharProcs << /.notdef 6 0 R >> >>\n" ++
            "endobj\n",
        .{widths},
    );
    defer allocator.free(font);
    const charproc =
        "6 0 obj\n" ++
        "<< /Length 17 >>\n" ++
        "stream\n" ++
        "600 0 0 0 0 0 d0\n" ++
        "endstream\n" ++
        "endobj\n";
    const content = "BT\n/F1 16 Tf\n100 700 Td\n(Type3 simple text) Tj\nET\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{ font, charproc });
}

/// Generate a Type3 font whose ToUnicode CMap remaps raw ABC to XYZ.
pub fn generateType3ToUnicodePdf(allocator: std.mem.Allocator) ![]u8 {
    const font =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type3 /Name /F1 /FontBBox [0 -200 1000 900] " ++
        "/FontMatrix [0.001 0 0 0.001 0 0] /FirstChar 65 /LastChar 67 /Widths [600 600 600] " ++
        "/Encoding << /Type /Encoding /Differences [65 /A /B /C] >> /Resources << >> " ++
        "/CharProcs << /.notdef 6 0 R /A 6 0 R /B 6 0 R /C 6 0 R >> /ToUnicode 7 0 R >>\n" ++
        "endobj\n";
    const charproc =
        "6 0 obj\n" ++
        "<< /Length 17 >>\n" ++
        "stream\n" ++
        "600 0 0 0 0 0 d0\n" ++
        "endstream\n" ++
        "endobj\n";
    const tounicode =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /Type3ToUnicode def
        \\1 begincodespacerange
        \\<00> <FF>
        \\endcodespacerange
        \\3 beginbfchar
        \\<41> <0058>
        \\<42> <0059>
        \\<43> <005A>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;
    const cmap_object = try std.fmt.allocPrint(
        allocator,
        "7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n",
        .{ tounicode.len, tounicode },
    );
    defer allocator.free(cmap_object);
    const content = "BT\n/F1 16 Tf\n100 700 Td\n(ABC) Tj\nET\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{ font, charproc, cmap_object });
}

/// Generate an Identity-H CID font without ToUnicode and with a suspicious control CID.
pub fn generateIdentityHBrokenPdf(allocator: std.mem.Allocator) ![]u8 {
    const content =
        "BT\n" ++
        "/F1 12 Tf\n100 700 Td\n(Broken identity) Tj\n" ++
        "/F2 12 Tf\n100 680 Td\n<0001> Tj\n" ++
        "ET\n";
    const font1 =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\n" ++
        "endobj\n";
    const font2 =
        "6 0 obj\n" ++
        "<< /Type /Font /Subtype /Type0 /BaseFont /BrokenIdentity /Encoding /Identity-H /DescendantFonts [7 0 R] >>\n" ++
        "endobj\n";
    const descendant =
        "7 0 obj\n" ++
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /BrokenIdentity " ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 >>\n" ++
        "endobj\n";
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R /F2 6 0 R", content, &.{ font1, font2, descendant });
}

/// Generate a vertical Identity-V CID font fixture with ToUnicode for Japanese text.
pub fn generateIdentityVVerticalCjkPdf(allocator: std.mem.Allocator) ![]u8 {
    const content = "BT\n/F1 18 Tf\n300 700 Td\n<00010002> Tj\nET\n";
    const font =
        "5 0 obj\n" ++
        "<< /Type /Font /Subtype /Type0 /BaseFont /VerticalCJK /Encoding /Identity-V " ++
        "/DescendantFonts [6 0 R] /ToUnicode 7 0 R >>\n" ++
        "endobj\n";
    const descendant =
        "6 0 obj\n" ++
        "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /VerticalCJK " ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 5 >> /DW 1000 /W [1 [1000 1000]] >>\n" ++
        "endobj\n";
    const tounicode =
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CMapType 2 def
        \\/CMapName /VerticalCJKToUnicode def
        \\/WMode 1 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\2 beginbfchar
        \\<0001> <65E5>
        \\<0002> <672C>
        \\endbfchar
        \\endcmap
        \\CMapName currentdict /CMap defineresource pop
        \\end
        \\end
    ;
    const cmap_object = try std.fmt.allocPrint(
        allocator,
        "7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n",
        .{ tounicode.len, tounicode },
    );
    defer allocator.free(cmap_object);
    return generateSinglePageFontFixturePdf(allocator, "/F1 5 0 R", content, &.{ font, descendant, cmap_object });
}

/// Generate a PDF whose leaf page node omits /Type (valid but often rejected).
/// Tests Fix 2: pagetree /Type default inference.
pub fn generatePdfWithoutPageType(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page dict intentionally omits /Type /Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n");
    try writer.writeAll("<< /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n");
    try writer.writeAll("endobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = runtime.arrayListWriter(&content, allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
    try cw.print("({s}) Tj\n", .{text});
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an inline image (BI/EI block) surrounded by text.
/// Tests Fix 1: inline image skipping in the content stream lexer.
pub fn generateInlineImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Content stream: text, inline image, text
    // The inline image bytes \xAA\xBB are arbitrary binary - they won't form "EI"
    const content =
        "BT\n/F1 12 Tf\n100 700 Td\n(Before) Tj\nET\n" ++
        "BI\n/W 2 /H 2 /CS /G /BPC 8\nID\n\xAA\xBB\xCC\xDD\nEI\n" ++
        "BT\n/F1 12 Tf\n100 650 Td\n(After) Tj\nET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with superscript text at a slightly elevated Y position.
/// Tests the superscript/subscript newline-suppression fix: a Tm whose Y
/// shift is smaller than 0.7 * max(current_font, last_text_font) should not
/// emit a newline.
pub fn generateSuperscriptPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Main text at Y=700 (12pt), superscript "2" at Y=707 (7pt), then back to Y=700 (12pt).
    // Y shift = 7, threshold = max(7,12)*0.7 = 8.4 → no newline emitted.
    const content =
        "BT\n" ++
        "/F1 12 Tf\n" ++
        "1 0 0 1 100 700 Tm\n" ++
        "(Hello) Tj\n" ++
        "/F1 7 Tf\n" ++
        "1 0 0 1 110 707 Tm\n" ++
        "(2) Tj\n" ++
        "/F1 12 Tf\n" ++
        "1 0 0 1 120 700 Tm\n" ++
        "( World) Tj\n" ++
        "ET\n";

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.len});
    try writer.writeAll(content);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.print("0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1_offset, obj2_offset });
    try writer.print("{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj3_offset, obj4_offset, obj5_offset });
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "generate minimal PDF" {
    const pdf_data = try generateMinimalPdf(std.testing.allocator, "Hello World");
    defer std.testing.allocator.free(pdf_data);

    // Verify it starts with PDF header
    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));

    // Verify it ends with %%EOF
    try std.testing.expect(std.mem.endsWith(u8, pdf_data, "%%EOF\n"));

    // Verify it contains our text
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Hello World") != null);
}

test "generate multi-page PDF" {
    const pages = &[_][]const u8{ "Page One", "Page Two", "Page Three" };
    const pdf_data = try generateMultiPagePdf(std.testing.allocator, pages);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Count 3") != null);
}

test "generate CID font PDF" {
    const pdf_data = try generateCIDFontPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have Type0 font
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Type0") != null);
    // Should have ToUnicode CMap
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "beginbfchar") != null);
    // Should have Identity-H encoding
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Identity-H") != null);
}

/// Generate a PDF with incremental updates
/// Creates a base PDF, then appends an incremental update that modifies the content
pub fn generateIncrementalPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    // ===== ORIGINAL PDF =====
    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content (original text: "Original Text")
    const content1 = "BT\n/F1 12 Tf\n100 700 Td\n(Original Text) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content1.len, content1 });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Original XRef table
    const xref1_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref1_offset});

    // ===== INCREMENTAL UPDATE =====
    // Replace object 4 with new content

    // New Object 4: Updated content (now says "Updated Text")
    const content2 = "BT\n/F1 12 Tf\n100 700 Td\n(Updated Text) Tj\nET\n";
    const new_obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content2.len, content2 });

    // Incremental XRef table (only updated objects)
    const xref2_offset = pdf.items.len;
    try writer.writeAll("xref\n4 1\n"); // Only object 4 is updated
    try writer.print("{d:0>10} 00000 n \n", .{new_obj4_offset});

    try writer.writeAll("trailer\n");
    try writer.print("<< /Size 6 /Root 1 0 R /Prev {} >>\n", .{xref1_offset});
    try writer.print("startxref\n{}\n%%EOF\n", .{xref2_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a minimal PDF with an /Encrypt entry in the trailer.
/// This doesn't implement real encryption - it just has the /Encrypt key
/// so the parser detects it as encrypted.
pub fn generateEncryptedPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);

    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    // Object 4: Content stream
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Encrypted) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    // Object 5: Font
    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");

    // Object 6: Encrypt dictionary (dummy - just enough to be detected)
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Filter /Standard /V 1 /R 2 /O (dummy) /U (dummy) /P -4 >>\nendobj\n");

    // XRef table
    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    // Trailer with /Encrypt reference
    try writer.writeAll("trailer\n");
    try writer.writeAll("<< /Size 7 /Root 1 0 R /Encrypt 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate encrypted PDF" {
    const pdf_data = try generateEncryptedPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have /Encrypt in trailer
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Encrypt 6 0 R") != null);
}

test "generate incremental PDF" {
    const pdf_data = try generateIncrementalPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);

    try std.testing.expect(std.mem.startsWith(u8, pdf_data, "%PDF-1.4"));
    // Should have two %%EOF markers (original + incremental update)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, pdf_data, pos, "%%EOF")) |idx| {
        count += 1;
        pos = idx + 5;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // Should have /Prev reference
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Prev") != null);

    // Should contain both texts (though only "Updated Text" should be extracted)
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Original Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "Updated Text") != null);
}

/// Generate a PDF with metadata in the /Info dictionary
pub fn generateMetadataPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Metadata Test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Info dictionary
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Title (Test Document) /Author (Test Author) ");
    try writer.writeAll("/Subject (Test Subject) /Keywords (test, pdf, zpdf) ");
    try writer.writeAll("/Creator (TestGenerator) /Producer (zpdf) >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R /Info 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an outline (bookmarks / TOC)
pub fn generateOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog with /Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>\nendobj\n");

    // Object 2: Pages with 2 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content1 = "BT\n/F1 12 Tf\n100 700 Td\n(Chapter 1 Content) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content1.len, content1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Info
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Title (Outline Test) >>\nendobj\n");

    // Object 7: Outlines root
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>\nendobj\n");

    // Object 8: Outline item "Chapter 1" pointing to page 1 (obj 3)
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Title (Chapter 1) /Parent 7 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

    // Page 2
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 10 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content2 = "BT\n/F1 12 Tf\n100 700 Td\n(Chapter 2 Content) Tj\nET\n";
    const obj10_offset = pdf.items.len;
    try writer.print("10 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content2.len, content2 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 11\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});

    try writer.writeAll("trailer\n<< /Size 11 /Root 1 0 R /Info 6 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with link annotations
pub fn generateLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with /Annots array
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Click here) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Link annotation with URI
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [100 690 200 710] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.com) >> >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with form fields (/AcroForm)
pub fn generateFormFieldPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with AcroForm
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Form Test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Text field
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (name) /V (John Doe) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Object 7: Button field
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (submit) ");
    try writer.writeAll("/Rect [100 550 200 570] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with page labels
pub fn generatePageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with PageLabels: pages 0-1 roman lowercase, pages 2+ decimal
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /r >> 2 << /S /D >>] >> >>\nendobj\n");

    // 3 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R] /Count 3 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c1 = "BT\n/F1 12 Tf\n100 700 Td\n(Page i) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c1.len, c1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Page 2
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 7 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c2 = "BT\n/F1 12 Tf\n100 700 Td\n(Page ii) Tj\nET\n";
    const obj7_offset = pdf.items.len;
    try writer.print("7 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c2.len, c2 });

    // Page 3
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 9 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c3 = "BT\n/F1 12 Tf\n100 700 Td\n(Page 1) Tj\nET\n";
    const obj9_offset = pdf.items.len;
    try writer.print("9 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c3.len, c3 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

test "generate metadata PDF" {
    const pdf_data = try generateMetadataPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Test Document)") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Info 6 0 R") != null);
}

test "generate outline PDF" {
    const pdf_data = try generateOutlinePdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Outlines 7 0 R") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Title (Chapter 1)") != null);
}

test "generate link PDF" {
    const pdf_data = try generateLinkPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/Subtype /Link") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "https://example.com") != null);
}

test "generate form field PDF" {
    const pdf_data = try generateFormFieldPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/AcroForm") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/FT /Tx") != null);
}

test "generate page label PDF" {
    const pdf_data = try generatePageLabelPdf(std.testing.allocator);
    defer std.testing.allocator.free(pdf_data);
    try std.testing.expect(std.mem.indexOf(u8, pdf_data, "/PageLabels") != null);
}

/// Generate a PDF with a nested outline (multiple levels, siblings, GoTo actions)
pub fn generateNestedOutlinePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Object 1: Catalog with Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>\nendobj\n");

    // Object 2: Pages (2 pages)
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 10 0 R] /Count 2 >>\nendobj\n");

    // Page 1
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c1 = "BT\n/F1 12 Tf\n100 700 Td\n(Page One) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c1.len, c1 });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Outlines root
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Outlines /First 7 0 R /Last 8 0 R /Count 2 >>\nendobj\n");

    // Object 7: "Part I" — top level, has child 9, next sibling 8, dest = page 1
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Title (Part I) /Parent 6 0 R /Next 8 0 R ");
    try writer.writeAll("/First 9 0 R /Last 9 0 R /Count 1 /Dest [3 0 R /Fit] >>\nendobj\n");

    // Object 8: "Part II" — top level, via /A GoTo action, dest = page 2
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Title (Part II) /Parent 6 0 R ");
    try writer.writeAll("/A << /S /GoTo /D [10 0 R /Fit] >> >>\nendobj\n");

    // Object 9: "Section 1.1" — child of Part I, level 1, dest = page 1
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /Title (Section 1.1) /Parent 7 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

    // Page 2
    const obj10_offset = pdf.items.len;
    try writer.writeAll("10 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 11 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const c2 = "BT\n/F1 12 Tf\n100 700 Td\n(Page Two) Tj\nET\n";
    const obj11_offset = pdf.items.len;
    try writer.print("11 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ c2.len, c2 });

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 12\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj11_offset});

    try writer.writeAll("trailer\n<< /Size 12 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with multiple link annotations: URI, GoTo internal, and a non-link annotation
pub fn generateMultiLinkPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with 3 annotations: 2 links + 1 highlight (should be ignored)
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> ");
    try writer.writeAll("/Annots [6 0 R 7 0 R 8 0 R] >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Links page) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: URI link
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] ");
    try writer.writeAll("/A << /S /URI /URI (https://example.org) >> >>\nendobj\n");

    // Object 7: GoTo internal link to page 1 (obj 3)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Annot /Subtype /Link /Rect [10 40 100 60] ");
    try writer.writeAll("/A << /S /GoTo /D [3 0 R /Fit] >> >>\nendobj\n");

    // Object 8: Highlight annotation (NOT a link, should be skipped)
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /Type /Annot /Subtype /Highlight /Rect [10 70 100 90] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 9\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});

    try writer.writeAll("trailer\n<< /Size 9 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with all form field types: text, button, choice, signature
pub fn generateAllFormFieldsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 7 0 R 8 0 R 9 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(All Fields) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Text field with value
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Tx /T (email) /V (user@example.com) ");
    try writer.writeAll("/Rect [100 600 300 620] >>\nendobj\n");

    // Button field (no value)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Btn /T (ok_button) >>\nendobj\n");

    // Choice field with value
    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /FT /Ch /T (country) /V (USA) ");
    try writer.writeAll("/Rect [100 500 300 520] >>\nendobj\n");

    // Signature field (no value)
    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /FT /Sig /T (signature) >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 10\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});

    try writer.writeAll("trailer\n<< /Size 10 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate nested AcroForm fields with text, button, radio-like, and choice
/// values. Values are intentionally stored in field dictionaries rather than
/// rendered appearances so extraction must read AcroForm state.
pub fn generateRealisticWidgetFieldsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 9 0 R 10 0 R 11 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n72 720 Td\n(Profile Form) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /T (profile) /Kids [7 0 R 8 0 R] >>\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /FT /Tx /T (first_name) /V (Ada) /Rect [100 650 260 670] >>\nendobj\n");

    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /FT /Tx /T (email) /V (ada@example.com) /Rect [100 620 300 640] >>\nendobj\n");

    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /FT /Btn /T (subscribe) /V /Yes /Rect [100 590 120 610] >>\nendobj\n");

    const obj10_offset = pdf.items.len;
    try writer.writeAll("10 0 obj\n<< /FT /Btn /T (cadence) /V /Quarterly /Rect [100 560 200 580] >>\nendobj\n");

    const obj11_offset = pdf.items.len;
    try writer.writeAll("11 0 obj\n<< /FT /Ch /T (country) /V (USA) /Rect [100 530 220 550] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 12\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj11_offset});

    try writer.writeAll("trailer\n<< /Size 12 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate AcroForm fields whose terminal widget dictionaries inherit /FT and
/// /V from parent field dictionaries.
pub fn generateInheritedWidgetFieldsPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/AcroForm << /Fields [6 0 R 8 0 R 10 0 R] >> >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n72 720 Td\n(Inherited Widgets) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /FT /Btn /T (consent) /V /Yes /Kids [7 0 R] >>\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Subtype /Widget /T (agree) /Rect [100 650 120 670] >>\nendobj\n");

    const obj8_offset = pdf.items.len;
    try writer.writeAll("8 0 obj\n<< /FT /Ch /T (preferences) /Kids [9 0 R] >>\nendobj\n");

    const obj9_offset = pdf.items.len;
    try writer.writeAll("9 0 obj\n<< /Subtype /Widget /T (region) /V (EMEA) /Rect [100 620 240 640] >>\nendobj\n");

    const obj10_offset = pdf.items.len;
    try writer.writeAll("10 0 obj\n<< /FT /Tx /T (profile.phone) /V (555-0100) /Kids [11 0 R] >>\nendobj\n");

    const obj11_offset = pdf.items.len;
    try writer.writeAll("11 0 obj\n<< /Subtype /Widget /Rect [100 590 240 610] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 12\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj8_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj9_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj10_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj11_offset});

    try writer.writeAll("trailer\n<< /Size 12 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with page labels: uppercase roman, alpha, prefix, custom start
pub fn generateExtendedPageLabelPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Pages 0-1: uppercase roman (I, II)
    // Page 2: alpha lowercase starting at 1 (a)
    // Pages 3+: decimal with prefix "App-" starting at 1 (App-1)
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R ");
    try writer.writeAll("/PageLabels << /Nums [0 << /S /R >> 2 << /S /a >> 3 << /S /D /P (App-) /St 1 >>] >> >>\nendobj\n");

    // 5 pages
    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 6 0 R 8 0 R 10 0 R 12 0 R] /Count 5 >>\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Generate 5 pages (objects 3,4, 6,7, 8,9, 10,11, 12,13)
    const page_texts = [_][]const u8{ "Page I", "Page II", "Page a", "App Page 1", "App Page 2" };
    var page_offsets: [10]u64 = undefined; // pairs of (page_obj, content_obj)
    for (0..5) |pg| {
        const page_obj_num = 3 + pg * 2;
        const content_obj_num = page_obj_num + 1;
        if (page_obj_num == 5) {
            // Skip obj 5 (font) — already written. Adjust numbering.
            // Actually our numbering is 3,4, 6,7, 8,9, 10,11, 12,13 — no collision with 5.
        }

        page_offsets[pg * 2] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ", .{page_obj_num});
        try writer.print("/Contents {} 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n", .{content_obj_num});

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);
        var cw = runtime.arrayListWriter(&content, allocator);
        try cw.writeAll("BT\n/F1 12 Tf\n100 700 Td\n");
        try cw.print("({s}) Tj\n", .{page_texts[pg]});
        try cw.writeAll("ET\n");

        page_offsets[pg * 2 + 1] = pdf.items.len;
        try writer.print("{} 0 obj\n<< /Length {} >>\nstream\n", .{ content_obj_num, content.items.len });
        try writer.writeAll(content.items);
        try writer.writeAll("\nendstream\nendobj\n");
    }

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 14\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[0]}); // obj 3
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[1]}); // obj 4
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // obj 5
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[2]}); // obj 6
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[3]}); // obj 7
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[4]}); // obj 8
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[5]}); // obj 9
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[6]}); // obj 10
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[7]}); // obj 11
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[8]}); // obj 12
    try writer.print("{d:0>10} 00000 n \n", .{page_offsets[9]}); // obj 13

    try writer.writeAll("trailer\n<< /Size 14 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with an XObject image on the page
pub fn generateImagePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Page with XObject resource
    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 7 0 R >> >> >>\nendobj\n");

    // Content stream: text + cm (scale) + Do image
    const content = "BT\n/F1 12 Tf\n100 700 Td\n(Image below) Tj\nET\n200 0 0 150 100 500 cm\n/Im1 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: (unused)

    // Object 7: Image XObject (1x1 grayscale pixel)
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /XObject /Subtype /Image /Width 640 /Height 480 ");
    try writer.writeAll("/ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\n");
    try writer.writeAll("stream\n\xFF\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    // obj 6 unused — write dummy
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset}); // placeholder
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF whose only page content is one page-dominant XObject image.
pub fn generateImageOnlyPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);
    const image = try generateOcrFixtureImage(allocator);
    defer allocator.free(image.pixels);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>\nendobj\n");

    const content = "612 0 0 792 0 0 cm\n/Im1 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.print("5 0 obj\n<< /Type /XObject /Subtype /Image /Width {} /Height {} ", .{ image.width, image.height });
    try writer.print("/ColorSpace /DeviceGray /BitsPerComponent 8 /Length {} >>\n", .{image.pixels.len});
    try writer.writeAll("stream\n");
    try writer.writeAll(image.pixels);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a mixed page with native text plus a dominant scanned image region.
pub fn generateMixedNativeScanPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);
    const image = try generateOcrFixtureImage(allocator);
    defer allocator.free(image.pixels);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n72 740 Td\n(Native cover text) Tj\nET\n520 0 0 690 46 30 cm\n/Im1 Do\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Type /XObject /Subtype /Image /Width {} /Height {} ", .{ image.width, image.height });
    try writer.print("/ColorSpace /DeviceGray /BitsPerComponent 8 /Length {} >>\n", .{image.pixels.len});
    try writer.writeAll("stream\n");
    try writer.writeAll(image.pixels);
    try writer.writeAll("\nendstream\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 7\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});

    try writer.writeAll("trailer\n<< /Size 7 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

const RasterImage = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

fn generateOcrFixtureImage(allocator: std.mem.Allocator) !RasterImage {
    const width: u32 = 1200;
    const height: u32 = 1600;
    const pixels = try allocator.alloc(u8, width * height);
    @memset(pixels, 0xFF);

    drawBitmapText(pixels, width, height, "SCANNED TYPEWRITTEN", 36, 260, 8);

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn drawBitmapText(
    pixels: []u8,
    width: u32,
    height: u32,
    text: []const u8,
    start_x: u32,
    start_y: u32,
    scale: u32,
) void {
    var cursor_x = start_x;
    for (text) |byte| {
        if (byte == ' ') {
            cursor_x += 4 * scale;
            continue;
        }
        const glyph = glyph5x7(byte);
        drawGlyph(pixels, width, height, glyph, cursor_x, start_y, scale);
        cursor_x += 6 * scale;
    }
}

fn drawGlyph(
    pixels: []u8,
    width: u32,
    height: u32,
    rows: [7]u5,
    start_x: u32,
    start_y: u32,
    scale: u32,
) void {
    for (rows, 0..) |row_bits, row_index| {
        for (0..5) |col_index| {
            const shift: u3 = @intCast(4 - col_index);
            if (((row_bits >> shift) & 1) == 0) continue;
            fillRect(
                pixels,
                width,
                height,
                start_x + @as(u32, @intCast(col_index)) * scale,
                start_y + @as(u32, @intCast(row_index)) * scale,
                scale,
                scale,
                0x00,
            );
        }
    }
}

fn fillRect(
    pixels: []u8,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    rect_width: u32,
    rect_height: u32,
    value: u8,
) void {
    var row: u32 = 0;
    while (row < rect_height and y + row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < rect_width and x + col < width) : (col += 1) {
            pixels[(y + row) * width + x + col] = value;
        }
    }
}

fn glyph5x7(byte: u8) [7]u5 {
    return switch (byte) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        else => .{ 0b11111, 0b10001, 0b00110, 0b00100, 0b00110, 0b10001, 0b11111 },
    };
}

const PositionedText = struct {
    text: []const u8,
    x: u32,
    y: u32,
};

const RulingSegment = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
};

/// Generate a born-digital two-column page with header and footer furniture.
pub fn generateTwoColumnPdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Chapter 1", .x = 72, .y = 760 },
        .{ .text = "Left column first line", .x = 72, .y = 720 },
        .{ .text = "Left column second line", .x = 72, .y = 700 },
        .{ .text = "Left column third line", .x = 72, .y = 680 },
        .{ .text = "Right column first line", .x = 330, .y = 720 },
        .{ .text = "Right column second line", .x = 330, .y = 700 },
        .{ .text = "Right column third line", .x = 330, .y = 680 },
        .{ .text = "42", .x = 300, .y = 60 },
    };
    return generatePositionedTextPdf(allocator, &cells);
}

/// Generate a table-like page with repeated aligned numeric columns.
pub fn generateTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Table 1.", .x = 72, .y = 740 },
        .{ .text = "Year", .x = 80, .y = 720 },
        .{ .text = "Revenue", .x = 200, .y = 720 },
        .{ .text = "Margin", .x = 320, .y = 720 },
        .{ .text = "2019", .x = 80, .y = 700 },
        .{ .text = "100", .x = 200, .y = 700 },
        .{ .text = "20", .x = 320, .y = 700 },
        .{ .text = "2020", .x = 80, .y = 680 },
        .{ .text = "125", .x = 200, .y = 680 },
        .{ .text = "23", .x = 320, .y = 680 },
        .{ .text = "2021", .x = 80, .y = 660 },
        .{ .text = "140", .x = 200, .y = 660 },
        .{ .text = "25", .x = 320, .y = 660 },
    };
    return generatePositionedTextPdf(allocator, &cells);
}

/// Generate a harder financial table with a multi-word label cell, parenthesized
/// negatives, minus-sign negatives, and a footnote continuation row.
pub fn generateComplexFinancialTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Table 2.", .x = 72, .y = 740 },
        .{ .text = "Account", .x = 80, .y = 720 },
        .{ .text = "Revenue", .x = 180, .y = 720 },
        .{ .text = "Expense", .x = 260, .y = 720 },
        .{ .text = "Net", .x = 320, .y = 720 },
        .{ .text = "Total", .x = 80, .y = 700 },
        .{ .text = "revenue", .x = 122, .y = 700 },
        .{ .text = "1,200", .x = 180, .y = 700 },
        .{ .text = "(950)", .x = 260, .y = 700 },
        .{ .text = "250", .x = 320, .y = 700 },
        .{ .text = "Services*", .x = 80, .y = 680 },
        .{ .text = "-300", .x = 180, .y = 680 },
        .{ .text = "(450)", .x = 260, .y = 680 },
        .{ .text = "(750)", .x = 320, .y = 680 },
        .{ .text = "*", .x = 94, .y = 666 },
        .{ .text = "excludes", .x = 108, .y = 666 },
        .{ .text = "setup", .x = 168, .y = 666 },
        .{ .text = "fees", .x = 214, .y = 666 },
    };
    return generatePositionedTextPdf(allocator, &cells);
}

/// Generate a ruled financial table where cell geometry should come from
/// stroked grid lines rather than text anchors alone.
pub fn generateRuledFinancialTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Ruled Statement", .x = 72, .y = 742 },
        .{ .text = "Account", .x = 84, .y = 708 },
        .{ .text = "Q1", .x = 208, .y = 708 },
        .{ .text = "Q2", .x = 288, .y = 708 },
        .{ .text = "Cash", .x = 84, .y = 680 },
        .{ .text = "1,000", .x = 208, .y = 680 },
        .{ .text = "(200)", .x = 288, .y = 680 },
        .{ .text = "Debt", .x = 84, .y = 652 },
        .{ .text = "-50", .x = 208, .y = 652 },
        .{ .text = "(75)", .x = 288, .y = 652 },
    };
    const rulings = [_]RulingSegment{
        .{ .x0 = 72, .y0 = 724, .x1 = 372, .y1 = 724 },
        .{ .x0 = 72, .y0 = 696, .x1 = 372, .y1 = 696 },
        .{ .x0 = 72, .y0 = 668, .x1 = 372, .y1 = 668 },
        .{ .x0 = 72, .y0 = 640, .x1 = 372, .y1 = 640 },
        .{ .x0 = 72, .y0 = 640, .x1 = 72, .y1 = 724 },
        .{ .x0 = 192, .y0 = 640, .x1 = 192, .y1 = 724 },
        .{ .x0 = 272, .y0 = 640, .x1 = 272, .y1 = 724 },
        .{ .x0 = 372, .y0 = 640, .x1 = 372, .y1 = 724 },
    };
    return generatePositionedTextAndRulingsPdf(allocator, &cells, &rulings);
}

/// Generate a ruled financial table with a cell whose label is split across
/// physical text lines inside one ruled row.
pub fn generateRuledMultilineFinancialTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Multiline Statement", .x = 72, .y = 742 },
        .{ .text = "Account", .x = 84, .y = 708 },
        .{ .text = "Actual", .x = 208, .y = 708 },
        .{ .text = "Variance", .x = 288, .y = 708 },
        .{ .text = "Deferred", .x = 84, .y = 682 },
        .{ .text = "revenue", .x = 84, .y = 666 },
        .{ .text = "1,250", .x = 208, .y = 674 },
        .{ .text = "(300)", .x = 288, .y = 674 },
        .{ .text = "Support", .x = 84, .y = 636 },
        .{ .text = "400", .x = 208, .y = 636 },
        .{ .text = "-25", .x = 288, .y = 636 },
    };
    const rulings = [_]RulingSegment{
        .{ .x0 = 72, .y0 = 724, .x1 = 392, .y1 = 724 },
        .{ .x0 = 72, .y0 = 696, .x1 = 392, .y1 = 696 },
        .{ .x0 = 72, .y0 = 652, .x1 = 392, .y1 = 652 },
        .{ .x0 = 72, .y0 = 624, .x1 = 392, .y1 = 624 },
        .{ .x0 = 72, .y0 = 624, .x1 = 72, .y1 = 724 },
        .{ .x0 = 192, .y0 = 624, .x1 = 192, .y1 = 724 },
        .{ .x0 = 272, .y0 = 624, .x1 = 272, .y1 = 724 },
        .{ .x0 = 392, .y0 = 624, .x1 = 392, .y1 = 724 },
    };
    return generatePositionedTextAndRulingsPdf(allocator, &cells, &rulings);
}

/// Generate a ruled table with a merged header cell: internal vertical rules
/// begin below the first row, so the first header should report colspan=3.
pub fn generateMergedCellFinancialTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Merged Header Statement", .x = 72, .y = 742 },
        .{ .text = "Operating metrics", .x = 84, .y = 708 },
        .{ .text = "Account", .x = 84, .y = 680 },
        .{ .text = "Actual", .x = 208, .y = 680 },
        .{ .text = "Budget", .x = 288, .y = 680 },
        .{ .text = "Revenue", .x = 84, .y = 652 },
        .{ .text = "1,200", .x = 208, .y = 652 },
        .{ .text = "1,050", .x = 288, .y = 652 },
    };
    const rulings = [_]RulingSegment{
        .{ .x0 = 72, .y0 = 724, .x1 = 372, .y1 = 724 },
        .{ .x0 = 72, .y0 = 696, .x1 = 372, .y1 = 696 },
        .{ .x0 = 72, .y0 = 668, .x1 = 372, .y1 = 668 },
        .{ .x0 = 72, .y0 = 640, .x1 = 372, .y1 = 640 },
        .{ .x0 = 72, .y0 = 640, .x1 = 72, .y1 = 724 },
        .{ .x0 = 192, .y0 = 640, .x1 = 192, .y1 = 696 },
        .{ .x0 = 272, .y0 = 640, .x1 = 272, .y1 = 696 },
        .{ .x0 = 372, .y0 = 640, .x1 = 372, .y1 = 724 },
    };
    return generatePositionedTextAndRulingsPdf(allocator, &cells, &rulings);
}

/// Generate a ruled table with a row-spanning section label: the horizontal
/// rule between two detail rows is absent only in the first column.
pub fn generateRowspanFinancialTablePdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Rowspan Statement", .x = 72, .y = 742 },
        .{ .text = "Category", .x = 84, .y = 708 },
        .{ .text = "Q1", .x = 208, .y = 708 },
        .{ .text = "Q2", .x = 288, .y = 708 },
        .{ .text = "Assets", .x = 84, .y = 680 },
        .{ .text = "1,000", .x = 208, .y = 680 },
        .{ .text = "450", .x = 288, .y = 680 },
        .{ .text = "300", .x = 208, .y = 652 },
        .{ .text = "125", .x = 288, .y = 652 },
        .{ .text = "Liabilities", .x = 84, .y = 624 },
        .{ .text = "(700)", .x = 208, .y = 624 },
        .{ .text = "(200)", .x = 288, .y = 624 },
    };
    const rulings = [_]RulingSegment{
        .{ .x0 = 72, .y0 = 724, .x1 = 372, .y1 = 724 },
        .{ .x0 = 72, .y0 = 696, .x1 = 372, .y1 = 696 },
        .{ .x0 = 192, .y0 = 668, .x1 = 372, .y1 = 668 },
        .{ .x0 = 72, .y0 = 640, .x1 = 372, .y1 = 640 },
        .{ .x0 = 72, .y0 = 612, .x1 = 372, .y1 = 612 },
        .{ .x0 = 72, .y0 = 612, .x1 = 72, .y1 = 724 },
        .{ .x0 = 192, .y0 = 612, .x1 = 192, .y1 = 724 },
        .{ .x0 = 272, .y0 = 612, .x1 = 272, .y1 = 724 },
        .{ .x0 = 372, .y0 = 612, .x1 = 372, .y1 = 724 },
    };
    return generatePositionedTextAndRulingsPdf(allocator, &cells, &rulings);
}

/// Generate a two-page financial statement with repeated headers.
pub fn generateMultipageFinancialStatementPdf(allocator: std.mem.Allocator) ![]u8 {
    const page1 = [_]PositionedText{
        .{ .text = "Statement page 1", .x = 72, .y = 742 },
        .{ .text = "Account", .x = 84, .y = 708 },
        .{ .text = "Amount", .x = 220, .y = 708 },
        .{ .text = "Cash", .x = 84, .y = 680 },
        .{ .text = "1,000", .x = 220, .y = 680 },
        .{ .text = "Inventory", .x = 84, .y = 652 },
        .{ .text = "450", .x = 220, .y = 652 },
    };
    const page2 = [_]PositionedText{
        .{ .text = "Statement page 2", .x = 72, .y = 742 },
        .{ .text = "Account", .x = 84, .y = 708 },
        .{ .text = "Amount", .x = 220, .y = 708 },
        .{ .text = "Debt", .x = 84, .y = 680 },
        .{ .text = "(300)", .x = 220, .y = 680 },
        .{ .text = "Equity", .x = 84, .y = 652 },
        .{ .text = "1,150", .x = 220, .y = 652 },
    };
    const rulings = [_]RulingSegment{
        .{ .x0 = 72, .y0 = 724, .x1 = 302, .y1 = 724 },
        .{ .x0 = 72, .y0 = 696, .x1 = 302, .y1 = 696 },
        .{ .x0 = 72, .y0 = 668, .x1 = 302, .y1 = 668 },
        .{ .x0 = 72, .y0 = 640, .x1 = 302, .y1 = 640 },
        .{ .x0 = 72, .y0 = 640, .x1 = 72, .y1 = 724 },
        .{ .x0 = 192, .y0 = 640, .x1 = 192, .y1 = 724 },
        .{ .x0 = 302, .y0 = 640, .x1 = 302, .y1 = 724 },
    };
    return generateTwoPagePositionedTextAndRulingsPdf(allocator, &page1, &rulings, &page2, &rulings);
}

/// Generate a formula-like page with compact math-heavy notation.
pub fn generateFormulaPdf(allocator: std.mem.Allocator) ![]u8 {
    const cells = [_]PositionedText{
        .{ .text = "Formula 1.", .x = 72, .y = 740 },
        .{ .text = "E=mc^2++++////^^^^____", .x = 120, .y = 710 },
        .{ .text = "alpha+beta/gamma====", .x = 120, .y = 690 },
        .{ .text = "sum(x_i^2)>=delta++++", .x = 120, .y = 670 },
        .{ .text = "normal paragraph text", .x = 72, .y = 620 },
    };
    return generatePositionedTextPdf(allocator, &cells);
}

fn generatePositionedTextPdf(allocator: std.mem.Allocator, cells: []const PositionedText) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = runtime.arrayListWriter(&content, allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n");
    for (cells) |cell| {
        try cw.print("1 0 0 1 {} {} Tm\n({s}) Tj\n", .{
            cell.x,
            cell.y,
            cell.text,
        });
    }
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn generatePositionedTextAndRulingsPdf(
    allocator: std.mem.Allocator,
    cells: []const PositionedText,
    rulings: []const RulingSegment,
) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    const cw = runtime.arrayListWriter(&content, allocator);
    try appendPositionedTextContent(cw, cells);
    try appendRulingContent(cw, rulings);

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn generateTwoPagePositionedTextPdf(
    allocator: std.mem.Allocator,
    page1: []const PositionedText,
    page2: []const PositionedText,
) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>\nendobj\n");

    var content1: std.ArrayList(u8) = .empty;
    defer content1.deinit(allocator);
    const c1 = runtime.arrayListWriter(&content1, allocator);
    try appendPositionedTextContent(c1, page1);
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content1.items.len});
    try writer.writeAll(content1.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>\nendobj\n");

    var content2: std.ArrayList(u8) = .empty;
    defer content2.deinit(allocator);
    const c2 = runtime.arrayListWriter(&content2, allocator);
    try appendPositionedTextContent(c2, page2);
    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n", .{content2.items.len});
    try writer.writeAll(content2.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn generateTwoPagePositionedTextAndRulingsPdf(
    allocator: std.mem.Allocator,
    page1: []const PositionedText,
    page1_rulings: []const RulingSegment,
    page2: []const PositionedText,
    page2_rulings: []const RulingSegment,
) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>\nendobj\n");

    var content1: std.ArrayList(u8) = .empty;
    defer content1.deinit(allocator);
    const c1 = runtime.arrayListWriter(&content1, allocator);
    try appendPositionedTextContent(c1, page1);
    try appendRulingContent(c1, page1_rulings);
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content1.items.len});
    try writer.writeAll(content1.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>\nendobj\n");

    var content2: std.ArrayList(u8) = .empty;
    defer content2.deinit(allocator);
    const c2 = runtime.arrayListWriter(&content2, allocator);
    try appendPositionedTextContent(c2, page2);
    try appendRulingContent(c2, page2_rulings);
    const obj6_offset = pdf.items.len;
    try writer.print("6 0 obj\n<< /Length {} >>\nstream\n", .{content2.items.len});
    try writer.writeAll(content2.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});
    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

fn appendPositionedTextContent(writer: anytype, cells: []const PositionedText) !void {
    try writer.writeAll("BT\n/F1 12 Tf\n");
    for (cells) |cell| {
        try writer.print("1 0 0 1 {} {} Tm\n(", .{ cell.x, cell.y });
        try writePdfStringEscaped(writer, cell.text);
        try writer.writeAll(") Tj\n");
    }
    try writer.writeAll("ET\n");
}

fn appendRulingContent(writer: anytype, rulings: []const RulingSegment) !void {
    try writer.writeAll("1 w\n");
    for (rulings) |line| {
        try writer.print("{} {} m {} {} l\nS\n", .{ line.x0, line.y0, line.x1, line.y1 });
    }
}

fn writePdfStringEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '(', ')', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            else => try writer.writeByte(byte),
        }
    }
}

/// Generate a page with aligned numeric columns and formula-heavy notation.
pub fn generateTableFormulaPdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var cw = runtime.arrayListWriter(&content, allocator);
    try cw.writeAll("BT\n/F1 12 Tf\n");
    const cells = [_]struct { text: []const u8, x: u32, y: u32 }{
        .{ .text = "2019", .x = 80, .y = 720 },
        .{ .text = "100", .x = 200, .y = 720 },
        .{ .text = "2020", .x = 80, .y = 700 },
        .{ .text = "125", .x = 200, .y = 700 },
        .{ .text = "2021", .x = 80, .y = 680 },
        .{ .text = "140", .x = 200, .y = 680 },
        .{ .text = "2022", .x = 80, .y = 660 },
        .{ .text = "155", .x = 200, .y = 660 },
        .{ .text = "E=mc^2++++////^^^^____", .x = 320, .y = 720 },
        .{ .text = "alpha+beta/gamma====", .x = 320, .y = 700 },
        .{ .text = "sum(x_i^2)>=delta++++", .x = 320, .y = 680 },
    };
    for (cells) |cell| {
        try cw.print("1 0 0 1 {} {} Tm\n({s}) Tj\n", .{ cell.x, cell.y, cell.text });
    }
    try cw.writeAll("ET\n");

    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n", .{content.items.len});
    try writer.writeAll(content.items);
    try writer.writeAll("\nendstream\nendobj\n");

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 6\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});

    try writer.writeAll("trailer\n<< /Size 6 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}

/// Generate a PDF with UTF-16BE encoded metadata and outline title
pub fn generateUtf16BePdf(allocator: std.mem.Allocator) ![]u8 {
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);

    try writer.writeAll("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

    // Catalog with Outlines
    const obj1_offset = pdf.items.len;
    try writer.writeAll("1 0 obj\n<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>\nendobj\n");

    const obj2_offset = pdf.items.len;
    try writer.writeAll("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    const obj3_offset = pdf.items.len;
    try writer.writeAll("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ");
    try writer.writeAll("/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n");

    const content = "BT\n/F1 12 Tf\n100 700 Td\n(UTF16 test) Tj\nET\n";
    const obj4_offset = pdf.items.len;
    try writer.print("4 0 obj\n<< /Length {} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });

    const obj5_offset = pdf.items.len;
    try writer.writeAll("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ");
    try writer.writeAll("/Encoding /WinAnsiEncoding >>\nendobj\n");

    // Object 6: Outlines root
    const obj6_offset = pdf.items.len;
    try writer.writeAll("6 0 obj\n<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>\nendobj\n");

    // Object 7: Outline item with UTF-16BE title "Café" = FE FF 0043 0061 0066 00E9
    const obj7_offset = pdf.items.len;
    try writer.writeAll("7 0 obj\n<< /Title <FEFF00430061006600E9> /Parent 6 0 R /Dest [3 0 R /Fit] >>\nendobj\n");

    const xref_offset = pdf.items.len;
    try writer.writeAll("xref\n0 8\n");
    try writer.writeAll("0000000000 65535 f \n");
    try writer.print("{d:0>10} 00000 n \n", .{obj1_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj2_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj3_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj4_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj5_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj6_offset});
    try writer.print("{d:0>10} 00000 n \n", .{obj7_offset});

    try writer.writeAll("trailer\n<< /Size 8 /Root 1 0 R >>\n");
    try writer.print("startxref\n{}\n%%EOF\n", .{xref_offset});

    return pdf.toOwnedSlice(allocator);
}
