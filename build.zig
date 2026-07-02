const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tesseract_c = b.option(
        bool,
        "tesseract-c",
        "Enable optional libtesseract C API OCR backend",
    ) orelse false;
    const tesseract_include = b.option(
        []const u8,
        "tesseract-include",
        "Directory containing tesseract/capi.h for optional C FFI backend",
    ) orelse "/opt/homebrew/include";
    const tesseract_lib = b.option(
        []const u8,
        "tesseract-lib",
        "Directory containing libtesseract and libleptonica for optional C FFI backend",
    ) orelse "/opt/homebrew/lib";
    const ocr_options = b.addOptions();
    ocr_options.addOption(bool, "enable_tesseract_c", enable_tesseract_c);
    const ocr_build = OcrBuildOptions{
        .options = ocr_options,
        .enable_tesseract_c = enable_tesseract_c,
        .tesseract_include = tesseract_include,
        .tesseract_lib = tesseract_lib,
    };

    // Main library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/root.zig", target, optimize, ocr_build),
    });

    b.installArtifact(lib);

    // Shared library for Python/FFI bindings. Exported C symbols keep the
    // zpdf_* prefix for compatibility during the package rename.
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/capi.zig", target, optimize, ocr_build),
    });

    b.installArtifact(shared_lib);

    const shared_step = b.step("shared", "Build shared library for FFI");
    shared_step.dependOn(&shared_lib.step);

    // WebAssembly build
    const wasm = b.addExecutable(.{
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/wapi.zig", b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }), .ReleaseSmall, ocr_build),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const wasm_step = b.step("wasm", "Build WebAssembly module");
    const install_wasm = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&install_wasm.step);

    // CLI tool
    const exe = b.addExecutable(.{
        .name = "pdf-parser",
        .root_module = parserModule(b, "src/main.zig", target, optimize, ocr_build),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the pdf-parser CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/root.zig", target, optimize, ocr_build),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const simd_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/simd.zig", target, optimize, ocr_build),
    });

    const run_simd_unit_tests = b.addRunArtifact(simd_unit_tests);

    const decompress_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/decompress.zig", target, optimize, ocr_build),
    });

    const run_decompress_unit_tests = b.addRunArtifact(decompress_unit_tests);

    const parser_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/parser.zig", target, optimize, ocr_build),
    });

    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);

    const xref_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/xref.zig", target, optimize, ocr_build),
    });

    const run_xref_unit_tests = b.addRunArtifact(xref_unit_tests);

    const encoding_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/encoding.zig", target, optimize, ocr_build),
    });

    const run_encoding_unit_tests = b.addRunArtifact(encoding_unit_tests);

    const runtime_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/runtime.zig", target, optimize, ocr_build),
    });

    const run_runtime_unit_tests = b.addRunArtifact(runtime_unit_tests);

    const layout_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/layout.zig", target, optimize, ocr_build),
    });

    const run_layout_unit_tests = b.addRunArtifact(layout_unit_tests);

    const complexity_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/complexity.zig", target, optimize, ocr_build),
    });

    const run_complexity_unit_tests = b.addRunArtifact(complexity_unit_tests);

    const specialists_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/specialists.zig", target, optimize, ocr_build),
    });

    const run_specialists_unit_tests = b.addRunArtifact(specialists_unit_tests);

    const specialist_protocol_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/specialist_protocol.zig", target, optimize, ocr_build),
    });

    const run_specialist_protocol_unit_tests = b.addRunArtifact(specialist_protocol_unit_tests);

    const reconcile_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/reconcile.zig", target, optimize, ocr_build),
    });

    const run_reconcile_unit_tests = b.addRunArtifact(reconcile_unit_tests);

    const schema_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/schema.zig", target, optimize, ocr_build),
    });

    const run_schema_unit_tests = b.addRunArtifact(schema_unit_tests);

    const stream_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/stream.zig", target, optimize, ocr_build),
    });

    const run_stream_unit_tests = b.addRunArtifact(stream_unit_tests);

    const adaptive_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/adaptive.zig", target, optimize, ocr_build),
    });

    const run_adaptive_unit_tests = b.addRunArtifact(adaptive_unit_tests);

    const main_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/main.zig", target, optimize, ocr_build),
    });

    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);

    const eval_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/eval.zig", target, optimize, ocr_build),
    });

    const run_eval_unit_tests = b.addRunArtifact(eval_unit_tests);

    const eval_runner_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/eval_runner.zig", target, optimize, ocr_build),
    });

    const run_eval_runner_unit_tests = b.addRunArtifact(eval_runner_unit_tests);

    const ocr_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/ocr.zig", target, optimize, ocr_build),
    });

    const run_ocr_unit_tests = b.addRunArtifact(ocr_unit_tests);

    const ocr_step = b.step("ocr-test", "Run OCR adapter unit tests");
    ocr_step.dependOn(&run_ocr_unit_tests.step);

    if (enable_tesseract_c) {
        const tesseract_c_unit_tests = b.addTest(.{
            .root_module = parserModule(b, "src/ocr.zig", target, optimize, ocr_build),
        });
        const run_tesseract_c_unit_tests = b.addRunArtifact(tesseract_c_unit_tests);
        ocr_step.dependOn(&run_tesseract_c_unit_tests.step);

        const tesseract_c_ffi_unit_tests = b.addTest(.{
            .root_module = parserModule(b, "src/ocr/tesseract_c_ffi.zig", target, optimize, ocr_build),
        });
        const run_tesseract_c_ffi_unit_tests = b.addRunArtifact(tesseract_c_ffi_unit_tests);
        ocr_step.dependOn(&run_tesseract_c_ffi_unit_tests.step);
    }

    const interpreter_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/interpreter.zig", target, optimize, ocr_build),
    });

    const run_interpreter_unit_tests = b.addRunArtifact(interpreter_unit_tests);

    const testpdf_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/testpdf.zig", target, optimize, ocr_build),
    });

    const run_testpdf_unit_tests = b.addRunArtifact(testpdf_unit_tests);

    const integration_tests = b.addTest(.{
        .root_module = parserModule(b, "src/integration_test.zig", target, optimize, ocr_build),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const native_eval_tests = b.addTest(.{
        .root_module = parserModule(b, "src/native_eval.zig", target, optimize, ocr_build),
    });

    const run_native_eval_tests = b.addRunArtifact(native_eval_tests);

    const native_eval_step = b.step("native-eval", "Run native extraction correctness fixtures");
    native_eval_step.dependOn(&run_native_eval_tests.step);

    const eval_corpus_exe = b.addExecutable(.{
        .name = "pdf-parser-eval-corpus",
        .root_module = parserModule(b, "src/eval_corpus_writer.zig", target, optimize, ocr_build),
    });
    const eval_corpus_cmd = b.addRunArtifact(eval_corpus_exe);
    if (b.args) |args| {
        eval_corpus_cmd.addArgs(args);
    }

    const eval_corpus_step = b.step("eval-corpus", "Generate tiny evaluation corpus fixtures");
    eval_corpus_step.dependOn(&eval_corpus_cmd.step);

    const eval_exe = b.addExecutable(.{
        .name = "pdf-parser-eval",
        .root_module = parserModule(b, "src/eval_runner.zig", target, optimize, ocr_build),
    });
    b.installArtifact(eval_exe);

    const eval_cmd = b.addRunArtifact(eval_exe);
    eval_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        eval_cmd.addArgs(args);
    }

    const eval_step = b.step("eval", "Run per-document evaluation and emit JSONL");
    eval_step.dependOn(&eval_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_simd_unit_tests.step);
    test_step.dependOn(&run_decompress_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_xref_unit_tests.step);
    test_step.dependOn(&run_encoding_unit_tests.step);
    test_step.dependOn(&run_runtime_unit_tests.step);
    test_step.dependOn(&run_layout_unit_tests.step);
    test_step.dependOn(&run_complexity_unit_tests.step);
    test_step.dependOn(&run_specialists_unit_tests.step);
    test_step.dependOn(&run_specialist_protocol_unit_tests.step);
    test_step.dependOn(&run_reconcile_unit_tests.step);
    test_step.dependOn(&run_schema_unit_tests.step);
    test_step.dependOn(&run_stream_unit_tests.step);
    test_step.dependOn(&run_adaptive_unit_tests.step);
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_eval_unit_tests.step);
    test_step.dependOn(&run_eval_runner_unit_tests.step);
    test_step.dependOn(&run_ocr_unit_tests.step);
    test_step.dependOn(&run_interpreter_unit_tests.step);
    test_step.dependOn(&run_testpdf_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_native_eval_tests.step);

    // Benchmark
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = parserModule(b, "src/bench.zig", target, .ReleaseFast, ocr_build),
    });

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}

const OcrBuildOptions = struct {
    options: *std.Build.Step.Options,
    enable_tesseract_c: bool,
    tesseract_include: []const u8,
    tesseract_lib: []const u8,
};

fn parserModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ocr_build: OcrBuildOptions,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("ocr_options", ocr_build.options);

    if (ocr_build.enable_tesseract_c) {
        module.link_libc = true;
        module.addSystemIncludePath(.{ .cwd_relative = ocr_build.tesseract_include });
        module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        module.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
        module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        module.addLibraryPath(.{ .cwd_relative = ocr_build.tesseract_lib });
        module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.linkSystemLibrary("tesseract", .{});
        module.linkSystemLibrary("leptonica", .{});
    }

    return module;
}
