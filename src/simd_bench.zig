//! In-process benchmark for the substring-search seam used by parser scanners.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime.zig");
const simd = @import("simd.zig");

const default_warmup_count: usize = 100;
const default_repeat_count: usize = 1000;
const batch_iteration_count: usize = 256;
const needle = "EI";
const safe_alphabet = "ABCDFGHJKLMNOPQRSTUVWXYZ";
const buffer_sizes = [_]usize{ 32, 64, 128, 256, 512, 1024, 4096 };
const max_buffer_size = buffer_sizes[buffer_sizes.len - 1];

const Arm = enum {
    scalar,
    std_mem,
    existing_simd,
};

const Config = struct {
    warmup_count: usize = default_warmup_count,
    repeat_count: usize = default_repeat_count,
    format: enum { json, text } = .text,
};

const SampleStats = struct {
    median_ns: u64,
    mad_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

const BenchResult = struct {
    scalar: SampleStats,
    std_mem: SampleStats,
    existing_simd: SampleStats,
    checksum: usize,
};

pub const main = runtime.MainWithArgs(mainInner).main;

fn mainInner(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const config = try parseArgs(args);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = runtime.stdoutWriter(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (builtin.mode != .ReleaseFast) {
        try writeRefusal(stdout, config);
        return;
    }

    const sample_count = std.math.mul(usize, config.repeat_count, 3) catch return error.InvalidIterationCount;
    const samples = try allocator.alloc(u64, sample_count);
    defer allocator.free(samples);
    const scalar_samples = samples[0..config.repeat_count];
    const std_samples = samples[config.repeat_count .. config.repeat_count * 2];
    const simd_samples = samples[config.repeat_count * 2 ..];

    var buffers: [buffer_sizes.len][max_buffer_size]u8 = undefined;
    prepareBuffers(&buffers);

    var checksum: usize = 0;
    var warmup_index: usize = 0;
    while (warmup_index < config.warmup_count) : (warmup_index += 1) {
        checksum +%= runSample(.scalar, &buffers);
        checksum +%= runSample(.std_mem, &buffers);
        checksum +%= runSample(.existing_simd, &buffers);
    }

    var repeat_index: usize = 0;
    while (repeat_index < config.repeat_count) : (repeat_index += 1) {
        scalar_samples[repeat_index] = timeBatch(.scalar, &buffers, &checksum);
        std_samples[repeat_index] = timeBatch(.std_mem, &buffers, &checksum);
        simd_samples[repeat_index] = timeBatch(.existing_simd, &buffers, &checksum);
    }
    std.mem.doNotOptimizeAway(checksum);

    const result = BenchResult{
        .scalar = stats(scalar_samples),
        .std_mem = stats(std_samples),
        .existing_simd = stats(simd_samples),
        .checksum = checksum,
    };
    if (config.format == .json) {
        try writeJson(stdout, config, result);
    } else {
        try writeText(stdout, config, result);
    }
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--warmup")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            config.warmup_count = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            config.repeat_count = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            if (std.mem.eql(u8, args[index], "json")) {
                config.format = .json;
            } else if (std.mem.eql(u8, args[index], "text")) {
                config.format = .text;
            } else {
                return error.InvalidFormat;
            }
        } else {
            return error.UnknownArgument;
        }
    }
    if (config.warmup_count == 0 or config.repeat_count == 0) return error.InvalidIterationCount;
    return config;
}

fn prepareBuffers(buffers: *[buffer_sizes.len][max_buffer_size]u8) void {
    for (buffers, buffer_sizes, 0..) |*storage, size, buffer_index| {
        var state: u32 = @intCast(0x9e3779b9 +% @as(u32, @intCast(buffer_index * 97)));
        for (storage[0..size], 0..) |*byte, byte_index| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            const alphabet_index: usize = state % safe_alphabet.len;
            byte.* = safe_alphabet[alphabet_index];
            if (byte_index % 47 == 11) byte.* = 'E';
        }
        storage[size - needle.len] = needle[0];
        storage[size - 1] = needle[1];
    }
}

fn timeBatch(arm: Arm, buffers: *const [buffer_sizes.len][max_buffer_size]u8, checksum: *usize) u64 {
    const started_ns = runtime.nanoTimestamp();
    checksum.* +%= runSample(arm, buffers);
    const elapsed_ns = runtime.nanoTimestamp() - started_ns;
    return @intCast(@max(elapsed_ns, 0));
}

fn runSample(arm: Arm, buffers: *const [buffer_sizes.len][max_buffer_size]u8) usize {
    var checksum: usize = 0;
    var batch_index: usize = 0;
    while (batch_index < batch_iteration_count) : (batch_index += 1) {
        checksum +%= runBatch(arm, buffers);
    }
    std.mem.doNotOptimizeAway(checksum);
    return checksum;
}

fn runBatch(arm: Arm, buffers: *const [buffer_sizes.len][max_buffer_size]u8) usize {
    var checksum: usize = 0;
    for (buffers, buffer_sizes) |*storage, size| {
        const data = storage[0..size];
        const found = switch (arm) {
            .scalar => scalarFindSubstring(data, needle),
            .std_mem => std.mem.indexOf(u8, data, needle),
            .existing_simd => simd.findSubstring(data, needle),
        };
        checksum +%= found orelse data.len;
    }
    std.mem.doNotOptimizeAway(checksum);
    return checksum;
}

fn scalarFindSubstring(data: []const u8, search_needle: []const u8) ?usize {
    if (search_needle.len == 0) return 0;
    if (search_needle.len > data.len) return null;

    var index: usize = 0;
    while (index + search_needle.len <= data.len) : (index += 1) {
        if (data[index] == search_needle[0] and
            std.mem.eql(u8, data[index..][0..search_needle.len], search_needle))
        {
            return index;
        }
    }
    return null;
}

fn stats(samples: []u64) SampleStats {
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    const median = percentile(samples, 50);
    const min = samples[0];
    const max = samples[samples.len - 1];
    for (samples) |*sample| {
        sample.* = if (sample.* > median) sample.* - median else median - sample.*;
    }
    std.sort.heap(u64, samples, {}, std.sort.asc(u64));
    return .{
        .median_ns = median,
        .mad_ns = percentile(samples, 50),
        .min_ns = min,
        .max_ns = max,
    };
}

fn percentile(sorted_samples: []const u64, percent: usize) u64 {
    const index = ((sorted_samples.len - 1) * percent) / 100;
    return sorted_samples[index];
}

fn resolvedVectorWidth() usize {
    const has_avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
    const has_sse42 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);
    const has_neon = builtin.cpu.arch == .aarch64;
    return if (has_avx2) 32 else if (has_sse42 or has_neon) 16 else 8;
}

fn hasAvx2() bool {
    return builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
}

fn hasSse42() bool {
    return builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);
}

fn verdict(result: BenchResult) ?[]const u8 {
    const scalar = result.scalar.median_ns;
    const standard = result.std_mem.median_ns;
    const existing = result.existing_simd.median_ns;
    const fastest = @min(scalar, @min(standard, existing));
    const next_fastest, const combined_mad, const winner = if (fastest == scalar)
        if (standard <= existing)
            .{ standard, result.scalar.mad_ns + result.std_mem.mad_ns, "scalar" }
        else
            .{ existing, result.scalar.mad_ns + result.existing_simd.mad_ns, "scalar" }
    else if (fastest == standard)
        if (scalar <= existing)
            .{ scalar, result.std_mem.mad_ns + result.scalar.mad_ns, "std_mem" }
        else
            .{ existing, result.std_mem.mad_ns + result.existing_simd.mad_ns, "std_mem" }
    else if (scalar <= standard)
        .{ scalar, result.existing_simd.mad_ns + result.scalar.mad_ns, "existing_simd" }
    else
        .{ standard, result.existing_simd.mad_ns + result.std_mem.mad_ns, "existing_simd" };
    const improvement_percent = if (next_fastest == 0) 0 else ((next_fastest - fastest) * 100) / next_fastest;
    if (improvement_percent < 5 or next_fastest - fastest <= combined_mad) return null;
    return winner;
}

fn writeRefusal(writer: anytype, config: Config) !void {
    if (config.format == .json) {
        try writer.print(
            "{{\"schema_version\":\"1.0.0\",\"zig_version\":\"{s}\",\"optimize_mode\":\"{s}\",\"architecture\":\"{s}\",\"target_features\":{{\"avx2\":{},\"sse4_2\":{},\"neon\":{}}},\"resolved_vector_width_bytes\":{},\"buffer_distribution\":{{\"sizes_bytes\":[32,64,128,256,512,1024,4096],\"needle\":\"EI\",\"match_position\":\"end\",\"false_first_byte_stride\":47}},\"warmup_count\":{},\"repeat_count\":{},\"batch_iterations\":{},\"operations_per_sample\":{},\"verdict\":null,\"refusal_reason\":\"benchmark verdicts require ReleaseFast\"}}\n",
            .{
                builtin.zig_version_string,
                @tagName(builtin.mode),
                @tagName(builtin.cpu.arch),
                hasAvx2(),
                hasSse42(),
                builtin.cpu.arch == .aarch64,
                resolvedVectorWidth(),
                config.warmup_count,
                config.repeat_count,
                batch_iteration_count,
                batch_iteration_count * buffer_sizes.len,
            },
        );
    } else {
        try writer.print("Refusing benchmark verdict in {s}; rerun with -Doptimize=ReleaseFast.\n", .{@tagName(builtin.mode)});
    }
}

fn writeJson(writer: anytype, config: Config, result: BenchResult) !void {
    const result_verdict = verdict(result);
    try writer.print(
        "{{\"schema_version\":\"1.0.0\",\"zig_version\":\"{s}\",\"optimize_mode\":\"{s}\",\"architecture\":\"{s}\",\"target_features\":{{\"avx2\":{},\"sse4_2\":{},\"neon\":{}}},\"resolved_vector_width_bytes\":{},\"buffer_distribution\":{{\"sizes_bytes\":[32,64,128,256,512,1024,4096],\"needle\":\"EI\",\"match_position\":\"end\",\"false_first_byte_stride\":47}},\"warmup_count\":{},\"repeat_count\":{},\"batch_iterations\":{},\"operations_per_sample\":{},\"arms\":{{\"scalar\":{{\"median_ns\":{},\"mad_ns\":{},\"min_ns\":{},\"max_ns\":{}}},\"std_mem\":{{\"median_ns\":{},\"mad_ns\":{},\"min_ns\":{},\"max_ns\":{}}},\"existing_simd\":{{\"median_ns\":{},\"mad_ns\":{},\"min_ns\":{},\"max_ns\":{}}}}},\"checksum\":{},\"verdict\":",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.cpu.arch),
            hasAvx2(),
            hasSse42(),
            builtin.cpu.arch == .aarch64,
            resolvedVectorWidth(),
            config.warmup_count,
            config.repeat_count,
            batch_iteration_count,
            batch_iteration_count * buffer_sizes.len,
            result.scalar.median_ns,
            result.scalar.mad_ns,
            result.scalar.min_ns,
            result.scalar.max_ns,
            result.std_mem.median_ns,
            result.std_mem.mad_ns,
            result.std_mem.min_ns,
            result.std_mem.max_ns,
            result.existing_simd.median_ns,
            result.existing_simd.mad_ns,
            result.existing_simd.min_ns,
            result.existing_simd.max_ns,
            result.checksum,
        },
    );
    if (result_verdict) |winner| {
        try writer.print("\"{s}\"}}\n", .{winner});
    } else {
        try writer.writeAll("null}\n");
    }
}

fn writeText(writer: anytype, config: Config, result: BenchResult) !void {
    try writer.print(
        "Zig {s} {s} {s}, vector width {} B, warmup {}, repeat {}, batch iterations {}\n" ++
            "scalar: median {} ns, MAD {} ns\n" ++
            "std.mem.indexOf: median {} ns, MAD {} ns\n" ++
            "existing SIMD: median {} ns, MAD {} ns\n",
        .{
            builtin.zig_version_string,
            @tagName(builtin.mode),
            @tagName(builtin.cpu.arch),
            resolvedVectorWidth(),
            config.warmup_count,
            config.repeat_count,
            batch_iteration_count,
            result.scalar.median_ns,
            result.scalar.mad_ns,
            result.std_mem.median_ns,
            result.std_mem.mad_ns,
            result.existing_simd.median_ns,
            result.existing_simd.mad_ns,
        },
    );
    if (verdict(result)) |winner| {
        try writer.print("verdict: {s}\n", .{winner});
    } else {
        try writer.writeAll("verdict: no clear winner\n");
    }
}

test "benchmark arms agree across deterministic buffers" {
    var buffers: [buffer_sizes.len][max_buffer_size]u8 = undefined;
    prepareBuffers(&buffers);
    for (&buffers, buffer_sizes) |*storage, size| {
        try std.testing.expectEqual(size - needle.len, scalarFindSubstring(storage[0..size], needle).?);
    }
    try std.testing.expectEqual(runBatch(.scalar, &buffers), runBatch(.std_mem, &buffers));
    try std.testing.expectEqual(runBatch(.scalar, &buffers), runBatch(.existing_simd, &buffers));
}

test "scalar substring edge cases match standard library" {
    const cases = [_][]const u8{ "", "E", "EI", "AEI", "EAEI", "no match" };
    for (cases) |data| {
        try std.testing.expectEqual(std.mem.indexOf(u8, data, needle), scalarFindSubstring(data, needle));
    }
}
