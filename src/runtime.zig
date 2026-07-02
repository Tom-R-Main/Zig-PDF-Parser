const std = @import("std");

/// Zig 0.16 runtime helpers shared by CLI tools, tests, and FFI entrypoints.
pub const File = std.Io.File;

var current_io: ?std.Io = null;

pub fn debugAllocator() std.heap.DebugAllocator(.{}) {
    return .init;
}

pub fn setIo(io_value: std.Io) void {
    current_io = io_value;
}

fn currentIo() std.Io {
    return current_io orelse @panic("std.Io not initialized");
}

pub fn current() std.Io {
    return currentIo();
}

/// Build a Zig 0.16 entrypoint that supplies an allocator and argv to `main_fn`.
pub fn MainWithArgs(comptime main_fn: anytype) type {
    return struct {
        pub fn main(init: std.process.Init) !void {
            setIo(init.io);
            const args = try init.minimal.args.toSlice(init.arena.allocator());
            try main_fn(init.gpa, args);
        }
    };
}

/// Small adapter for call sites that stream into a std.ArrayList.
pub fn arrayListWriter(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListWriter {
    return .{
        .list = list,
        .allocator = allocator,
    };
}

pub const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: @This(), byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.allocator, fmt, args);
    }
};

pub fn stdoutWriter(buffer: []u8) @TypeOf(std.Io.File.stdout().writer(currentIo(), buffer)) {
    return std.Io.File.stdout().writer(currentIo(), buffer);
}

pub fn stderrWriter(buffer: []u8) @TypeOf(std.Io.File.stderr().writer(currentIo(), buffer)) {
    return std.Io.File.stderr().writer(currentIo(), buffer);
}

pub fn writeAllStdout(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(currentIo(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn createFileCwd(path: []const u8) !File {
    return std.Io.Dir.cwd().createFile(currentIo(), path, .{});
}

pub fn createDirPathCwd(path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(currentIo(), path, .default_dir);
}

pub fn createDirPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return createDirPathCwd(path);
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return;
    if (dirExists(path)) return;
    if (std.fs.path.dirname(path)) |parent| {
        if (!std.mem.eql(u8, parent, path)) try createDirPath(parent);
    }
    std.Io.Dir.createDirAbsolute(currentIo(), path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn dirExists(path: []const u8) bool {
    const dir = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(currentIo(), path, .{})
    else
        std.Io.Dir.cwd().openDir(currentIo(), path, .{});
    if (dir) |opened| {
        opened.close(currentIo());
        return true;
    } else |_| {
        return false;
    }
}

pub fn closeFile(file: File) void {
    file.close(currentIo());
}

pub fn fileSizeCwd(path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(currentIo(), path, .{});
    defer file.close(currentIo());
    return (try file.stat(currentIo())).size;
}

pub fn deleteFileCwd(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(currentIo(), path) catch {};
}

pub fn deleteTreeCwd(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(currentIo(), path) catch {};
}

pub fn readFileAllocAlignedCwd(
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime alignment: std.mem.Alignment,
) ![]align(alignment.toByteUnits()) u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const data = try allocator.alignedAlloc(u8, alignment, stat.size);
    errdefer allocator.free(data);

    const bytes_read = try file.readPositionalAll(io, data, 0);
    if (bytes_read != stat.size) return error.UnexpectedEof;
    return data;
}

pub fn mmapFileReadOnlyCwd(allocator: std.mem.Allocator, path: []const u8) ![]align(std.heap.page_size_min) u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    return std.posix.mmap(
        null,
        stat.size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
}

pub fn writeAllFile(file: File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(currentIo(), &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn fileWriter(file: File, buffer: []u8) @TypeOf(file.writer(currentIo(), buffer)) {
    return file.writer(currentIo(), buffer);
}

pub fn nanoTimestamp() i128 {
    return @intCast(std.Io.Timestamp.now(currentIo(), .awake).nanoseconds);
}

pub fn runIgnored(argv: []const []const u8) !u8 {
    var child = try std.process.spawn(currentIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(currentIo());
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

pub fn runCapture(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    options: struct {
        stdout_limit: usize = 16 * 1024 * 1024,
        stderr_limit: usize = 1024 * 1024,
        timeout_ms: u32 = 10_000,
    },
) !std.process.RunResult {
    return std.process.run(allocator, currentIo(), .{
        .argv = argv,
        .stdout_limit = .limited(options.stdout_limit),
        .stderr_limit = .limited(options.stderr_limit),
        .timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(@intCast(options.timeout_ms)),
        } },
    });
}

test "runtime ArrayList writer" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    var writer = arrayListWriter(&list, std.testing.allocator);
    try writer.writeAll("hello");
    try writer.writeByte(' ');
    try writer.print("{}", .{123});

    try std.testing.expectEqualStrings("hello 123", list.items);
}

test "runtime cwd file helpers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    setIo(threaded.io());

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "zpdf-runtime-test-{x}-{x}.tmp", .{
        std.testing.random_seed,
        nanoTimestamp(),
    });
    deleteFileCwd(path);
    defer deleteFileCwd(path);

    const file = try createFileCwd(path);
    try writeAllFile(file, "abc123");
    closeFile(file);

    try std.testing.expectEqual(@as(u64, 6), try fileSizeCwd(path));
    const data = try readFileAllocAlignedCwd(std.testing.allocator, path, .fromByteUnits(1));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("abc123", data);
}

test "runtime nano timestamp returns a value" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    setIo(threaded.io());

    _ = nanoTimestamp();
}
