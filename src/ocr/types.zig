const layout = @import("../layout.zig");

pub const Backend = enum {
    tesseract_cli,
    tesseract_c,
};

pub const AttemptStatus = enum {
    not_invoked,
    completed,
    empty,
    unavailable,
    failed,
    timeout,
    invalid_output,
};

pub const AttemptStage = enum {
    rasterize,
    recognize,
};

pub const DiagnosticCode = enum {
    ocr_disabled,
    rasterizer_requires_file,
    rasterizer_unavailable,
    rasterizer_failed,
    rasterizer_timeout,
    rasterizer_output_limit,
    invalid_raster_image,
    tesseract_unavailable,
    tesseract_failed,
    tesseract_timeout,
    tesseract_output_limit,
    invalid_tesseract_output,
    tesseract_c_backend_disabled,
};

pub const Policy = enum {
    single,
    bounded,
};

pub const PageSegMode = enum(u8) {
    osd_only = 0,
    auto_osd = 1,
    auto_only = 2,
    auto = 3,
    single_column = 4,
    single_block_vertical = 5,
    single_block = 6,
    single_line = 7,
    single_word = 8,
    circle_word = 9,
    single_char = 10,
    sparse_text = 11,
    sparse_text_osd = 12,
    raw_line = 13,

    pub fn tesseractNumber(self: PageSegMode) u8 {
        return @intFromEnum(self);
    }
};

pub const OcrConfig = struct {
    backend: Backend = .tesseract_cli,
    policy: Policy = .bounded,
    executable: []const u8 = "tesseract",
    rasterizer_executable: []const u8 = "pdftoppm",
    lang: []const u8 = "eng",
    psm: PageSegMode = .single_block,
    dpi: u32 = 200,
    fallback_psm: PageSegMode = .sparse_text,
    fallback_dpi: u32 = 300,
    max_attempts: u8 = 2,
    retry_min_character_count: usize = 8,
    retry_min_mean_confidence: f32 = 0.65,
    retry_min_text_coverage: f32 = 0.0005,
    rasterize_grayscale: bool = true,
    timeout_ms: u32 = 10_000,
    stdout_limit: usize = 16 * 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
};

pub const OcrInput = struct {
    page_index: u32,
    pdf_bbox: layout.BBox,
    image_path: []const u8,
    pixel_width: u32,
    pixel_height: u32,
};

pub const RasterizeOutcome = struct {
    status: AttemptStatus,
    input: ?OcrInput = null,
    exit_code: ?u8 = null,
    stderr: []u8 = &.{},
    duration_ms: u64 = 0,
    diagnostic_code: ?DiagnosticCode = null,

    pub fn deinit(self: *RasterizeOutcome, allocator: anytype) void {
        if (self.stderr.len > 0) allocator.free(self.stderr);
        self.stderr = &.{};
    }
};

pub const RecognitionOutcome = struct {
    status: AttemptStatus,
    spans: []layout.TextSpan = &.{},
    exit_code: ?u8 = null,
    stderr: []u8 = &.{},
    duration_ms: u64 = 0,
    diagnostic_code: ?DiagnosticCode = null,

    pub fn deinit(self: *RecognitionOutcome, allocator: anytype) void {
        for (self.spans) |span| {
            if (span.text.len > 0) allocator.free(@constCast(span.text));
        }
        if (self.spans.len > 0) allocator.free(self.spans);
        if (self.stderr.len > 0) allocator.free(self.stderr);
        self.spans = &.{};
        self.stderr = &.{};
    }
};
