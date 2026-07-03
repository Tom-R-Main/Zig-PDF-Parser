//! Structural PDF diagnostics and check report rendering.
//!
//! This module is intentionally independent of the adaptive artifact schema.
//! It describes parser recovery evidence for xref, object, and page-tree
//! handling so the CLI can compare structural behavior against qpdf.

const std = @import("std");

pub const Severity = enum {
    info,
    warning,
    error_,

    pub fn name(self: Severity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .error_ => "error",
        };
    }
};

pub const Stage = enum {
    header,
    xref,
    object,
    object_stream,
    page_tree,
    encryption,

    pub fn name(self: Stage) []const u8 {
        return switch (self) {
            .header => "header",
            .xref => "xref",
            .object => "object",
            .object_stream => "object_stream",
            .page_tree => "page_tree",
            .encryption => "encryption",
        };
    }
};

pub const Action = enum {
    none,
    recovered,
    skipped,
    failed,

    pub fn name(self: Action) []const u8 {
        return switch (self) {
            .none => "none",
            .recovered => "recovered",
            .skipped => "skipped",
            .failed => "failed",
        };
    }
};

pub const Code = enum {
    invalid_header,
    missing_startxref,
    invalid_startxref,
    recovered_xref_offset,
    invalid_xref_offset,
    invalid_prev_offset,
    prev_cycle,
    prev_chain_too_deep,
    duplicate_xref_entry,
    truncated_xref_row,
    malformed_xref_stream_row,
    unknown_xref_stream_entry,
    hybrid_xref_stream,
    wrong_stream_length,
    recovered_stream_length,
    malformed_object_stream,
    missing_object,
    page_tree_missing_type,
    page_tree_wrong_count,
    page_tree_missing_kids,
    page_tree_bad_kid,
    page_tree_circular_reference,
    page_tree_missing_box,
    page_tree_recovered_child,

    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .invalid_header => "invalid_header",
            .missing_startxref => "missing_startxref",
            .invalid_startxref => "invalid_startxref",
            .recovered_xref_offset => "recovered_xref_offset",
            .invalid_xref_offset => "invalid_xref_offset",
            .invalid_prev_offset => "invalid_prev_offset",
            .prev_cycle => "prev_cycle",
            .prev_chain_too_deep => "prev_chain_too_deep",
            .duplicate_xref_entry => "duplicate_xref_entry",
            .truncated_xref_row => "truncated_xref_row",
            .malformed_xref_stream_row => "malformed_xref_stream_row",
            .unknown_xref_stream_entry => "unknown_xref_stream_entry",
            .hybrid_xref_stream => "hybrid_xref_stream",
            .wrong_stream_length => "wrong_stream_length",
            .recovered_stream_length => "recovered_stream_length",
            .malformed_object_stream => "malformed_object_stream",
            .missing_object => "missing_object",
            .page_tree_missing_type => "page_tree_missing_type",
            .page_tree_wrong_count => "page_tree_wrong_count",
            .page_tree_missing_kids => "page_tree_missing_kids",
            .page_tree_bad_kid => "page_tree_bad_kid",
            .page_tree_circular_reference => "page_tree_circular_reference",
            .page_tree_missing_box => "page_tree_missing_box",
            .page_tree_recovered_child => "page_tree_recovered_child",
        };
    }
};

pub const ObjRef = struct {
    num: u32,
    gen: u16 = 0,
};

pub const Diagnostic = struct {
    code: Code,
    severity: Severity,
    stage: Stage,
    offset: ?u64 = null,
    object_ref: ?ObjRef = null,
    action: Action = .none,
    message: []const u8,
};

pub const Status = enum {
    ok,
    recovered,
    failed,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .recovered => "recovered",
            .failed => "failed",
        };
    }
};

pub const Summary = struct {
    xref_entries: usize = 0,
    xref_free_entries: usize = 0,
    xref_in_use_entries: usize = 0,
    xref_compressed_entries: usize = 0,
    object_stream_entries: usize = 0,
    trailer_size: ?i64 = null,
    has_root: bool = false,
    has_encrypt: bool = false,
};

pub fn appendDiagnostic(allocator: std.mem.Allocator, list: ?*std.ArrayList(Diagnostic), diagnostic: Diagnostic) void {
    if (list) |diagnostics| {
        diagnostics.append(allocator, diagnostic) catch {};
    }
}

pub fn statusFromDiagnostics(diagnostics: []const Diagnostic) Status {
    var recovered = false;
    for (diagnostics) |diagnostic| {
        if (diagnostic.action == .failed or diagnostic.severity == .error_) return .failed;
        if (diagnostic.action == .recovered or diagnostic.action == .skipped or diagnostic.severity == .warning) recovered = true;
    }
    return if (recovered) .recovered else .ok;
}

pub fn renderCheckJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    document_id: []const u8,
    input_sha256: []const u8,
    parser_version: []const u8,
    page_count: usize,
    encrypted: bool,
    summary: Summary,
    diagnostics: []const Diagnostic,
) !void {
    const status = statusFromDiagnostics(diagnostics);
    try writer.writeAll("{\"schema_name\":\"structural_check\",\"schema_version\":\"0.1.0\",\"record_type\":\"structural_check\"");
    try writer.writeAll(",\"document_id\":\"");
    try writeJsonEscaped(writer, document_id);
    try writer.writeAll("\",\"input_sha256\":\"");
    try writer.writeAll(input_sha256);
    try writer.writeAll("\",\"parser_version\":\"");
    try writeJsonEscaped(writer, parser_version);
    try writer.writeAll("\",\"status\":\"");
    try writer.writeAll(status.name());
    try writer.print("\",\"page_count\":{},\"encrypted\":{}", .{ page_count, encrypted });
    try writer.writeAll(",\"xref_summary\":{");
    try writer.print("\"entries\":{},\"free_entries\":{},\"in_use_entries\":{},\"compressed_entries\":{},\"object_stream_entries\":{}", .{
        summary.xref_entries,
        summary.xref_free_entries,
        summary.xref_in_use_entries,
        summary.xref_compressed_entries,
        summary.object_stream_entries,
    });
    try writer.writeAll(",\"trailer_size\":");
    if (summary.trailer_size) |size| try writer.print("{}", .{size}) else try writer.writeAll("null");
    try writer.print(",\"has_root\":{},\"has_encrypt\":{}", .{ summary.has_root, summary.has_encrypt });
    try writer.writeAll("},\"diagnostic_count\":");
    try writer.print("{}", .{diagnostics.len});
    try writer.writeAll(",\"diagnostics\":[");
    for (diagnostics, 0..) |diagnostic, index| {
        if (index > 0) try writer.writeByte(',');
        try writeDiagnosticJson(writer, diagnostic);
    }
    try writer.writeAll("]}");
    _ = allocator;
}

fn writeDiagnosticJson(writer: anytype, diagnostic: Diagnostic) !void {
    try writer.writeAll("{\"code\":\"");
    try writer.writeAll(diagnostic.code.name());
    try writer.writeAll("\",\"severity\":\"");
    try writer.writeAll(diagnostic.severity.name());
    try writer.writeAll("\",\"stage\":\"");
    try writer.writeAll(diagnostic.stage.name());
    try writer.writeAll("\",\"offset\":");
    if (diagnostic.offset) |offset| try writer.print("{}", .{offset}) else try writer.writeAll("null");
    try writer.writeAll(",\"object_ref\":");
    if (diagnostic.object_ref) |ref| {
        try writer.print("{{\"num\":{},\"gen\":{}}}", .{ ref.num, ref.gen });
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"action\":\"");
    try writer.writeAll(diagnostic.action.name());
    try writer.writeAll("\",\"message\":\"");
    try writeJsonEscaped(writer, diagnostic.message);
    try writer.writeAll("\"}");
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    var clean_start: usize = 0;
    for (text, 0..) |byte, index| {
        if (!jsonNeedsEscape(byte)) continue;
        if (index > clean_start) try writer.writeAll(text[clean_start..index]);
        try writeJsonEscapedByte(writer, byte);
        clean_start = index + 1;
    }
    if (clean_start < text.len) try writer.writeAll(text[clean_start..]);
}

fn jsonNeedsEscape(byte: u8) bool {
    return byte < 0x20 or byte == '"' or byte == '\\';
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\x08' => try writer.writeAll("\\b"),
        '\x0c' => try writer.writeAll("\\f"),
        else => if (byte < 0x20) {
            try writer.print("\\u00{X:0>2}", .{byte});
        } else {
            try writer.writeByte(byte);
        },
    }
}

test "structural status follows diagnostics" {
    try std.testing.expectEqual(Status.ok, statusFromDiagnostics(&.{}));
    try std.testing.expectEqual(Status.recovered, statusFromDiagnostics(&.{.{
        .code = .missing_startxref,
        .severity = .warning,
        .stage = .xref,
        .action = .recovered,
        .message = "Recovered",
    }}));
    try std.testing.expectEqual(Status.failed, statusFromDiagnostics(&.{.{
        .code = .invalid_xref_offset,
        .severity = .error_,
        .stage = .xref,
        .action = .failed,
        .message = "Failed",
    }}));
}
