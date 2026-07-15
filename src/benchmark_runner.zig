//! Product-grade corpus benchmark runner.
//!
//! This runner keeps benchmark scorecards separate from adaptive extraction
//! schemas. It reuses eval_runner.zig for first-party document metrics and
//! wraps those results in suite/lane/category/regression records.

const std = @import("std");
const runtime = @import("runtime.zig");
const eval = @import("eval.zig");
const eval_runner = @import("eval_runner.zig");
const schema = @import("schema.zig");

pub const benchmark_schema_version = "0.2.0";

const MetricName = enum {
    cer,
    wer,
    normalized_edit_distance,
    token_f1,
    reading_order_score,
    table_cell_accuracy,
    table_span_accuracy,
    table_role_accuracy,
    table_rowspan_accuracy,
    table_colspan_accuracy,
    table_page_accuracy,
    table_continuation_accuracy,
    table_source_span_coverage,
    table_bbox_iou,
    table_numeric_accuracy,
    table_header_accuracy,
    table_footnote_accuracy,
    formula_structure_accuracy,
    form_field_accuracy,
    latency_ms,
    peak_rss_mb,
};

const MetricDirection = enum {
    lower,
    higher,
};

const MetricSpec = struct {
    name: MetricName,
    direction: MetricDirection,
    max_regression: f64,
    required: bool = false,
};

const default_specs = [_]MetricSpec{
    .{ .name = .cer, .direction = .lower, .max_regression = 0.02 },
    .{ .name = .wer, .direction = .lower, .max_regression = 0.02 },
    .{ .name = .normalized_edit_distance, .direction = .lower, .max_regression = 0.02 },
    .{ .name = .token_f1, .direction = .higher, .max_regression = 0.02 },
    .{ .name = .reading_order_score, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_cell_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_span_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_role_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_rowspan_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_colspan_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_page_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_continuation_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_source_span_coverage, .direction = .higher, .max_regression = 0.05 },
    .{ .name = .table_bbox_iou, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_numeric_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_header_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .table_footnote_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .formula_structure_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .form_field_accuracy, .direction = .higher, .max_regression = 0.03 },
    .{ .name = .latency_ms, .direction = .lower, .max_regression = 25.0 },
    .{ .name = .peak_rss_mb, .direction = .lower, .max_regression = 32.0 },
};

const Options = struct {
    manifest_path: []const u8 = "benchmark/eval/corpus/manifest.tsv",
    metadata_path: ?[]const u8 = null,
    suite_id: []const u8 = "default-suite",
    tools: []const u8 = "pdf-parser:adaptive",
    output_path: ?[]const u8 = null,
    jsonl_path: ?[]const u8 = null,
    candidate_command: ?[]const u8 = null,
    baseline_command: ?[]const u8 = null,
    thresholds_path: ?[]const u8 = null,
    fail_on_regression: bool = false,
    require_tools: bool = false,
    fail_on_skipped: bool = false,
    ocr_config: @import("ocr.zig").OcrConfig = .{},
};

const ToolKind = enum {
    pdf_parser_native,
    pdf_parser_adaptive,
    command,
    python_baseline,
    skipped,
};

const ToolLane = struct {
    id: []const u8,
    kind: ToolKind,
    command_template: ?[]const u8 = null,
    owns_command_template: bool = false,
};

const Metrics = struct {
    cer: ?f64 = null,
    wer: ?f64 = null,
    normalized_edit_distance: ?f64 = null,
    token_f1: ?f64 = null,
    reading_order_score: ?f64 = null,
    table_cell_accuracy: ?f64 = null,
    table_span_accuracy: ?f64 = null,
    table_role_accuracy: ?f64 = null,
    table_rowspan_accuracy: ?f64 = null,
    table_colspan_accuracy: ?f64 = null,
    table_page_accuracy: ?f64 = null,
    table_continuation_accuracy: ?f64 = null,
    table_source_span_coverage: ?f64 = null,
    table_bbox_iou: ?f64 = null,
    table_numeric_accuracy: ?f64 = null,
    table_header_accuracy: ?f64 = null,
    table_footnote_accuracy: ?f64 = null,
    formula_structure_accuracy: ?f64 = null,
    form_field_accuracy: ?f64 = null,
    latency_ms: ?f64 = null,
    peak_rss_mb: ?f64 = null,
};

const Counters = struct {
    native_pages: ?u32 = null,
    ocr_pages: ?u32 = null,
    table_regions: ?u32 = null,
    formula_regions: ?u32 = null,
};

const DocumentResult = struct {
    doc_id: []u8,
    category: []u8,
    tool_id: []u8,
    status: []const u8,
    reason: ?[]u8 = null,
    pages: u32 = 0,
    metrics: Metrics = .{},
    counters: Counters = .{},
    duration_ms: ?f64 = null,

    fn deinit(self: *DocumentResult, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_id);
        allocator.free(self.category);
        allocator.free(self.tool_id);
        if (self.reason) |reason| allocator.free(reason);
    }
};

const Regression = struct {
    doc_id: []u8,
    category: []u8,
    metric: MetricName,
    baseline_value: ?f64,
    candidate_value: ?f64,
    delta: ?f64,
    threshold: f64,
    direction: MetricDirection,
    status: []const u8,

    fn deinit(self: *Regression, allocator: std.mem.Allocator) void {
        allocator.free(self.doc_id);
        allocator.free(self.category);
    }
};

const BenchmarkResult = struct {
    json: []u8,
    jsonl: []u8,
    has_regression: bool,
    skipped_count: usize,

    fn deinit(self: *BenchmarkResult, allocator: std.mem.Allocator) void {
        allocator.free(self.json);
        allocator.free(self.jsonl);
    }
};

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const options = parseArgs(args) catch |err| {
        try printUsage();
        if (err == error.HelpRequested) return;
        return err;
    };

    var result = try runBenchmark(allocator, options);
    defer result.deinit(allocator);

    if (options.output_path) |path| {
        try ensureParentDir(path);
        const file = try runtime.createFileCwd(path);
        defer runtime.closeFile(file);
        try runtime.writeAllFile(file, result.json);
    } else {
        try runtime.writeAllStdout(result.json);
    }

    if (options.jsonl_path) |path| {
        try ensureParentDir(path);
        const file = try runtime.createFileCwd(path);
        defer runtime.closeFile(file);
        try runtime.writeAllFile(file, result.jsonl);
    }

    if (options.fail_on_skipped and result.skipped_count > 0) return error.BenchmarkToolSkipped;
    if (options.fail_on_regression and result.has_regression) return error.BenchmarkRegression;
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return;
    try runtime.createDirPath(dir);
}

fn runBenchmark(allocator: std.mem.Allocator, options: Options) !BenchmarkResult {
    const manifest = try runtime.readFileAllocAlignedCwd(allocator, options.manifest_path, .fromByteUnits(1));
    defer allocator.free(manifest);

    const manifest_sha256 = try schema.sha256Hex(allocator, manifest);
    defer allocator.free(manifest_sha256);

    const run_id = try std.fmt.allocPrint(allocator, "bench-{s}-{x}", .{
        manifest_sha256[0..@min(manifest_sha256.len, 12)],
        runtime.nanoTimestamp(),
    });
    defer allocator.free(run_id);

    var metadata_bytes: ?[]align(1) u8 = null;
    defer if (metadata_bytes) |bytes| allocator.free(bytes);
    var inferred_metadata_path: ?[]u8 = null;
    defer if (inferred_metadata_path) |path| allocator.free(path);
    const metadata_path = options.metadata_path orelse blk: {
        inferred_metadata_path = try eval_runner.inferMetadataPath(allocator, options.manifest_path);
        break :blk inferred_metadata_path.?;
    };
    metadata_bytes = runtime.readFileAllocAlignedCwd(allocator, metadata_path, .fromByteUnits(1)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const expected_counts = if (metadata_bytes) |bytes|
        try eval_runner.parseMetadataRouteCounts(allocator, bytes)
    else
        try allocator.alloc(eval_runner.ExpectedRouteCounts, 0);
    defer allocator.free(expected_counts);

    var lanes = try parseLanes(allocator, options);
    defer {
        for (lanes.items) |lane| {
            if (lane.owns_command_template) allocator.free(lane.command_template.?);
        }
        lanes.deinit(allocator);
    }

    var specs = try loadMetricSpecs(allocator, options.thresholds_path);
    defer specs.deinit(allocator);

    const started_ns = runtime.nanoTimestamp();

    var results: std.ArrayList(DocumentResult) = .empty;
    defer {
        for (results.items) |*result| result.deinit(allocator);
        results.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, manifest, '\n');
    while (line_it.next()) |raw_line| {
        const entry = try eval_runner.parseManifestLine(raw_line) orelse continue;
        for (lanes.items) |lane| {
            const result = try evaluateLane(allocator, lane, entry, expected_counts, options);
            try results.append(allocator, result);
        }
    }

    var regressions: std.ArrayList(Regression) = .empty;
    defer {
        for (regressions.items) |*regression| regression.deinit(allocator);
        regressions.deinit(allocator);
    }
    try appendRegressions(allocator, &regressions, results.items, specs.items);

    const finished_ns = runtime.nanoTimestamp();

    const json = try renderScorecardJson(allocator, .{
        .run_id = run_id,
        .suite_id = options.suite_id,
        .started_ns = started_ns,
        .finished_ns = finished_ns,
        .manifest_path = options.manifest_path,
        .metadata_path = options.metadata_path,
        .manifest_sha256 = manifest_sha256,
        .lanes = lanes.items,
        .results = results.items,
        .regressions = regressions.items,
        .specs = specs.items,
    });
    errdefer allocator.free(json);

    const jsonl = try renderScorecardJsonl(allocator, .{
        .run_id = run_id,
        .suite_id = options.suite_id,
        .started_ns = started_ns,
        .finished_ns = finished_ns,
        .manifest_path = options.manifest_path,
        .metadata_path = options.metadata_path,
        .manifest_sha256 = manifest_sha256,
        .lanes = lanes.items,
        .results = results.items,
        .regressions = regressions.items,
        .specs = specs.items,
    });
    errdefer allocator.free(jsonl);

    return .{
        .json = json,
        .jsonl = jsonl,
        .has_regression = regressions.items.len > 0,
        .skipped_count = countSkipped(results.items),
    };
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.manifest_path = args[index];
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.metadata_path = args[index];
        } else if (std.mem.eql(u8, arg, "--suite-id")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.suite_id = args[index];
        } else if (std.mem.eql(u8, arg, "--tools")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.tools = args[index];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--jsonl")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.jsonl_path = args[index];
        } else if (std.mem.eql(u8, arg, "--candidate-command")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.candidate_command = args[index];
        } else if (std.mem.eql(u8, arg, "--baseline-command")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.baseline_command = args[index];
        } else if (std.mem.eql(u8, arg, "--thresholds")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.thresholds_path = args[index];
        } else if (std.mem.eql(u8, arg, "--fail-on-regression")) {
            options.fail_on_regression = true;
        } else if (std.mem.eql(u8, arg, "--require-tools")) {
            options.require_tools = true;
        } else if (std.mem.eql(u8, arg, "--fail-on-skipped")) {
            options.fail_on_skipped = true;
        } else if (std.mem.eql(u8, arg, "--ocr-executable")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.executable = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-rasterizer")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.rasterizer_executable = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-lang")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.lang = args[index];
        } else if (std.mem.eql(u8, arg, "--ocr-dpi")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.ocr_config.dpi = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--ocr-color")) {
            options.ocr_config.rasterize_grayscale = false;
        } else if (std.mem.eql(u8, arg, "--ocr-grayscale")) {
            options.ocr_config.rasterize_grayscale = true;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn printUsage() !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = runtime.stdoutWriter(&buffer);
    const writer = &stdout_writer.interface;
    defer writer.flush() catch {};
    try writer.writeAll(
        \\pdf-parser benchmark - corpus benchmark scorecards
        \\
        \\Usage:
        \\  pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv [options]
        \\
        \\Options:
        \\  --manifest FILE          TSV corpus manifest
        \\  --metadata FILE          Optional JSONL sidecar with expected route counts
        \\  --suite-id ID            Stable suite id (default: default-suite)
        \\  --tools LIST             Comma-separated lanes, e.g. pdf-parser:adaptive,pdf-parser:native
        \\  --candidate-command CMD  pdf-parser-compatible candidate executable path
        \\  --baseline-command CMD   pdf-parser-compatible baseline executable path
        \\  --thresholds FILE        Benchmark threshold JSON
        \\  --fail-on-regression     Exit non-zero when candidate regresses against baseline
        \\  --require-tools          Treat unknown non-command tools as errors
        \\  --fail-on-skipped        Exit non-zero when any lane skips a document
        \\  --output FILE            Full scorecard JSON path
        \\  --jsonl FILE             Record-oriented scorecard JSONL path
        \\  --ocr-executable FILE    Tesseract executable for adaptive lanes
        \\  --ocr-rasterizer FILE    pdftoppm-compatible rasterizer for adaptive lanes
        \\  --ocr-dpi N              Rasterization DPI for adaptive OCR lanes (default: 200)
        \\  --ocr-color              Rasterize OCR pages as RGB instead of default grayscale
        \\  --ocr-grayscale          Rasterize OCR pages as grayscale (default)
        \\
        \\Tool lanes:
        \\  pdf-parser:native
        \\  pdf-parser:adaptive
        \\  command:<id>=<command template with optional {pdf}>
        \\
    );
}

fn parseLanes(allocator: std.mem.Allocator, options: Options) !std.ArrayList(ToolLane) {
    var lanes: std.ArrayList(ToolLane) = .empty;
    errdefer lanes.deinit(allocator);

    if (options.baseline_command) |command| {
        try lanes.append(allocator, .{
            .id = "baseline",
            .kind = .command,
            .command_template = try pdfParserCommandTemplate(allocator, command, true),
            .owns_command_template = std.mem.indexOf(u8, command, "{pdf}") == null,
        });
    }
    if (options.candidate_command) |command| {
        try lanes.append(allocator, .{
            .id = "candidate",
            .kind = .command,
            .command_template = try pdfParserCommandTemplate(allocator, command, true),
            .owns_command_template = std.mem.indexOf(u8, command, "{pdf}") == null,
        });
    }
    if (lanes.items.len > 0) return lanes;

    var split = std.mem.splitScalar(u8, options.tools, ',');
    while (split.next()) |raw_tool| {
        const tool = std.mem.trim(u8, raw_tool, " \t\r\n");
        if (tool.len == 0) continue;
        if (std.mem.eql(u8, tool, "pdf-parser:native")) {
            try lanes.append(allocator, .{ .id = "pdf-parser:native", .kind = .pdf_parser_native });
        } else if (std.mem.eql(u8, tool, "pdf-parser:adaptive") or std.mem.eql(u8, tool, "pdf-parser")) {
            try lanes.append(allocator, .{ .id = "pdf-parser:adaptive", .kind = .pdf_parser_adaptive });
        } else if (std.mem.startsWith(u8, tool, "command:")) {
            const rest = tool["command:".len..];
            const equals = std.mem.indexOfScalar(u8, rest, '=') orelse return error.MalformedToolLane;
            try lanes.append(allocator, .{
                .id = rest[0..equals],
                .kind = .command,
                .command_template = rest[equals + 1 ..],
            });
        } else if (isKnownPythonBaseline(tool)) {
            try lanes.append(allocator, .{ .id = tool, .kind = .python_baseline });
        } else if (options.require_tools) {
            return error.UnknownToolLane;
        } else {
            try lanes.append(allocator, .{ .id = tool, .kind = .skipped });
        }
    }
    if (lanes.items.len == 0) return error.NoToolLanes;
    return lanes;
}

fn pdfParserCommandTemplate(allocator: std.mem.Allocator, command: []const u8, adaptive: bool) ![]const u8 {
    if (std.mem.indexOf(u8, command, "{pdf}") != null) return command;
    return if (adaptive)
        try std.fmt.allocPrint(allocator, "{s} extract --adaptive -f text {{pdf}}", .{command})
    else
        try std.fmt.allocPrint(allocator, "{s} extract -f text {{pdf}}", .{command});
}

fn isKnownPythonBaseline(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "pymupdf") or
        std.mem.eql(u8, tool, "pypdfium2") or
        std.mem.eql(u8, tool, "pdfplumber") or
        std.mem.eql(u8, tool, "tesseract");
}

fn evaluateLane(
    allocator: std.mem.Allocator,
    lane: ToolLane,
    entry: eval_runner.ManifestEntry,
    expected_counts: []const eval_runner.ExpectedRouteCounts,
    options: Options,
) !DocumentResult {
    const start_ns = runtime.nanoTimestamp();
    switch (lane.kind) {
        .pdf_parser_native, .pdf_parser_adaptive => {
            var eval_options: eval_runner.Options = .{
                .pdf_path = entry.pdf_path,
                .truth_text_path = entry.truth_text_path,
                .truth_table_json_path = entry.truth_table_json_path,
                .truth_reading_order_path = entry.truth_reading_order_path,
                .truth_formula_path = entry.truth_formula_path,
                .truth_formula_json_path = entry.truth_formula_json_path,
                .truth_form_json_path = entry.truth_form_json_path,
                .doc_id = entry.doc_id,
                .parser = lane.id,
                .category = entry.category,
                .extraction_mode = if (lane.kind == .pdf_parser_adaptive) .adaptive else .native,
                .ocr_config = options.ocr_config,
            };
            if (lane.kind == .pdf_parser_adaptive) {
                if (eval_runner.findExpectedRouteCounts(expected_counts, entry.doc_id)) |expected| {
                    eval_options.expected_ocr_pages = expected.ocr_pages;
                    eval_options.expected_table_regions = expected.table_regions;
                    eval_options.expected_formula_regions = expected.formula_regions;
                }
            }
            const jsonl = eval_runner.evaluateOneToJsonl(allocator, eval_options) catch |err| {
                const reason = try std.fmt.allocPrint(allocator, "eval failed: {}", .{err});
                return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
            };
            defer allocator.free(jsonl);
            return parseEvalJsonlResult(allocator, jsonl, lane.id, runtime.nanoTimestamp() - start_ns);
        },
        .command => return evaluateCommandLane(allocator, lane, entry, start_ns),
        .python_baseline => {
            const reason = try allocator.dupe(u8, "use benchmark/eval/compare.py compatibility adapter or command:<id>=... for this optional baseline");
            return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
        },
        .skipped => {
            const reason = try allocator.dupe(u8, "unknown tool lane");
            return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
        },
    }
}

fn evaluateCommandLane(
    allocator: std.mem.Allocator,
    lane: ToolLane,
    entry: eval_runner.ManifestEntry,
    start_ns: i128,
) !DocumentResult {
    const command_template = lane.command_template orelse return error.MissingCommandTemplate;
    const argv = try buildCommandArgv(allocator, command_template, entry.pdf_path);
    defer freeStringList(allocator, argv);

    const run = runtime.runCapture(allocator, argv, .{ .stdout_limit = 64 * 1024 * 1024, .stderr_limit = 2 * 1024 * 1024, .timeout_ms = 120_000 }) catch |err| {
        const reason = try std.fmt.allocPrint(allocator, "command failed to start: {}", .{err});
        return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
    };
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    const exit_code: u8 = switch (run.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
        const reason = try std.fmt.allocPrint(allocator, "command exited with {d}: {s}", .{ exit_code, std.mem.trim(u8, run.stderr, " \t\r\n") });
        return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
    }

    const truth = runtime.readFileAllocAlignedCwd(allocator, entry.truth_text_path, .fromByteUnits(1)) catch |err| {
        const reason = try std.fmt.allocPrint(allocator, "truth read failed: {}", .{err});
        return skippedResult(allocator, entry, lane.id, reason, runtime.nanoTimestamp() - start_ns);
    };
    defer allocator.free(truth);

    const text_metrics = try eval.evaluateText(allocator, .{
        .prediction = run.stdout,
        .ground_truth = truth,
    });
    return .{
        .doc_id = try allocator.dupe(u8, entry.doc_id),
        .category = try allocator.dupe(u8, @tagName(entry.category)),
        .tool_id = try allocator.dupe(u8, lane.id),
        .status = "ok",
        .metrics = .{
            .cer = text_metrics.cer,
            .wer = text_metrics.wer,
            .normalized_edit_distance = text_metrics.normalized_edit_distance,
            .token_f1 = text_metrics.token_f1,
            .latency_ms = nsToMs(runtime.nanoTimestamp() - start_ns),
            .peak_rss_mb = eval.currentPeakRssMb(),
        },
        .duration_ms = nsToMs(runtime.nanoTimestamp() - start_ns),
    };
}

fn buildCommandArgv(allocator: std.mem.Allocator, template: []const u8, pdf_path: []const u8) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    var saw_pdf = false;
    var tokens = std.mem.tokenizeAny(u8, template, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "{pdf}")) {
            try argv.append(allocator, try allocator.dupe(u8, pdf_path));
            saw_pdf = true;
        } else {
            try argv.append(allocator, try allocator.dupe(u8, token));
        }
    }
    if (!saw_pdf) try argv.append(allocator, try allocator.dupe(u8, pdf_path));
    return argv.toOwnedSlice(allocator);
}

fn skippedResult(
    allocator: std.mem.Allocator,
    entry: eval_runner.ManifestEntry,
    lane_id: []const u8,
    reason: []u8,
    elapsed_ns: i128,
) !DocumentResult {
    return .{
        .doc_id = try allocator.dupe(u8, entry.doc_id),
        .category = try allocator.dupe(u8, @tagName(entry.category)),
        .tool_id = try allocator.dupe(u8, lane_id),
        .status = "skipped",
        .reason = reason,
        .duration_ms = nsToMs(elapsed_ns),
    };
}

fn parseEvalJsonlResult(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
    lane_id: []const u8,
    duration_ns: i128,
) !DocumentResult {
    const line_end = std.mem.indexOfScalar(u8, jsonl, '\n') orelse jsonl.len;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, jsonl[0..line_end], .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    const metrics_object = object.get("metrics").?.object;
    const pages = jsonU32(object.get("pages"));
    return .{
        .doc_id = try allocator.dupe(u8, object.get("doc_id").?.string),
        .category = try allocator.dupe(u8, object.get("category").?.string),
        .tool_id = try allocator.dupe(u8, lane_id),
        .status = "ok",
        .pages = pages,
        .metrics = .{
            .cer = jsonFloat(metrics_object.get("cer")),
            .wer = jsonFloat(metrics_object.get("wer")),
            .normalized_edit_distance = jsonFloat(metrics_object.get("normalized_edit_distance")),
            .token_f1 = jsonFloat(metrics_object.get("token_f1")),
            .reading_order_score = jsonFloat(metrics_object.get("reading_order_score")),
            .table_cell_accuracy = jsonFloat(metrics_object.get("table_cell_accuracy")),
            .table_span_accuracy = jsonFloat(metrics_object.get("table_span_accuracy")),
            .table_role_accuracy = jsonFloat(metrics_object.get("table_role_accuracy")),
            .table_rowspan_accuracy = jsonFloat(metrics_object.get("table_rowspan_accuracy")),
            .table_colspan_accuracy = jsonFloat(metrics_object.get("table_colspan_accuracy")),
            .table_page_accuracy = jsonFloat(metrics_object.get("table_page_accuracy")),
            .table_continuation_accuracy = jsonFloat(metrics_object.get("table_continuation_accuracy")),
            .table_source_span_coverage = jsonFloat(metrics_object.get("table_source_span_coverage")),
            .table_bbox_iou = jsonFloat(metrics_object.get("table_bbox_iou")),
            .table_numeric_accuracy = jsonFloat(metrics_object.get("table_numeric_accuracy")),
            .table_header_accuracy = jsonFloat(metrics_object.get("table_header_accuracy")),
            .table_footnote_accuracy = jsonFloat(metrics_object.get("table_footnote_accuracy")),
            .formula_structure_accuracy = jsonFloat(metrics_object.get("formula_structure_accuracy")),
            .form_field_accuracy = jsonFloat(metrics_object.get("form_field_accuracy")),
            .latency_ms = jsonFloat(metrics_object.get("median_ms_per_page")),
            .peak_rss_mb = jsonFloat(metrics_object.get("peak_rss_mb")),
        },
        .counters = .{
            .native_pages = nativePagesFromRatio(jsonFloat(object.get("native_text_ratio")), pages),
            .ocr_pages = jsonU32Optional(object.get("ocr_pages")),
            .table_regions = jsonU32Optional(object.get("table_regions")),
            .formula_regions = jsonU32Optional(object.get("formula_regions")),
        },
        .duration_ms = nsToMs(duration_ns),
    };
}

fn nativePagesFromRatio(ratio: ?f64, pages: u32) ?u32 {
    const value = ratio orelse return null;
    if (value < 0) return null;
    return @intFromFloat(@round(value * @as(f64, @floatFromInt(pages))));
}

fn jsonFloat(value: ?std.json.Value) ?f64 {
    const actual = value orelse return null;
    return switch (actual) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn jsonU32(value: ?std.json.Value) u32 {
    return jsonU32Optional(value) orelse 0;
}

fn jsonU32Optional(value: ?std.json.Value) ?u32 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0) @intFromFloat(number) else null,
        else => null,
    };
}

fn loadMetricSpecs(allocator: std.mem.Allocator, thresholds_path: ?[]const u8) !std.ArrayList(MetricSpec) {
    var specs: std.ArrayList(MetricSpec) = .empty;
    errdefer specs.deinit(allocator);
    try specs.appendSlice(allocator, &default_specs);
    const path = thresholds_path orelse return specs;

    const bytes = try runtime.readFileAllocAlignedCwd(allocator, path, .fromByteUnits(1));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const metrics = parsed.value.object.get("metrics") orelse return specs;
    if (metrics != .object) return specs;
    var it = metrics.object.iterator();
    while (it.next()) |entry| {
        const metric_name = std.meta.stringToEnum(MetricName, entry.key_ptr.*) orelse continue;
        const index = findSpecIndex(specs.items, metric_name) orelse continue;
        if (entry.value_ptr.* != .object) continue;
        const metric_object = entry.value_ptr.object;
        if (metric_object.get("direction")) |direction_value| {
            if (direction_value == .string) {
                specs.items[index].direction = std.meta.stringToEnum(MetricDirection, direction_value.string) orelse specs.items[index].direction;
            }
        }
        if (jsonFloat(metric_object.get("max_regression"))) |max_regression| {
            specs.items[index].max_regression = max_regression;
        }
        if (metric_object.get("required")) |required_value| {
            if (required_value == .bool) specs.items[index].required = required_value.bool;
        }
    }
    return specs;
}

fn findSpecIndex(specs: []const MetricSpec, metric: MetricName) ?usize {
    for (specs, 0..) |spec, index| {
        if (spec.name == metric) return index;
    }
    return null;
}

fn appendRegressions(
    allocator: std.mem.Allocator,
    regressions: *std.ArrayList(Regression),
    results: []const DocumentResult,
    specs: []const MetricSpec,
) !void {
    for (results) |candidate| {
        if (!std.mem.eql(u8, candidate.tool_id, "candidate") or !std.mem.eql(u8, candidate.status, "ok")) continue;
        const baseline = findResult(results, "baseline", candidate.doc_id) orelse continue;
        if (!std.mem.eql(u8, baseline.status, "ok")) continue;
        for (specs) |spec| {
            const candidate_value = metricValue(candidate.metrics, spec.name);
            const baseline_value = metricValue(baseline.metrics, spec.name);
            if (candidate_value == null or baseline_value == null) {
                if (spec.required) {
                    try regressions.append(allocator, .{
                        .doc_id = try allocator.dupe(u8, candidate.doc_id),
                        .category = try allocator.dupe(u8, candidate.category),
                        .metric = spec.name,
                        .baseline_value = baseline_value,
                        .candidate_value = candidate_value,
                        .delta = null,
                        .threshold = spec.max_regression,
                        .direction = spec.direction,
                        .status = "missing_required_metric",
                    });
                }
                continue;
            }
            const delta = candidate_value.? - baseline_value.?;
            const regressed = switch (spec.direction) {
                .lower => delta > spec.max_regression,
                .higher => delta < -spec.max_regression,
            };
            if (!regressed) continue;
            try regressions.append(allocator, .{
                .doc_id = try allocator.dupe(u8, candidate.doc_id),
                .category = try allocator.dupe(u8, candidate.category),
                .metric = spec.name,
                .baseline_value = baseline_value,
                .candidate_value = candidate_value,
                .delta = delta,
                .threshold = spec.max_regression,
                .direction = spec.direction,
                .status = "regressed",
            });
        }
    }
}

fn findResult(results: []const DocumentResult, tool_id: []const u8, doc_id: []const u8) ?DocumentResult {
    for (results) |result| {
        if (std.mem.eql(u8, result.tool_id, tool_id) and std.mem.eql(u8, result.doc_id, doc_id)) return result;
    }
    return null;
}

const RenderContext = struct {
    run_id: []const u8,
    suite_id: []const u8,
    started_ns: i128,
    finished_ns: i128,
    manifest_path: []const u8,
    metadata_path: ?[]const u8,
    manifest_sha256: []const u8,
    lanes: []const ToolLane,
    results: []const DocumentResult,
    regressions: []const Regression,
    specs: []const MetricSpec,
};

fn renderScorecardJson(allocator: std.mem.Allocator, ctx: RenderContext) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_scorecard", ctx, null, null);
    try writer.print(",\"status\":\"{s}\"", .{if (ctx.regressions.len == 0) "pass" else "fail"});
    try writer.print(",\"started_ns\":{},\"finished_ns\":{},\"duration_ms\":{d:.6}", .{ ctx.started_ns, ctx.finished_ns, nsToMs(ctx.finished_ns - ctx.started_ns) });
    try writer.print(",\"lane_count\":{},\"document_result_count\":{},\"regression_count\":{}", .{ ctx.lanes.len, ctx.results.len, ctx.regressions.len });
    try writer.writeAll(",\"manifest_path\":\"");
    try writeJsonEscaped(writer, ctx.manifest_path);
    try writer.writeAll("\",\"metadata_path\":");
    try writeOptionalString(writer, ctx.metadata_path);

    try writer.writeAll(",\"lanes\":[");
    for (ctx.lanes, 0..) |lane, index| {
        if (index > 0) try writer.writeByte(',');
        try writeLaneRecord(writer, ctx, lane);
    }
    try writer.writeByte(']');

    try writer.writeAll(",\"document_results\":[");
    for (ctx.results, 0..) |result, index| {
        if (index > 0) try writer.writeByte(',');
        try writeDocumentResultRecord(writer, ctx, result);
    }
    try writer.writeByte(']');

    try writer.writeAll(",\"category_summaries\":[");
    try writeCategorySummaries(writer, ctx, false);
    try writer.writeByte(']');

    try writer.writeAll(",\"regressions\":[");
    for (ctx.regressions, 0..) |regression, index| {
        if (index > 0) try writer.writeByte(',');
        try writeRegressionRecord(writer, ctx, regression);
    }
    try writer.writeByte(']');

    try writer.writeAll(",\"thresholds\":[");
    for (ctx.specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        try writeMetricSpec(writer, spec);
    }
    try writer.writeByte(']');

    try writer.writeAll("}\n");
    return out.toOwnedSlice(allocator);
}

fn renderScorecardJsonl(allocator: std.mem.Allocator, ctx: RenderContext) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = runtime.arrayListWriter(&out, allocator);

    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_run", ctx, null, null);
    try writer.print(",\"status\":\"{s}\",\"started_ns\":{},\"finished_ns\":{},\"duration_ms\":{d:.6},\"manifest_path\":\"", .{
        if (ctx.regressions.len == 0) "pass" else "fail",
        ctx.started_ns,
        ctx.finished_ns,
        nsToMs(ctx.finished_ns - ctx.started_ns),
    });
    try writeJsonEscaped(writer, ctx.manifest_path);
    try writer.writeAll("\",\"metadata_path\":");
    try writeOptionalString(writer, ctx.metadata_path);
    try writer.writeAll("}\n");

    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_suite", ctx, null, null);
    try writer.print(",\"lane_count\":{},\"document_result_count\":{}}}\n", .{ ctx.lanes.len, ctx.results.len });

    for (ctx.lanes) |lane| {
        try writeLaneRecord(writer, ctx, lane);
        try writer.writeByte('\n');
    }
    for (ctx.results) |result| {
        try writeDocumentResultRecord(writer, ctx, result);
        try writer.writeByte('\n');
    }
    try writeCategorySummaries(writer, ctx, true);
    if (categorySummaryCount(ctx) > 0) try writer.writeByte('\n');
    for (ctx.regressions) |regression| {
        try writeRegressionRecord(writer, ctx, regression);
        try writer.writeByte('\n');
    }

    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_scorecard", ctx, null, null);
    try writer.print(",\"status\":\"{s}\",\"regression_count\":{}}}\n", .{ if (ctx.regressions.len == 0) "pass" else "fail", ctx.regressions.len });
    return out.toOwnedSlice(allocator);
}

fn writeLaneRecord(writer: anytype, ctx: RenderContext, lane: ToolLane) !void {
    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_lane", ctx, lane.id, null);
    try writer.print(",\"tool_kind\":\"{s}\",\"status\":\"enabled\"}}", .{@tagName(lane.kind)});
}

fn writeDocumentResultRecord(writer: anytype, ctx: RenderContext, result: DocumentResult) !void {
    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_document_result", ctx, result.tool_id, result.category);
    try writer.writeAll(",\"doc_id\":\"");
    try writeJsonEscaped(writer, result.doc_id);
    try writer.print("\",\"status\":\"{s}\",\"pages\":{}", .{ result.status, result.pages });
    try writer.writeAll(",\"reason\":");
    try writeOptionalString(writer, result.reason);
    try writer.writeAll(",\"metrics\":");
    try writeMetrics(writer, result.metrics);
    try writer.writeAll(",\"counters\":");
    try writeCounters(writer, result.counters);
    try writer.writeAll(",\"route_deltas\":");
    try writeRouteDeltas(writer, ctx, result);
    try writer.writeAll(",\"duration_ms\":");
    try writeOptionalFloat(writer, result.duration_ms);
    try writer.writeByte('}');
}

fn writeCategorySummaries(writer: anytype, ctx: RenderContext, jsonl: bool) !void {
    var first = true;
    for (ctx.lanes) |lane| {
        for (eval.corpus_categories) |category| {
            const category_name = @tagName(category);
            if (!hasGroup(ctx.results, lane.id, category_name)) continue;
            if (!first) {
                if (jsonl) try writer.writeByte('\n') else try writer.writeByte(',');
            }
            first = false;
            try writer.writeByte('{');
            try writeRecordCommon(writer, "benchmark_category_summary", ctx, lane.id, category_name);
            const counts = groupCounts(ctx.results, lane.id, category_name);
            try writer.print(",\"count\":{},\"skipped_count\":{},\"metrics\":{{", .{ counts.count, counts.skipped });
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .cer);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .wer);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .token_f1);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .table_cell_accuracy);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .table_numeric_accuracy);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .table_bbox_iou);
            try writer.writeByte(',');
            try writeMetricAggregate(writer, ctx.results, lane.id, category_name, .latency_ms);
            try writer.writeAll("}}");
        }
    }
}

fn writeRegressionRecord(writer: anytype, ctx: RenderContext, regression: Regression) !void {
    try writer.writeByte('{');
    try writeRecordCommon(writer, "benchmark_regression", ctx, "candidate", regression.category);
    try writer.writeAll(",\"doc_id\":\"");
    try writeJsonEscaped(writer, regression.doc_id);
    try writer.print("\",\"metric\":\"{s}\",\"status\":\"{s}\",\"direction\":\"{s}\",\"threshold\":{d:.6}", .{
        @tagName(regression.metric),
        regression.status,
        @tagName(regression.direction),
        regression.threshold,
    });
    try writer.writeAll(",\"baseline_value\":");
    try writeOptionalFloat(writer, regression.baseline_value);
    try writer.writeAll(",\"candidate_value\":");
    try writeOptionalFloat(writer, regression.candidate_value);
    try writer.writeAll(",\"delta\":");
    try writeOptionalFloat(writer, regression.delta);
    try writer.writeByte('}');
}

fn writeRecordCommon(writer: anytype, record_type: []const u8, ctx: RenderContext, tool_id: ?[]const u8, category: ?[]const u8) !void {
    try writer.writeAll("\"benchmark_schema_version\":\"");
    try writer.writeAll(benchmark_schema_version);
    try writer.writeAll("\",\"record_type\":\"");
    try writer.writeAll(record_type);
    try writer.writeAll("\",\"run_id\":\"");
    try writeJsonEscaped(writer, ctx.run_id);
    try writer.writeAll("\",\"suite_id\":\"");
    try writeJsonEscaped(writer, ctx.suite_id);
    try writer.writeAll("\",\"manifest_sha256\":\"");
    try writer.writeAll(ctx.manifest_sha256);
    try writer.writeAll("\",\"tool_id\":");
    try writeOptionalString(writer, tool_id);
    try writer.writeAll(",\"category\":");
    try writeOptionalString(writer, category);
}

fn writeMetrics(writer: anytype, metrics: Metrics) !void {
    try writer.writeByte('{');
    inline for (std.meta.fields(MetricName), 0..) |field, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("\"{s}\":", .{field.name});
        try writeOptionalFloat(writer, metricValue(metrics, @field(MetricName, field.name)));
    }
    try writer.writeByte('}');
}

fn writeCounters(writer: anytype, counters: Counters) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"native_pages\":");
    try writeOptionalInteger(writer, counters.native_pages);
    try writer.writeAll(",\"ocr_pages\":");
    try writeOptionalInteger(writer, counters.ocr_pages);
    try writer.writeAll(",\"table_regions\":");
    try writeOptionalInteger(writer, counters.table_regions);
    try writer.writeAll(",\"formula_regions\":");
    try writeOptionalInteger(writer, counters.formula_regions);
    try writer.writeByte('}');
}

fn writeRouteDeltas(writer: anytype, ctx: RenderContext, result: DocumentResult) !void {
    if (!std.mem.eql(u8, result.tool_id, "candidate")) {
        try writer.writeAll("null");
        return;
    }
    const baseline = findResult(ctx.results, "baseline", result.doc_id) orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeByte('{');
    try writer.writeAll("\"ocr_pages\":");
    try writeOptionalSignedInteger(writer, optionalU32Delta(result.counters.ocr_pages, baseline.counters.ocr_pages));
    try writer.writeAll(",\"table_regions\":");
    try writeOptionalSignedInteger(writer, optionalU32Delta(result.counters.table_regions, baseline.counters.table_regions));
    try writer.writeAll(",\"formula_regions\":");
    try writeOptionalSignedInteger(writer, optionalU32Delta(result.counters.formula_regions, baseline.counters.formula_regions));
    try writer.writeByte('}');
}

fn optionalU32Delta(candidate: ?u32, baseline: ?u32) ?i64 {
    const c = candidate orelse return null;
    const b = baseline orelse return null;
    return @as(i64, @intCast(c)) - @as(i64, @intCast(b));
}

fn writeMetricAggregate(writer: anytype, results: []const DocumentResult, tool_id: []const u8, category: []const u8, metric: MetricName) !void {
    var count: usize = 0;
    var sum: f64 = 0;
    var worst: ?f64 = null;
    const direction = (defaultSpec(metric) orelse default_specs[0]).direction;
    for (results) |result| {
        if (!std.mem.eql(u8, result.tool_id, tool_id) or !std.mem.eql(u8, result.category, category)) continue;
        const value = metricValue(result.metrics, metric) orelse continue;
        count += 1;
        sum += value;
        worst = if (worst) |current| switch (direction) {
            .lower => @max(current, value),
            .higher => @min(current, value),
        } else value;
    }
    try writer.print("\"{s}\":{{\"count\":{},\"mean\":", .{ @tagName(metric), count });
    try writeOptionalFloat(writer, if (count == 0) null else sum / @as(f64, @floatFromInt(count)));
    try writer.writeAll(",\"worst\":");
    try writeOptionalFloat(writer, worst);
    try writer.writeByte('}');
}

fn writeMetricSpec(writer: anytype, spec: MetricSpec) !void {
    try writer.print("{{\"metric\":\"{s}\",\"direction\":\"{s}\",\"max_regression\":{d:.6},\"required\":{s}}}", .{
        @tagName(spec.name),
        @tagName(spec.direction),
        spec.max_regression,
        if (spec.required) "true" else "false",
    });
}

fn metricValue(metrics: Metrics, metric: MetricName) ?f64 {
    return switch (metric) {
        .cer => metrics.cer,
        .wer => metrics.wer,
        .normalized_edit_distance => metrics.normalized_edit_distance,
        .token_f1 => metrics.token_f1,
        .reading_order_score => metrics.reading_order_score,
        .table_cell_accuracy => metrics.table_cell_accuracy,
        .table_span_accuracy => metrics.table_span_accuracy,
        .table_role_accuracy => metrics.table_role_accuracy,
        .table_rowspan_accuracy => metrics.table_rowspan_accuracy,
        .table_colspan_accuracy => metrics.table_colspan_accuracy,
        .table_page_accuracy => metrics.table_page_accuracy,
        .table_continuation_accuracy => metrics.table_continuation_accuracy,
        .table_source_span_coverage => metrics.table_source_span_coverage,
        .table_bbox_iou => metrics.table_bbox_iou,
        .table_numeric_accuracy => metrics.table_numeric_accuracy,
        .table_header_accuracy => metrics.table_header_accuracy,
        .table_footnote_accuracy => metrics.table_footnote_accuracy,
        .formula_structure_accuracy => metrics.formula_structure_accuracy,
        .form_field_accuracy => metrics.form_field_accuracy,
        .latency_ms => metrics.latency_ms,
        .peak_rss_mb => metrics.peak_rss_mb,
    };
}

fn defaultSpec(metric: MetricName) ?MetricSpec {
    for (default_specs) |spec| {
        if (spec.name == metric) return spec;
    }
    return null;
}

const GroupCounts = struct {
    count: usize = 0,
    skipped: usize = 0,
};

fn groupCounts(results: []const DocumentResult, tool_id: []const u8, category: []const u8) GroupCounts {
    var counts: GroupCounts = .{};
    for (results) |result| {
        if (!std.mem.eql(u8, result.tool_id, tool_id) or !std.mem.eql(u8, result.category, category)) continue;
        counts.count += 1;
        if (!std.mem.eql(u8, result.status, "ok")) counts.skipped += 1;
    }
    return counts;
}

fn hasGroup(results: []const DocumentResult, tool_id: []const u8, category: []const u8) bool {
    return groupCounts(results, tool_id, category).count > 0;
}

fn categorySummaryCount(ctx: RenderContext) usize {
    var count: usize = 0;
    for (ctx.lanes) |lane| {
        for (eval.corpus_categories) |category| {
            if (hasGroup(ctx.results, lane.id, @tagName(category))) count += 1;
        }
    }
    return count;
}

fn countSkipped(results: []const DocumentResult) usize {
    var count: usize = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.status, "ok")) count += 1;
    }
    return count;
}

fn writeOptionalFloat(writer: anytype, value: ?f64) !void {
    if (value) |number| {
        try writer.print("{d:.6}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalInteger(writer: anytype, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalSignedInteger(writer: anytype, value: ?i64) !void {
    if (value) |number| {
        try writer.print("{}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeByte('"');
        try writeJsonEscaped(writer, text);
        try writer.writeByte('"');
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => {
                if (byte < 0x20) {
                    try writer.print("\\u00{X:0>2}", .{byte});
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
    }
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

test "benchmark threshold regression directions" {
    var regressions: std.ArrayList(Regression) = .empty;
    defer {
        for (regressions.items) |*regression| regression.deinit(std.testing.allocator);
        regressions.deinit(std.testing.allocator);
    }
    const results = [_]DocumentResult{
        .{
            .doc_id = @constCast("doc"),
            .category = @constCast("clean_born_digital"),
            .tool_id = @constCast("baseline"),
            .status = "ok",
            .metrics = .{ .token_f1 = 0.99, .cer = 0.01 },
        },
        .{
            .doc_id = @constCast("doc"),
            .category = @constCast("clean_born_digital"),
            .tool_id = @constCast("candidate"),
            .status = "ok",
            .metrics = .{ .token_f1 = 0.90, .cer = 0.08 },
        },
    };
    try appendRegressions(std.testing.allocator, &regressions, &results, &.{
        .{ .name = .token_f1, .direction = .higher, .max_regression = 0.02 },
        .{ .name = .cer, .direction = .lower, .max_regression = 0.02 },
    });
    try std.testing.expectEqual(@as(usize, 2), regressions.items.len);
}

test "benchmark command argv replaces pdf token" {
    const argv = try buildCommandArgv(std.testing.allocator, "tool --input {pdf}", "fixture.pdf");
    defer freeStringList(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("fixture.pdf", argv[2]);
}

test "benchmark scorecard JSONL records parse line by line" {
    const allocator = std.testing.allocator;
    const ctx = RenderContext{
        .run_id = "run-1",
        .suite_id = "suite",
        .started_ns = 1,
        .finished_ns = 2,
        .manifest_path = "manifest.tsv",
        .metadata_path = null,
        .manifest_sha256 = "abc",
        .lanes = &.{.{ .id = "pdf-parser:native", .kind = .pdf_parser_native }},
        .results = &.{.{
            .doc_id = @constCast("doc"),
            .category = @constCast("clean_born_digital"),
            .tool_id = @constCast("pdf-parser:native"),
            .status = "ok",
            .metrics = .{ .token_f1 = 1.0 },
        }},
        .regressions = &.{},
        .specs = &default_specs,
    };
    const jsonl = try renderScorecardJsonl(allocator, ctx);
    defer allocator.free(jsonl);
    var lines = std.mem.splitScalar(u8, jsonl, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            benchmark_schema_version,
            parsed.value.object.get("benchmark_schema_version").?.string,
        );
        if (std.mem.eql(u8, parsed.value.object.get("record_type").?.string, "benchmark_document_result")) {
            const metrics = parsed.value.object.get("metrics").?.object;
            try std.testing.expect(metrics.get("table_bbox_iou") != null);
            try std.testing.expect(metrics.get("table_numeric_accuracy") != null);
            try std.testing.expect(metrics.get("table_header_accuracy") != null);
            try std.testing.expect(metrics.get("table_footnote_accuracy") != null);
        }
        count += 1;
    }
    try std.testing.expect(count >= 4);
}

test "benchmark runner evaluates private manifest with native and adaptive lanes" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    const testpdf = @import("testpdf.zig");
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Benchmark Native");
    defer allocator.free(pdf_data);

    var pdf_buf: [96]u8 = undefined;
    const pdf_path = try std.fmt.bufPrint(&pdf_buf, "pdf-parser-benchmark-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(pdf_path);
    defer runtime.deleteFileCwd(pdf_path);
    const pdf_file = try runtime.createFileCwd(pdf_path);
    try runtime.writeAllFile(pdf_file, pdf_data);
    runtime.closeFile(pdf_file);

    var truth_buf: [96]u8 = undefined;
    const truth_path = try std.fmt.bufPrint(&truth_buf, "pdf-parser-benchmark-{x}.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(truth_path);
    defer runtime.deleteFileCwd(truth_path);
    const truth_file = try runtime.createFileCwd(truth_path);
    try runtime.writeAllFile(truth_file, "Benchmark Native\n");
    runtime.closeFile(truth_file);

    var manifest_buf: [96]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_buf, "pdf-parser-benchmark-{x}.tsv", .{std.testing.random_seed});
    runtime.deleteFileCwd(manifest_path);
    defer runtime.deleteFileCwd(manifest_path);
    const manifest = try std.fmt.allocPrint(
        allocator,
        "clean_born_digital\tbench-doc\t{s}\t{s}\n",
        .{ pdf_path, truth_path },
    );
    defer allocator.free(manifest);
    const manifest_file = try runtime.createFileCwd(manifest_path);
    try runtime.writeAllFile(manifest_file, manifest);
    runtime.closeFile(manifest_file);

    var result = try runBenchmark(allocator, .{
        .manifest_path = manifest_path,
        .suite_id = "private-suite",
        .tools = "pdf-parser:native,pdf-parser:adaptive,pymupdf",
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.has_regression);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_count);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"record_type\":\"benchmark_scorecard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"suite_id\":\"private-suite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"tool_id\":\"pdf-parser:native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"tool_id\":\"pdf-parser:adaptive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"tool_id\":\"pymupdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.jsonl, "\"record_type\":\"benchmark_category_summary\"") != null);
}

test "benchmark runner compares baseline and candidate command lanes" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());

    var pdf_buf: [96]u8 = undefined;
    const pdf_path = try std.fmt.bufPrint(&pdf_buf, "pdf-parser-benchmark-command-{x}.pdf", .{std.testing.random_seed});
    runtime.deleteFileCwd(pdf_path);
    defer runtime.deleteFileCwd(pdf_path);
    const pdf_file = try runtime.createFileCwd(pdf_path);
    try runtime.writeAllFile(pdf_file, "%PDF-1.4\n%%EOF\n");
    runtime.closeFile(pdf_file);

    var truth_buf: [96]u8 = undefined;
    const truth_path = try std.fmt.bufPrint(&truth_buf, "pdf-parser-benchmark-command-{x}.txt", .{std.testing.random_seed});
    runtime.deleteFileCwd(truth_path);
    defer runtime.deleteFileCwd(truth_path);
    const truth_file = try runtime.createFileCwd(truth_path);
    try runtime.writeAllFile(truth_file, "same output\n");
    runtime.closeFile(truth_file);

    var manifest_buf: [96]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_buf, "pdf-parser-benchmark-command-{x}.tsv", .{std.testing.random_seed});
    runtime.deleteFileCwd(manifest_path);
    defer runtime.deleteFileCwd(manifest_path);
    const manifest = try std.fmt.allocPrint(
        allocator,
        "clean_born_digital\tcommand-doc\t{s}\t{s}\n",
        .{ pdf_path, truth_path },
    );
    defer allocator.free(manifest);
    const manifest_file = try runtime.createFileCwd(manifest_path);
    try runtime.writeAllFile(manifest_file, manifest);
    runtime.closeFile(manifest_file);

    var result = try runBenchmark(allocator, .{
        .manifest_path = manifest_path,
        .suite_id = "command-suite",
        .baseline_command = "/bin/echo same output",
        .candidate_command = "/bin/echo same output",
    });
    defer result.deinit(allocator);

    try std.testing.expect(!result.has_regression);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"tool_id\":\"baseline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"tool_id\":\"candidate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"regression_count\":0") != null);
}
