//! PDF Page Tree Parser
//!
//! PDFs store pages in a tree structure for efficiency with large documents.
//! Structure: Catalog -> Pages (root) -> [Pages | Page] -> ...
//!
//! We flatten this to a simple array for O(1) page access.

const std = @import("std");
const parser = @import("parser.zig");
const xref_mod = @import("xref.zig");
const encryption = @import("encryption.zig");
const structural = @import("structural.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;

pub const Page = struct {
    /// Object reference for this page
    ref: ObjRef,
    /// Page dictionary
    dict: Object.Dict,
    /// Inherited MediaBox [x0, y0, x1, y1]
    media_box: [4]f64,
    /// Inherited CropBox (defaults to MediaBox)
    crop_box: [4]f64,
    /// Rotation in degrees (0, 90, 180, 270)
    rotation: i32,
    /// Inherited Resources dictionary
    resources: ?Object.Dict,
};

pub const PageTreeError = error{
    CatalogNotFound,
    PagesNotFound,
    InvalidPageTree,
    InvalidPageObject,
    CircularReference,
    OutOfMemory,
};

pub const BuildOptions = struct {
    security: ?*const encryption.SecurityHandler = null,
    diagnostics: ?*std.ArrayList(structural.Diagnostic) = null,
    diagnostic_allocator: ?std.mem.Allocator = null,
    recover: bool = true,
};

/// Resolve object reference using XRef table
pub fn resolveRef(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    return resolveRefWithOptions(allocator, data, xref, ref, resolved_cache, .{});
}

/// Resolve object reference using XRef table, optionally decrypting the
/// resulting indirect object with the document security handler.
pub fn resolveRefWithSecurity(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
    security: ?*const encryption.SecurityHandler,
) !Object {
    return resolveRefWithOptions(allocator, data, xref, ref, resolved_cache, .{ .security = security });
}

pub fn resolveRefWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) !Object {
    // Check cache first
    if (resolved_cache.get(ref.num)) |cached| {
        return cached;
    }

    const entry = xref.get(ref.num) orelse {
        emit(allocator, options, .{
            .code = .missing_object,
            .severity = .warning,
            .stage = .object,
            .object_ref = .{ .num = ref.num, .gen = ref.gen },
            .action = .skipped,
            .message = "Object reference is missing from xref table",
        });
        return Object{ .null = {} };
    };

    switch (entry.entry_type) {
        .free => return Object{ .null = {} },
        .in_use => {
            if (entry.offset >= data.len) {
                emit(allocator, options, .{
                    .code = .missing_object,
                    .severity = .warning,
                    .stage = .object,
                    .offset = entry.offset,
                    .object_ref = .{ .num = ref.num, .gen = ref.gen },
                    .action = .skipped,
                    .message = "Object offset points beyond end of file",
                });
                return Object{ .null = {} };
            }

            var p = parser.Parser.initAtWithOptions(allocator, data, @intCast(entry.offset), .{
                .recover_stream_lengths = options.recover,
                .diagnostics = options.diagnostics,
                .diagnostic_allocator = options.diagnostic_allocator,
            });
            const indirect = p.parseIndirectObject() catch {
                emit(allocator, options, .{
                    .code = .missing_object,
                    .severity = .warning,
                    .stage = .object,
                    .offset = entry.offset,
                    .object_ref = .{ .num = ref.num, .gen = ref.gen },
                    .action = .skipped,
                    .message = "Failed to parse indirect object",
                });
                return Object{ .null = {} };
            };
            const object = if (options.security) |handler|
                handler.decryptObject(allocator, .{ .num = indirect.num, .gen = indirect.gen }, indirect.obj) catch return Object{ .null = {} }
            else
                indirect.obj;

            try resolved_cache.put(ref.num, object);
            return object;
        },
        .compressed => {
            // Object is inside an object stream
            return resolveCompressedObject(allocator, data, xref, entry, resolved_cache, options);
        },
    }
}

fn resolveCompressedObject(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    entry: xref_mod.XRefEntry,
    resolved_cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) !Object {
    const objstm_num: u32 = @intCast(entry.offset);
    const index = entry.gen_or_index;

    // Get the object stream
    const objstm_entry = xref.get(objstm_num) orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, null, "Object stream reference is missing"));
        return Object{ .null = {} };
    };
    if (objstm_entry.entry_type != .in_use) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, null, "Object stream entry is not an in-use object"));
        return Object{ .null = {} };
    }
    if (objstm_entry.offset >= data.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream offset points beyond EOF"));
        return Object{ .null = {} };
    }

    var p = parser.Parser.initAtWithOptions(allocator, data, @intCast(objstm_entry.offset), .{
        .recover_stream_lengths = options.recover,
        .diagnostics = options.diagnostics,
        .diagnostic_allocator = options.diagnostic_allocator,
    });
    const indirect = p.parseIndirectObject() catch {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to parse object stream object"));
        return Object{ .null = {} };
    };

    const objstm_obj = if (options.security) |handler|
        handler.decryptObject(allocator, .{ .num = indirect.num, .gen = indirect.gen }, indirect.obj) catch return Object{ .null = {} }
    else
        indirect.obj;

    const stream = switch (objstm_obj) {
        .stream => |s| s,
        else => {
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream reference did not resolve to a stream"));
            return Object{ .null = {} };
        },
    };

    // Decompress stream (arena-allocated, no need to free)
    const decompress = @import("decompress.zig");
    const decoded = decompress.decompressStream(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
    ) catch {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to decompress object stream"));
        return Object{ .null = {} };
    };

    // Parse object stream header
    const n = stream.dict.getInt("N") orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream is missing /N"));
        return Object{ .null = {} };
    };
    const first = stream.dict.getInt("First") orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream is missing /First"));
        return Object{ .null = {} };
    };

    if (n <= 0 or first < 0 or first >= decoded.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream has invalid /N or /First"));
        return Object{ .null = {} };
    }

    // Parse offset pairs from header
    var header_parser = parser.Parser.init(allocator, decoded);
    var offsets: std.ArrayList(struct { num: u32, offset: u64 }) = .empty;
    defer offsets.deinit(allocator);

    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const obj = header_parser.parseObject() catch {
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header ended early"));
            break;
        };
        const num: u32 = switch (obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        const offset_obj = header_parser.parseObject() catch {
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header offset ended early"));
            break;
        };
        const offset: u64 = switch (offset_obj) {
            .integer => |int| @intCast(int),
            else => break,
        };

        try offsets.append(allocator, .{ .num = num, .offset = offset });
    }

    // Find our object
    if (index >= offsets.items.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream target index is out of range"));
        return Object{ .null = {} };
    }

    const obj_offset: usize = @intCast(first);
    const rel_offset = offsets.items[index].offset;

    if (obj_offset + rel_offset >= decoded.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream target offset is out of range"));
        return Object{ .null = {} };
    }

    var obj_parser = parser.Parser.initAt(allocator, decoded, obj_offset + @as(usize, @intCast(rel_offset)));
    const result = obj_parser.parseObject() catch {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to parse compressed object"));
        return Object{ .null = {} };
    };

    try resolved_cache.put(offsets.items[index].num, result);
    return result;
}

/// Build page array from PDF document
pub fn buildPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
) PageTreeError![]Page {
    return buildPageTreeWithSecurity(allocator, data, xref, null);
}

pub fn buildPageTreeWithSecurity(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    security: ?*const encryption.SecurityHandler,
) PageTreeError![]Page {
    return buildPageTreeWithOptions(allocator, data, xref, .{ .security = security });
}

pub fn buildPageTreeWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    options: BuildOptions,
) PageTreeError![]Page {
    var resolved_cache = std.AutoHashMap(u32, Object).init(allocator);
    defer resolved_cache.deinit();

    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return PageTreeError.CatalogNotFound) {
        .reference => |r| r,
        else => return PageTreeError.CatalogNotFound,
    };

    // Resolve catalog
    const catalog = resolveRefWithOptions(allocator, data, xref, root_ref, &resolved_cache, options) catch
        return PageTreeError.CatalogNotFound;

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return PageTreeError.CatalogNotFound,
    };

    // Get Pages reference
    const pages_ref = switch (catalog_dict.get("Pages") orelse return PageTreeError.PagesNotFound) {
        .reference => |r| r,
        else => return PageTreeError.PagesNotFound,
    };

    // Build page list
    var pages: std.ArrayList(Page) = .empty;
    errdefer pages.deinit(allocator);

    // Track visited nodes to detect cycles
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    // Inherited attributes
    const default_mediabox = [4]f64{ 0, 0, 612, 792 }; // Letter size default

    try walkPageTree(
        allocator,
        data,
        xref,
        options,
        &resolved_cache,
        &visited,
        &pages,
        pages_ref,
        default_mediabox,
        null, // crop_box
        0, // rotation
        null, // resources
    );

    return pages.toOwnedSlice(allocator);
}

fn walkPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    options: BuildOptions,
    cache: *std.AutoHashMap(u32, Object),
    visited: *std.AutoHashMap(u32, void),
    pages: *std.ArrayList(Page),
    node_ref: ObjRef,
    inherited_mediabox: [4]f64,
    inherited_cropbox: ?[4]f64,
    inherited_rotation: i32,
    inherited_resources: ?Object.Dict,
) PageTreeError!void {
    // Cycle detection
    if (visited.contains(node_ref.num)) {
        emit(allocator, options, .{
            .code = .page_tree_circular_reference,
            .severity = .warning,
            .stage = .page_tree,
            .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
            .action = if (options.recover) .skipped else .failed,
            .message = "Circular page-tree reference",
        });
        return PageTreeError.CircularReference;
    }
    visited.put(node_ref.num, {}) catch return PageTreeError.OutOfMemory;
    defer _ = visited.remove(node_ref.num);

    // Resolve node
    const node = resolveRefWithOptions(allocator, data, xref, node_ref, cache, options) catch
        return PageTreeError.InvalidPageTree;

    const dict = switch (node) {
        .dict => |d| d,
        else => return PageTreeError.InvalidPageTree,
    };

    // Check Type — some generators omit /Type; infer from structure
    const type_name = dict.getName("Type") orelse blk: {
        emit(allocator, options, .{
            .code = .page_tree_missing_type,
            .severity = .warning,
            .stage = .page_tree,
            .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
            .action = .recovered,
            .message = "Page-tree node is missing /Type; inferred from structure",
        });
        break :blk if (dict.get("Kids") != null) "Pages" else "Page";
    };

    // Get inherited attributes at this level
    const mediabox = extractBox(dict, "MediaBox") orelse blk: {
        if (dict.get("MediaBox") != null) {
            emit(allocator, options, .{
                .code = .page_tree_missing_box,
                .severity = .warning,
                .stage = .page_tree,
                .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                .action = .recovered,
                .message = "Invalid MediaBox; using inherited/default box",
            });
        }
        break :blk inherited_mediabox;
    };
    const cropbox = extractBox(dict, "CropBox") orelse inherited_cropbox;
    const rotation = @as(i32, @intCast(dict.getInt("Rotate") orelse inherited_rotation));

    var resources = inherited_resources;
    if (dict.get("Resources")) |res_obj| {
        const resolved = switch (res_obj) {
            .reference => |r| resolveRefWithOptions(allocator, data, xref, r, cache, options) catch res_obj,
            else => res_obj,
        };
        if (resolved == .dict) {
            resources = resolved.dict;
        }
    }

    if (std.mem.eql(u8, type_name, "Pages")) {
        // Intermediate node - recurse into Kids
        const kids = blk: {
            const kids_obj = dict.get("Kids") orelse break :blk null;
            const resolved = switch (kids_obj) {
                .reference => |ref| resolveRefWithOptions(allocator, data, xref, ref, cache, options) catch break :blk null,
                else => kids_obj,
            };
            break :blk switch (resolved) {
                .array => |items| items,
                else => null,
            };
        } orelse {
            emit(allocator, options, .{
                .code = .page_tree_missing_kids,
                .severity = if (options.recover) .warning else .error_,
                .stage = .page_tree,
                .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                .action = if (options.recover) .skipped else .failed,
                .message = "Pages node is missing /Kids",
            });
            if (options.recover) return;
            return PageTreeError.InvalidPageTree;
        };
        if (dict.getInt("Count")) |declared_count| {
            if (declared_count != @as(i64, @intCast(kids.len))) {
                emit(allocator, options, .{
                    .code = .page_tree_wrong_count,
                    .severity = .warning,
                    .stage = .page_tree,
                    .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                    .action = .recovered,
                    .message = "Pages node /Count does not match immediate /Kids count",
                });
            }
        }

        for (kids) |kid| {
            const kid_ref = switch (kid) {
                .reference => |r| r,
                else => {
                    emit(allocator, options, .{
                        .code = .page_tree_bad_kid,
                        .severity = .warning,
                        .stage = .page_tree,
                        .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                        .action = .skipped,
                        .message = "Skipped non-reference page-tree kid",
                    });
                    continue;
                },
            };

            walkPageTree(
                allocator,
                data,
                xref,
                options,
                cache,
                visited,
                pages,
                kid_ref,
                mediabox,
                cropbox,
                rotation,
                resources,
            ) catch |err| {
                emit(allocator, options, .{
                    .code = .page_tree_recovered_child,
                    .severity = if (options.recover) .warning else .error_,
                    .stage = .page_tree,
                    .object_ref = .{ .num = kid_ref.num, .gen = kid_ref.gen },
                    .action = if (options.recover) .skipped else .failed,
                    .message = "Skipped unrecoverable page-tree child",
                });
                if (!options.recover) return err;
            };
        }
    } else if (std.mem.eql(u8, type_name, "Page")) {
        // Leaf node - add to pages list
        pages.append(allocator, .{
            .ref = node_ref,
            .dict = dict,
            .media_box = mediabox,
            .crop_box = cropbox orelse mediabox,
            .rotation = rotation,
            .resources = resources,
        }) catch return PageTreeError.OutOfMemory;
    }
    // Ignore unknown types
}

fn emit(allocator: std.mem.Allocator, options: BuildOptions, diagnostic: structural.Diagnostic) void {
    structural.appendDiagnostic(options.diagnostic_allocator orelse allocator, options.diagnostics, diagnostic);
}

fn objectStreamDiagnostic(objstm_num: u32, offset: ?u64, message: []const u8) structural.Diagnostic {
    return .{
        .code = .malformed_object_stream,
        .severity = .warning,
        .stage = .object_stream,
        .offset = offset,
        .object_ref = .{ .num = objstm_num, .gen = 0 },
        .action = .skipped,
        .message = message,
    };
}

fn extractBox(dict: Object.Dict, key: []const u8) ?[4]f64 {
    const array = dict.getArray(key) orelse return null;
    if (array.len != 4) return null;

    var box: [4]f64 = undefined;
    for (array, 0..) |elem, i| {
        box[i] = switch (elem) {
            .integer => |n| @floatFromInt(n),
            .real => |n| n,
            else => return null,
        };
    }
    return box;
}

/// Get page content stream(s)
pub fn getPageContents(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    return getPageContentsWithSecurity(parse_allocator, scratch_allocator, data, xref, page, cache, null);
}

pub fn getPageContentsWithSecurity(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
    security: ?*const encryption.SecurityHandler,
) ![]const u8 {
    const contents = page.dict.get("Contents") orelse return &[_]u8{};

    return getStreamData(parse_allocator, scratch_allocator, data, xref, contents, cache, security);
}

fn getStreamData(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj: Object,
    cache: *std.AutoHashMap(u32, Object),
    security: ?*const encryption.SecurityHandler,
) ![]const u8 {
    switch (obj) {
        .reference => |ref| {
            const resolved = try resolveRefWithSecurity(parse_allocator, data, xref, ref, cache, security);
            return getStreamData(parse_allocator, scratch_allocator, data, xref, resolved, cache, security);
        },
        .stream => |s| {
            const decompress = @import("decompress.zig");
            return decompress.decompressStream(
                scratch_allocator,
                s.data,
                s.dict.get("Filter"),
                s.dict.get("DecodeParms"),
            ) catch return s.data;
        },
        .array => |arr| {
            // Concatenate multiple content streams
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(scratch_allocator);

            for (arr) |item| {
                const stream_data = try getStreamData(parse_allocator, scratch_allocator, data, xref, item, cache, security);
                // stream_data is arena-allocated, no need to free
                try result.appendSlice(scratch_allocator, stream_data);
                try result.append(scratch_allocator, '\n'); // Separate streams
            }

            return result.toOwnedSlice(scratch_allocator);
        },
        else => return &[_]u8{},
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "extractBox" {
    const allocator = std.testing.allocator;

    // Create a simple dict with MediaBox
    var entries = [_]Object.Dict.Entry{
        .{
            .key = "MediaBox",
            .value = Object{
                .array = @constCast(&[_]Object{
                    .{ .integer = 0 },
                    .{ .integer = 0 },
                    .{ .integer = 612 },
                    .{ .integer = 792 },
                }),
            },
        },
    };

    const dict = Object.Dict{ .entries = &entries };

    const box = extractBox(dict, "MediaBox");
    try std.testing.expect(box != null);
    try std.testing.expectApproxEqRel(@as(f64, 0), box.?[0], 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 612), box.?[2], 0.001);

    _ = allocator;
}
