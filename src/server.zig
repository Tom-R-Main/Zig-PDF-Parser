//! Stateless HTTP wrapper for host applications.
//!
//! The server is intentionally thin: request bodies name an input file and the
//! response is produced by the same adaptive adapter used by the CLI and C ABI.

const std = @import("std");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");

pub const ServeOptions = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_body_bytes: usize = 1024 * 1024,
};

const ExtractRequest = struct {
    input_path: []const u8,
    source_id: ?[]const u8 = null,
    document_id: ?[]const u8 = null,
    format: zpdf.AdaptiveAdapterFormat = .stream_jsonl,
    page_start: ?usize = null,
    page_end: ?usize = null,
    strict: bool = false,
    permissive: bool = true,
    password: ?[]const u8 = null,
    password_file: ?[]const u8 = null,
    debug_assets_dir: ?[]const u8 = null,
    specialist_config_path: ?[]const u8 = null,
};

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var options = ServeOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            options.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPort;
            options.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--max-body-bytes")) {
            i += 1;
            if (i >= args.len) return error.MissingBodyLimit;
            options.max_body_bytes = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            std.debug.print("Unknown serve option: {s}\n", .{arg});
            return;
        }
    }

    try run(allocator, options);
}

pub fn run(allocator: std.mem.Allocator, options: ServeOptions) !void {
    const address = try parseListenAddress(options.host, options.port);
    var listener = try std.Io.net.IpAddress.listen(&address, runtime.current(), .{ .reuse_address = true });
    defer listener.deinit(runtime.current());

    std.debug.print("pdf-parser listening on {s}:{d}\n", .{ options.host, options.port });
    while (true) {
        const stream = listener.accept(runtime.current()) catch |err| {
            std.debug.print("accept failed: {}\n", .{err});
            continue;
        };
        defer stream.close(runtime.current());
        handleConnection(allocator, stream, options) catch |err| {
            std.debug.print("connection failed: {}\n", .{err});
        };
    }
}

fn parseListenAddress(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.mem.eql(u8, host, "0.0.0.0")) return .{ .ip4 = std.Io.net.Ip4Address.unspecified(port) };
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost")) return .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    return std.Io.net.IpAddress.parse(host, port);
}

fn handleConnection(allocator: std.mem.Allocator, stream: std.Io.net.Stream, options: ServeOptions) !void {
    var read_buffer: [16 * 1024]u8 = undefined;
    var write_buffer: [16 * 1024]u8 = undefined;
    var net_reader = stream.reader(runtime.current(), &read_buffer);
    var net_writer = stream.writer(runtime.current(), &write_buffer);
    var http_server = std.http.Server.init(&net_reader.interface, &net_writer.interface);

    var request = http_server.receiveHead() catch return;
    try handleRequest(allocator, &request, options);
}

fn handleRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request, options: ServeOptions) !void {
    const target = request.head.target;
    if (request.head.method == .GET and std.mem.eql(u8, target, "/healthz")) {
        try respondJson(request, .ok, "{\"status\":\"ok\"}\n");
        return;
    }
    if (request.head.method == .GET and std.mem.eql(u8, target, "/v1/capabilities")) {
        const body = try renderCapabilities(allocator);
        defer allocator.free(body);
        try respondJson(request, .ok, body);
        return;
    }
    if (request.head.method == .POST and std.mem.eql(u8, target, "/v1/extract-adaptive")) {
        const response = extractFromHttpRequest(allocator, request, options.max_body_bytes) catch |err| {
            const body = try errorJson(allocator, "extract_failed", @errorName(err));
            defer allocator.free(body);
            try respondJson(request, .bad_request, body);
            return;
        };
        defer allocator.free(response.bytes);
        try request.respond(response.bytes, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = response.content_type }},
        });
        return;
    }

    try respondJson(request, .not_found, "{\"error\":\"not_found\"}\n");
}

const HttpExtractResponse = struct {
    bytes: []u8,
    content_type: []const u8,
};

fn extractFromHttpRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request, max_body_bytes: usize) !HttpExtractResponse {
    var body_buffer: [4096]u8 = undefined;
    var body_reader = request.readerExpectNone(&body_buffer);
    const body = try body_reader.allocRemaining(allocator, .limited(max_body_bytes));
    defer allocator.free(body);
    return extractFromRequestJson(allocator, body);
}

pub fn extractFromRequestJson(allocator: std.mem.Allocator, body: []const u8) !HttpExtractResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const request = try parseExtractRequest(parsed.value);

    var password_input = try loadPasswordInput(allocator, request.password, request.password_file);
    defer password_input.deinit(allocator);

    var error_config = if (request.strict)
        zpdf.ErrorConfig.strict()
    else if (request.permissive)
        zpdf.ErrorConfig.permissive()
    else
        zpdf.ErrorConfig.default();
    error_config.password = password_input.value;

    const doc = try zpdf.Document.openWithConfig(allocator, request.input_path, error_config);
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    _ = try zpdf.adapter.extractAdaptive(allocator, doc, writer, .{
        .document_id = request.document_id,
        .source_id = request.source_id,
        .format = request.format,
        .debug_assets_dir = request.debug_assets_dir,
        .specialist_config_path = request.specialist_config_path,
        .adaptive_options = .{
            .page_start = request.page_start,
            .page_end = request.page_end,
        },
    });

    const bytes = try output.toOwnedSlice(allocator);
    return .{
        .bytes = bytes,
        .content_type = switch (request.format) {
            .json, .trace_json => "application/json",
            .artifact_jsonl, .stream_jsonl => "application/x-ndjson",
        },
    };
}

fn parseExtractRequest(value: std.json.Value) !ExtractRequest {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidJsonBody,
    };
    const input_path = stringField(object, "input_path") orelse return error.MissingInputPath;
    return .{
        .input_path = input_path,
        .source_id = stringField(object, "source_id"),
        .document_id = stringField(object, "document_id"),
        .format = if (stringField(object, "format")) |format| zpdf.adapter.formatFromName(format) orelse return error.InvalidFormat else .stream_jsonl,
        .page_start = integerField(object, "page_start"),
        .page_end = integerField(object, "page_end"),
        .strict = boolField(object, "strict") orelse false,
        .permissive = boolField(object, "permissive") orelse true,
        .password = stringField(object, "password"),
        .password_file = stringField(object, "password_file"),
        .debug_assets_dir = stringField(object, "debug_assets_dir"),
        .specialist_config_path = stringField(object, "specialist_config_path"),
    };
}

const PasswordInput = struct {
    value: ?[]const u8 = null,
    owned: ?[]align(1) u8 = null,

    fn deinit(self: *PasswordInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
        self.* = .{};
    }
};

fn loadPasswordInput(allocator: std.mem.Allocator, password: ?[]const u8, password_file: ?[]const u8) !PasswordInput {
    if (password != null and password_file != null) return error.DuplicatePasswordSource;
    if (password) |value| return .{ .value = value };
    const path = password_file orelse return .{};
    const data = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    return .{
        .value = trimTrailingNewlines(data),
        .owned = data,
    };
}

fn trimTrailingNewlines(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) {
        end -= 1;
    }
    return bytes[0..end];
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn boolField(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?usize {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        else => null,
    };
}

pub fn renderCapabilities(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"parser_version\":\"{s}\",\"schema_version\":\"{s}\",\"formats\":[\"json\",\"artifact-jsonl\",\"stream-jsonl\",\"trace-json\"],\"endpoints\":[\"/healthz\",\"/v1/capabilities\",\"/v1/extract-adaptive\"],\"integration_modes\":[\"cli-subprocess\",\"c-abi\",\"http-server\"]}}\n",
        .{ zpdf.schema.parser_version, zpdf.schema.schema_version },
    );
}

fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn errorJson(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = runtime.arrayListWriter(&out, allocator);
    try writer.writeAll("{\"error\":\"");
    try writeJsonEscaped(writer, code);
    try writer.writeAll("\",\"message\":\"");
    try writeJsonEscaped(writer, message);
    try writer.writeAll("\"}\n");
    return out.toOwnedSlice(allocator);
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

test "server capabilities document packaging modes" {
    const body = try renderCapabilities(std.testing.allocator);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
    try std.testing.expect(std.mem.indexOf(u8, body, "cli-subprocess") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "c-abi") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "http-server") != null);
}

test "server parses extract request options" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"input_path":"doc.pdf","source_id":"external","format":"artifact-jsonl","page_start":1,"page_end":2,"strict":true}
    , .{});
    defer parsed.deinit();

    const request = try parseExtractRequest(parsed.value);
    try std.testing.expectEqualStrings("doc.pdf", request.input_path);
    try std.testing.expectEqualStrings("external", request.source_id.?);
    try std.testing.expectEqual(zpdf.AdaptiveAdapterFormat.artifact_jsonl, request.format);
    try std.testing.expectEqual(@as(?usize, 1), request.page_start);
    try std.testing.expectEqual(@as(?usize, 2), request.page_end);
    try std.testing.expect(request.strict);
}
