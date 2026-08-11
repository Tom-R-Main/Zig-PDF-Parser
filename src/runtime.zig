const std = @import("std");
const builtin = @import("builtin");

/// Zig 0.16 runtime helpers shared by CLI tools, tests, and FFI entrypoints.
pub const File = std.Io.File;
/// Large JSONL extraction streams are hundreds of MB on benchmark documents.
pub const large_output_buffer_size = 256 * 1024;

var current_io: ?std.Io = null;
var capture_input_sequence = std.atomic.Value(u64).init(0);

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

/// Run a bounded subprocess with deterministic bytes supplied on stdin.
/// A short-lived file avoids pipe write/read deadlocks while stdout and stderr
/// are drained concurrently by `std.process.run`.
pub fn runCaptureWithInput(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    input: []const u8,
    options: struct {
        stdout_limit: usize = 1024 * 1024,
        stderr_limit: usize = 64 * 1024,
        timeout_ms: u32 = 30_000,
    },
) !std.process.RunResult {
    const input_limit = 1024 * 1024;
    if (input.len > input_limit) return error.InputTooLong;
    const temp_dir: []const u8 = if (builtin.os.tag == .windows) "." else "/tmp";
    const sequence = capture_input_sequence.fetchAdd(1, .monotonic);
    const filename = try std.fmt.allocPrint(allocator, "pdf-parser-specialist-stdin-{x}-{x}.tmp", .{ nanoTimestamp(), sequence });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ temp_dir, filename });
    defer allocator.free(path);
    var path_exists = false;
    defer if (path_exists) deleteFilePath(path);

    const input_file = try createFilePath(path, .{
        .exclusive = true,
        .permissions = privateFilePermissions(),
    });
    path_exists = true;
    writeAllFile(input_file, input) catch |err| {
        input_file.close(currentIo());
        return err;
    };
    input_file.close(currentIo());

    const read_file = try openFilePath(path);
    defer read_file.close(currentIo());
    if (builtin.os.tag != .windows) {
        // POSIX children only need the open handle. Remove the directory entry
        // before spawning; keep deferred cleanup armed unless unlink succeeds.
        try deleteFilePathChecked(path);
        path_exists = false;
    }

    var child = try std.process.spawn(currentIo(), .{
        .argv = argv,
        .stdin = .{ .file = read_file },
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(currentIo());

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, currentIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(options.timeout_ms)),
    } };
    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > options.stdout_limit or stderr_reader.buffered().len > options.stderr_limit)
            return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(currentIo());
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

fn createFilePath(path: []const u8, options: std.Io.Dir.CreateFileOptions) !File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(currentIo(), path, options)
    else
        std.Io.Dir.cwd().createFile(currentIo(), path, options);
}

fn openFilePath(path: []const u8) !File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(currentIo(), path, .{})
    else
        std.Io.Dir.cwd().openFile(currentIo(), path, .{});
}

fn deleteFilePath(path: []const u8) void {
    deleteFilePathChecked(path) catch {};
}

fn deleteFilePathChecked(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.deleteFileAbsolute(currentIo(), path);
    } else {
        try std.Io.Dir.cwd().deleteFile(currentIo(), path);
    }
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
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

test "runtime subprocess stdin rejects oversized input before spawn" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    setIo(threaded.io());
    const input = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(input);
    try std.testing.expectError(error.InputTooLong, runCaptureWithInput(
        std.testing.allocator,
        &.{"definitely-not-spawned"},
        input,
        .{},
    ));
}

test "runtime nano timestamp returns a value" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    setIo(threaded.io());

    _ = nanoTimestamp();
}
