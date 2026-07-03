const layout = @import("../layout.zig");

pub const Backend = enum {
    tesseract_cli,
    tesseract_c,
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
    executable: []const u8 = "tesseract",
    rasterizer_executable: []const u8 = "pdftoppm",
    lang: []const u8 = "eng",
    psm: PageSegMode = .single_block,
    dpi: u32 = 200,
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
