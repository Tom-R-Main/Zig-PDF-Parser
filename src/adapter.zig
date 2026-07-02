//! Neutral host adapter surface for adaptive extraction.
//!
//! This module does not assume a particular host application. Callers provide
//! an optional external source id, an already-open document, and a writer.

const std = @import("std");
const adaptive = @import("adaptive.zig");
const runtime = @import("runtime.zig");
const schema = @import("schema.zig");
const specialist_protocol = @import("specialist_protocol.zig");
const stream = @import("stream.zig");

pub const AdaptiveAdapterFormat = enum {
    json,
    artifact_jsonl,
    stream_jsonl,
    trace_json,
};

pub const AdaptiveAdapterOptions = struct {
    document_id: ?[]const u8 = null,
    source_id: ?[]const u8 = null,
    format: AdaptiveAdapterFormat = .artifact_jsonl,
    adaptive_options: adaptive.ExtractOptions = .{},
    include_debug_asset_refs: bool = true,
    debug_assets_dir: ?[]const u8 = null,
    emit_specialist_requests_path: ?[]const u8 = null,
    specialist_config_path: ?[]const u8 = null,
};

pub const AdaptiveAdapterSummary = struct {
    format: AdaptiveAdapterFormat,
    streamed: bool = false,
    stream_summary: ?stream.StreamingSummary = null,
};

pub fn extractAdaptive(
    allocator: std.mem.Allocator,
    document: anytype,
    writer: anytype,
    options: AdaptiveAdapterOptions,
) !AdaptiveAdapterSummary {
    const input_sha256 = try schema.sha256Hex(allocator, document.data);
    defer allocator.free(input_sha256);

    const parser_errors = try allocator.alloc(schema.ManifestDiagnostic, document.errors.items.len);
    defer allocator.free(parser_errors);
    for (document.errors.items, 0..) |parse_error, index| {
        parser_errors[index] = .{
            .code = @tagName(parse_error.kind),
            .message = parse_error.message,
            .offset = parse_error.offset,
        };
    }
    const encryption_info = document.encryptionInfo();
    var encryption_warning_storage: [2]schema.ManifestDiagnostic = undefined;
    const encryption_warnings = schema.collectEncryptionWarnings(
        &encryption_warning_storage,
        encryption_info,
        document.error_config.respect_permissions,
    );

    const render_options = schema.RenderOptions{
        .document_id = options.document_id orelse document.source_path orelse "document",
        .source_id = options.source_id,
        .input_sha256 = input_sha256,
        .source_path = document.source_path,
        .page_count = document.pageCount(),
        .encrypted = document.isEncrypted(),
        .encryption_info = encryption_info,
        .corrupt = document.errors.items.len > 0,
        .warnings = encryption_warnings,
        .errors = parser_errors,
        .include_debug_asset_refs = options.include_debug_asset_refs,
        .debug_assets_dir = options.debug_assets_dir,
        .specialist_config_path = options.specialist_config_path,
    };

    if (options.format == .stream_jsonl) {
        if (options.emit_specialist_requests_path) |requests_path| {
            var request_result = try adaptive.extractDocument(allocator, document, options.adaptive_options);
            defer request_result.deinit();
            try writeSpecialistRequestsFile(allocator, requests_path, &request_result, render_options);
        }
        const summary = try document.extractAdaptiveStreaming(allocator, writer, .{
            .adaptive_options = options.adaptive_options,
            .schema_options = render_options,
            .include_debug_asset_refs = options.include_debug_asset_refs,
        });
        return .{ .format = options.format, .streamed = true, .stream_summary = summary };
    }

    var result = try adaptive.extractDocument(allocator, document, options.adaptive_options);
    defer result.deinit();

    if (options.emit_specialist_requests_path) |requests_path| {
        try writeSpecialistRequestsFile(allocator, requests_path, &result, render_options);
    }

    const rendered = switch (options.format) {
        .json => try schema.renderArtifactJson(allocator, &result, render_options),
        .artifact_jsonl => try schema.renderArtifactJsonl(allocator, &result, render_options),
        .trace_json => try schema.renderTraceJsonWithOptions(allocator, &result, render_options),
        .stream_jsonl => unreachable,
    };
    defer allocator.free(rendered);

    try writer.writeAll(rendered);
    return .{ .format = options.format };
}

fn writeSpecialistRequestsFile(allocator: std.mem.Allocator, path: []const u8, result: anytype, options: schema.RenderOptions) !void {
    const rendered = try specialist_protocol.renderRequestsJsonl(allocator, result, .{
        .document_id = options.document_id,
        .source_id = options.source_id,
        .input_sha256 = options.input_sha256,
    });
    defer allocator.free(rendered);

    const file = try runtime.createFileCwd(path);
    defer runtime.closeFile(file);
    try runtime.writeAllFile(file, rendered);
}

pub fn formatFromName(name: []const u8) ?AdaptiveAdapterFormat {
    if (std.mem.eql(u8, name, "json")) return .json;
    if (std.mem.eql(u8, name, "artifact-jsonl") or std.mem.eql(u8, name, "artifact_jsonl")) return .artifact_jsonl;
    if (std.mem.eql(u8, name, "stream-jsonl") or std.mem.eql(u8, name, "stream_jsonl")) return .stream_jsonl;
    if (std.mem.eql(u8, name, "trace-json") or std.mem.eql(u8, name, "trace_json")) return .trace_json;
    return null;
}

test "adapter parses neutral output formats" {
    try std.testing.expectEqual(AdaptiveAdapterFormat.json, formatFromName("json").?);
    try std.testing.expectEqual(AdaptiveAdapterFormat.artifact_jsonl, formatFromName("artifact-jsonl").?);
    try std.testing.expectEqual(AdaptiveAdapterFormat.stream_jsonl, formatFromName("stream_jsonl").?);
    try std.testing.expectEqual(AdaptiveAdapterFormat.trace_json, formatFromName("trace-json").?);
    try std.testing.expect(formatFromName("markdown") == null);
}
