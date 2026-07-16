//! Extraction-layer diagnostics for distinguishing traversal, content-stream,
//! text-operator, font-decoding, and final-output failures.

const std = @import("std");
const encoding = @import("encoding.zig");
const runtime = @import("runtime.zig");

pub const mapping_source_count = @typeInfo(encoding.MappingSource).@"enum".fields.len;

pub const FontReport = struct {
    font_object: ?u32 = null,
    resource_name: []const u8 = "",
    subtype: []const u8 = "unknown",
    base_font: []const u8 = "",
    encoding_cmap_name: []const u8 = "",
    cid_registry: []const u8 = "",
    cid_ordering: []const u8 = "",
    cid_supplement: i32 = 0,
    to_unicode_present: bool = false,
    to_unicode_mapped_codes: usize = 0,
    embedded_font_type: []const u8 = "none",
    cid_to_gid_map_type: []const u8 = "identity",
    glyph_count: usize = 0,
    mapping_counts: [mapping_source_count]usize = @splat(0),

    pub fn count(self: FontReport, source: encoding.MappingSource) usize {
        return self.mapping_counts[@intFromEnum(source)];
    }

    pub fn toUnicodeGlyphCoverage(self: FontReport) f64 {
        if (self.glyph_count == 0) return 0;
        return @as(f64, @floatFromInt(self.count(.explicit_to_unicode))) / @as(f64, @floatFromInt(self.glyph_count));
    }
};

pub const Status = enum {
    ok,
    no_text,
    suspect_unicode,
    incomplete,
    no_pages,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .no_text => "no_text",
            .suspect_unicode => "suspect_unicode",
            .incomplete => "incomplete",
            .no_pages => "no_pages",
        };
    }
};

pub const Report = struct {
    allocator: ?std.mem.Allocator = null,
    fonts: []const FontReport = &.{},
    document_page_count: usize = 0,
    selected_page_count: usize = 0,
    pages_scanned: usize = 0,
    pages_with_content: usize = 0,
    pages_without_content: usize = 0,
    content_stream_errors: usize = 0,
    decoded_content_bytes: usize = 0,
    operator_scan_errors: usize = 0,
    operator_count: usize = 0,
    text_object_count: usize = 0,
    text_show_operator_count: usize = 0,
    text_operand_bytes: usize = 0,
    span_count: usize = 0,
    glyph_count: usize = 0,
    mapped_glyph_count: usize = 0,
    unmapped_glyph_count: usize = 0,
    page_extraction_errors: usize = 0,
    pages_with_output: usize = 0,
    output_bytes: usize = 0,
    output_codepoints: usize = 0,
    invalid_utf8_pages: usize = 0,
    pages_with_text_operators_without_glyphs: usize = 0,
    form_xobjects_decoded: usize = 0,
    selection_inventory_codepoints: usize = 0,
    selection_candidate_codepoints: usize = 0,
    selection_missing_codepoints: usize = 0,
    selection_extra_codepoints: usize = 0,
    pages_selected_structured: usize = 0,
    pages_selected_table: usize = 0,
    pages_selected_full_context: usize = 0,
    pages_selected_legacy_fallback: usize = 0,

    pub fn deinit(self: *Report) void {
        if (self.fonts.len > 0) {
            for (self.fonts) |font| self.allocator.?.free(font.resource_name);
            self.allocator.?.free(self.fonts);
        }
        self.fonts = &.{};
    }

    pub fn status(self: Report) Status {
        if (self.document_page_count == 0) return .no_pages;
        if (self.content_stream_errors > 0 or
            self.operator_scan_errors > 0 or
            self.page_extraction_errors > 0 or
            self.pages_with_text_operators_without_glyphs > 0)
        {
            return .incomplete;
        }
        if (self.invalid_utf8_pages > 0 or self.unicodeMappingFailureRatio() >= 0.01) return .suspect_unicode;
        if (self.text_show_operator_count == 0 and self.output_bytes == 0) return .no_text;
        return .ok;
    }

    pub fn unicodeMappingFailureRatio(self: Report) f64 {
        const decoded_glyphs = self.mapped_glyph_count + self.unmapped_glyph_count;
        if (decoded_glyphs == 0) return 0;
        return @as(f64, @floatFromInt(self.unmapped_glyph_count)) / @as(f64, @floatFromInt(decoded_glyphs));
    }

    pub fn candidateCoverageRatio(self: Report) f64 {
        if (self.selection_inventory_codepoints == 0) return 1;
        const covered = self.selection_inventory_codepoints -| self.selection_missing_codepoints;
        return @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(self.selection_inventory_codepoints));
    }
};

pub fn renderJson(writer: anytype, document_id: []const u8, report: Report) !void {
    try writer.writeAll("{\"schema_name\":\"extraction_diagnostics\",\"schema_version\":\"0.3.0\",\"record_type\":\"extraction_diagnostics\",\"source_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeAll("\",\"provenance\":{\"source_kind\":\"native_pdf\",\"operation\":\"inspect_extraction\"}");
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeAll("\",\"status\":\"");
    try writer.writeAll(report.status().name());
    try writer.print("\",\"document_page_count\":{},\"selected_page_count\":{},\"pages_scanned\":{}", .{
        report.document_page_count,
        report.selected_page_count,
        report.pages_scanned,
    });
    try writer.print(",\"content\":{{\"pages_with_content\":{},\"pages_without_content\":{},\"content_stream_errors\":{},\"decoded_content_bytes\":{}}}", .{
        report.pages_with_content,
        report.pages_without_content,
        report.content_stream_errors,
        report.decoded_content_bytes,
    });
    try writer.print(",\"operators\":{{\"scan_errors\":{},\"total\":{},\"text_objects\":{},\"text_show\":{},\"text_operand_bytes\":{}}}", .{
        report.operator_scan_errors,
        report.operator_count,
        report.text_object_count,
        report.text_show_operator_count,
        report.text_operand_bytes,
    });
    try writer.print(",\"decoding\":{{\"spans\":{},\"glyphs\":{},\"mapped_glyphs\":{},\"unmapped_glyphs\":{}}}", .{
        report.span_count,
        report.glyph_count,
        report.mapped_glyph_count,
        report.unmapped_glyph_count,
    });
    try writer.print(",\"output\":{{\"page_extraction_errors\":{},\"pages_with_output\":{},\"bytes\":{},\"codepoints\":{},\"invalid_utf8_pages\":{}}}", .{
        report.page_extraction_errors,
        report.pages_with_output,
        report.output_bytes,
        report.output_codepoints,
        report.invalid_utf8_pages,
    });
    try writer.print(",\"selection\":{{\"form_xobjects_decoded\":{},\"inventory_codepoints\":{},\"candidate_codepoints\":{},\"missing_codepoints\":{},\"extra_codepoints\":{},\"candidate_coverage_ratio\":{d:.6},\"pages_selected\":{{\"structured\":{},\"table\":{},\"full_context\":{},\"legacy_fallback\":{}}}}}", .{
        report.form_xobjects_decoded,
        report.selection_inventory_codepoints,
        report.selection_candidate_codepoints,
        report.selection_missing_codepoints,
        report.selection_extra_codepoints,
        report.candidateCoverageRatio(),
        report.pages_selected_structured,
        report.pages_selected_table,
        report.pages_selected_full_context,
        report.pages_selected_legacy_fallback,
    });
    try writer.print(",\"signals\":{{\"no_pages_discovered\":{},\"text_operators_without_glyphs\":{},\"unicode_mapping_failures\":{},\"unicode_mapping_failure_ratio\":{d:.6}}}", .{
        report.document_page_count == 0,
        report.pages_with_text_operators_without_glyphs,
        report.unmapped_glyph_count,
        report.unicodeMappingFailureRatio(),
    });
    try writer.writeAll(",\"fonts\":[");
    for (report.fonts, 0..) |font, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"font_object\":");
        if (font.font_object) |object_num| try writer.print("{}", .{object_num}) else try writer.writeAll("null");
        try writer.writeAll(",\"resource_name\":\"");
        try writeJsonEscaped(writer, font.resource_name);
        try writer.writeAll("\",\"subtype\":\"");
        try writeJsonEscaped(writer, font.subtype);
        try writer.writeAll("\",\"base_font\":\"");
        try writeJsonEscaped(writer, font.base_font);
        try writer.writeAll("\",\"encoding_cmap_name\":\"");
        try writeJsonEscaped(writer, font.encoding_cmap_name);
        try writer.writeAll("\",\"cid_system_info\":{\"registry\":\"");
        try writeJsonEscaped(writer, font.cid_registry);
        try writer.writeAll("\",\"ordering\":\"");
        try writeJsonEscaped(writer, font.cid_ordering);
        try writer.print("\",\"supplement\":{}}}", .{font.cid_supplement});
        try writer.print(",\"to_unicode\":{{\"present\":{},\"mapped_codes\":{},\"glyph_coverage\":{d:.6}}}", .{
            font.to_unicode_present,
            font.to_unicode_mapped_codes,
            font.toUnicodeGlyphCoverage(),
        });
        try writer.writeAll(",\"embedded_font_type\":\"");
        try writeJsonEscaped(writer, font.embedded_font_type);
        try writer.writeAll("\",\"cid_to_gid_map_type\":\"");
        try writeJsonEscaped(writer, font.cid_to_gid_map_type);
        try writer.print("\",\"glyph_count\":{},\"mapping_sources\":{{", .{font.glyph_count});
        inline for (@typeInfo(encoding.MappingSource).@"enum".fields, 0..) |field, source_index| {
            if (source_index > 0) try writer.writeByte(',');
            try writer.print("\"{s}\":{}", .{ field.name, font.mapping_counts[source_index] });
        }
        try writer.writeAll("}}");
    }
    try writer.writeAll("]}");
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20)
                try writer.print("\\u00{X:0>2}", .{byte})
            else
                try writer.writeByte(byte),
        }
    }
}

test "status distinguishes missing pages unicode failures and empty documents" {
    try std.testing.expectEqual(Status.no_pages, (Report{}).status());
    try std.testing.expectEqual(Status.no_text, (Report{ .document_page_count = 1 }).status());
    try std.testing.expectEqual(Status.suspect_unicode, (Report{ .document_page_count = 1, .unmapped_glyph_count = 1 }).status());
    try std.testing.expectEqual(Status.incomplete, (Report{ .document_page_count = 1, .pages_with_text_operators_without_glyphs = 1 }).status());
    try std.testing.expectEqual(Status.ok, (Report{ .document_page_count = 1, .text_show_operator_count = 1, .output_bytes = 1 }).status());
}

test "diagnostic JSON includes per-font mapping provenance" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var font = FontReport{
        .font_object = 1111,
        .resource_name = "T1_6",
        .subtype = "Type1",
        .base_font = "Subset+Symbol",
        .to_unicode_present = false,
        .embedded_font_type = "Type1C",
        .glyph_count = 8,
    };
    font.mapping_counts[@intFromEnum(encoding.MappingSource.glyph_name)] = 8;
    try renderJson(runtime.arrayListWriter(&output, std.testing.allocator), "fixture.pdf", .{
        .document_page_count = 1,
        .selected_page_count = 1,
        .pages_scanned = 1,
        .glyph_count = 8,
        .mapped_glyph_count = 8,
        .output_bytes = 12,
        .form_xobjects_decoded = 2,
        .selection_inventory_codepoints = 10,
        .selection_candidate_codepoints = 8,
        .selection_missing_codepoints = 2,
        .pages_selected_full_context = 1,
        .fonts = &.{font},
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0.3.0", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings("fixture.pdf", parsed.value.object.get("source_id").?.string);
    const rendered_font = parsed.value.object.get("fonts").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 1111), rendered_font.get("font_object").?.integer);
    try std.testing.expectEqual(@as(i64, 8), rendered_font.get("mapping_sources").?.object.get("glyph_name").?.integer);
    const selection = parsed.value.object.get("selection").?.object;
    try std.testing.expectEqual(@as(i64, 2), selection.get("form_xobjects_decoded").?.integer);
    try std.testing.expectEqual(@as(i64, 2), selection.get("missing_codepoints").?.integer);
    try std.testing.expectEqual(@as(i64, 1), selection.get("pages_selected").?.object.get("full_context").?.integer);
}
