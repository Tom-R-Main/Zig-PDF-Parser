# pdf-parser (alpha stage)

A Zig PDF text extraction library evolving from a fast native extraction
kernel into a hybrid, adaptive parser.

## Features

- Memory-mapped file reading, zero-copy where possible
- Streaming text extraction with efficient arena allocation
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Configurable error handling (strict or permissive)
- Structure tree extraction for tagged PDFs (PDF/UA)
- Geometric (Y→X) reading order for non-tagged PDFs
- Markdown export for structured PDFs
- Adaptive extraction orchestration with native/layout/complexity/reconciler stages
- JSON inspection and trace output for page and region routing decisions

## Benchmark

Text extraction performance on Apple M4 Pro (reading order):

| Document | Pages | pdf-parser | MuPDF | Speedup |
|----------|------:|-----:|------:|--------:|
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | **582ms** | 2,152ms | 3.7x |
| [Pandas Docs](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | **640ms** | 1,130ms | 1.8x |
| [C++ Standard](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | **438ms** | 1,007ms | 2.3x |
| [PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf) | 1,310 | **236ms** | 1,481ms | 6.3x |

*Build with `zig build -Doptimize=ReleaseFast` for best performance.*

## Requirements

- Zig 0.16.0

## Building

```bash
zig build              # Build library and CLI
zig build test         # Run tests
```

## Usage

### Library

```zig
const std = @import("std");
const pdf_parser = @import("pdf_parser");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const doc = try pdf_parser.Document.open(allocator, "file.pdf");
    defer doc.close();

    var buf: [4096]u8 = undefined;
    var bw = std.Io.File.stdout().writer(init.io, &buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    for (0..doc.pageCount()) |page_num| {
        try doc.extractText(page_num, writer);
    }
}
```

### CLI

```bash
pdf-parser extract document.pdf              # Extract all pages (uses structure tree for reading order)
pdf-parser extract -p 1-10 document.pdf      # Extract pages 1-10
pdf-parser extract -o out.txt document.pdf   # Output to file
pdf-parser extract --adaptive -f json doc.pdf
pdf-parser extract --adaptive --trace doc.pdf
pdf-parser inspect complexity doc.pdf --format json
pdf-parser info document.pdf                 # Show document info
pdf-parser bench document.pdf                # Run benchmark
```

Adaptive extraction keeps fast native extraction on the default path while
recording when a page or region should be routed elsewhere. Current route names
include `use_native`, `queue_ocr`, `candidate_layout`, `candidate_table`,
`candidate_formula`, and `candidate_table_formula`. The trace JSON reports page
index, region index, span count, route, confidence, signal scores, and reasons
such as `image_dominant`, `missing_tounicode`, `table_alignment`,
`formula_density`, and `low_reading_order_confidence`.

### Python

```python
import zpdf

with zpdf.Document("file.pdf") as doc:
    print(doc.page_count)

    # Single page
    text = doc.extract_page(0)

    # All pages (accuracy mode is default)
    all_text = doc.extract_all()

    # Fast mode (higher throughput, stream-order extraction)
    fast_text = doc.extract_all(mode="fast")

    # Page info
    info = doc.get_page_info(0)
    print(f"{info.width}x{info.height}")

# Zero-copy memory open (unsafe semantics for other language bindings)
with zpdf.Document.open_memory_unsafe(open("file.pdf", "rb").read()) as doc:
    print(doc.page_count)
```

Build the shared library first:
```bash
zig build -Doptimize=ReleaseFast
PYTHONPATH=python python3 examples/basic.py
```

## Project Structure

```
src/
├── root.zig         # Document API and core types
├── main.zig         # CLI entry point
├── capi.zig         # C ABI exports for FFI
├── wapi.zig         # WASM API exports
├── parser.zig       # PDF object parser
├── xref.zig         # XRef table/stream parsing
├── pagetree.zig     # Page tree resolution
├── decompress.zig   # Stream decompression filters
├── encoding.zig     # Font encoding and CMap parsing
├── agl.zig          # Adobe Glyph List mappings
├── cff.zig          # CFF/Type1 font parsing
├── interpreter.zig  # Content stream interpreter
├── structtree.zig   # Structure tree parser (PDF/UA)
├── layout.zig       # Text layout and bounding boxes
├── markdown.zig     # Markdown export
├── complexity.zig   # Cheap page/region routing signals
├── adaptive.zig     # Adaptive extraction orchestration and trace records
├── reconcile.zig    # Provenance-preserving span/block/chunk outputs
├── specialists.zig  # Table/formula heuristics and adapter stubs
├── ocr.zig          # OCR routing adapter interface
└── simd.zig         # SIMD-accelerated parsing

python/zpdf/         # Python bindings (cffi, legacy package name)
examples/            # Usage examples
```

## Reading Order

pdf-parser extracts text in logical reading order using a three-tier approach:

1. **Structure Tree** (preferred): Uses the PDF's semantic structure for tagged/accessible PDFs (PDF/UA). Correctly handles multi-column layouts, sidebars, tables, and captions.

2. **Geometric Sort** (fallback): When no structure tree exists, sorts text spans by Y→X position to approximate visual reading order.

3. **Stream Order** (last resort): When bounding box extraction fails, falls back to raw PDF content stream order.

| Method | Pros | Cons |
|--------|------|------|
| Structure tree | Correct semantic order, handles complex layouts | Only works on tagged PDFs |
| Geometric sort | Works on any PDF, respects visual layout | May fail on complex multi-column layouts |
| Stream order | Always works | May not match visual order |

## Comparison

| Feature | pdf-parser | pdfium | MuPDF |
|---------|------|--------|-------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes |
| Tagged/structure tree | Yes | No | Yes |
| Visual reading order | No | No | Yes |
| Word bounding boxes | Yes | Yes | Yes |
| **Font Support** | | | |
| WinAnsi/MacRoman | Yes | Yes | Yes |
| ToUnicode CMap | Yes | Yes | Yes |
| CID fonts (Type0) | Partial* | Yes | Yes |
| **Compression** | | | |
| FlateDecode, LZW, ASCII85/Hex | Yes | Yes | Yes |
| JBIG2, JPEG2000 | No | Yes | Yes |
| **Other** | | | |
| Encrypted PDFs | No | Yes | Yes |
| Rendering | No | Yes | Yes |

*\*CID fonts: Works when CMap is embedded directly.*

**Use pdf-parser when:** Batch processing, tagged PDFs (PDF/UA), simple text extraction, Zig integration.

**Use pdfium when:** Browser integration, full PDF support, proven stability.

**Use MuPDF when:** Complex visual layouts, rendering needed.

## License

MIT for new implementation work. This fork began from `Lulzx/zpdf` at commit
`5eba7ade759d32b0d425eb905c17106b484dee30`, which was released under CC0-1.0;
see `NOTICE.md` and `LICENSES/CC0-1.0.txt` for provenance.
