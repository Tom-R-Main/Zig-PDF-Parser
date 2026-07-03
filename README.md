# pdf-parser (alpha stage)

A Zig PDF text extraction library evolving from a fast native extraction
kernel into a hybrid, adaptive parser.

## Features

- Memory-mapped file reading, zero-copy where possible
- Streaming text extraction with efficient arena allocation
- Multiple decompression filters: FlateDecode, ASCII85, ASCIIHex, LZW, RunLength
- Font encoding support: WinAnsi, MacRoman, ToUnicode CMap
- XRef table and stream parsing (PDF 1.5+)
- Known-password Standard Security Handler decryption for encrypted PDFs
- Configurable error handling (strict or permissive)
- Structure tree extraction for tagged PDFs (PDF/UA)
- Geometric (Y→X) reading order for non-tagged PDFs
- Markdown export for structured PDFs
- Adaptive extraction orchestration with native/layout/complexity/reconciler stages
- Local Tesseract OCR adapter for pages or regions routed as scanned content
- AcroForm field extraction, including nested/inherited widget values
- Geometry-aware table reconstruction for aligned, ruled, merged-cell, rowspan,
  footnote, and multi-page financial table fixtures
- JSON/JSONL/RAG/hOCR/ALTO/debug-SVG output surfaces with typed provenance
- Optional visual review sidecars for page overlays, table grids, OCR routes,
  low-confidence regions, and span/block ids
- Specialist protocol records for OCR/table/formula/layout/entity adapters
- JSON inspection and trace output for page and region routing decisions
- Corpus benchmark scorecards for parser versions, external tools, private
  manifests, and CI quality gates

## Performance Benchmark

Text extraction performance on Apple M4 Pro (reading order):

| Document | Pages | pdf-parser | MuPDF | Speedup |
|----------|------:|-----:|------:|--------:|
| [Intel SDM](https://cdrdv2.intel.com/v1/dl/getContent/671200) | 5,252 | **582ms** | 2,152ms | 3.7x |
| [Pandas Docs](https://pandas.pydata.org/pandas-docs/version/1.4/pandas.pdf) | 3,743 | **640ms** | 1,130ms | 1.8x |
| [C++ Standard](https://open-std.org/jtc1/sc22/wg21/docs/papers/2023/n4950.pdf) | 2,134 | **438ms** | 1,007ms | 2.3x |
| [PDF Reference 1.7](https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.7old.pdf) | 1,310 | **236ms** | 1,481ms | 6.3x |

*Build with `zig build -Doptimize=ReleaseFast` for best performance.*

## Evaluation Corpus

The checked-in evaluation corpus is intentionally small and deterministic, with
manifest metadata for source notes, redistribution status, SHA256, expected route
counts, and optional ground-truth labels.

```bash
zig build eval-corpus
zig build eval -- --adaptive \
  --ocr-executable tesseract \
  --ocr-rasterizer pdftoppm \
  --manifest benchmark/eval/corpus/manifest.tsv
zig build benchmark-eval
pdf-parser benchmark \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --suite-id tiny-corpus \
  --tools pdf-parser:adaptive,pdf-parser:native \
  --thresholds benchmark/eval/thresholds.json \
  --output benchmark/eval/outputs/scorecards/tiny-corpus.json \
  --jsonl benchmark/eval/outputs/scorecards/tiny-corpus.records.jsonl
.venv/bin/python benchmark/eval/compare.py \
  --pdf-parser-adaptive \
  --tools pdf-parser,pymupdf,pypdfium2,pdfplumber \
  --ensure-releasefast \
  --manifest benchmark/eval/corpus/manifest.tsv
.venv/bin/python benchmark/eval/fetch_large_corpus.py --dry-run
.venv/bin/python benchmark/eval/run_baseline.py --large
.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl \
  --output /tmp/pdf-parser-profile.jsonl
.venv/bin/python benchmark/eval/analyze_baseline.py \
  --compare-jsonl benchmark/eval/outputs/comparison/baseline.jsonl \
  --profile-jsonl /tmp/pdf-parser-profile.jsonl \
  --manifest benchmark/eval/large/manifest.tsv \
  --output /tmp/pdf-parser-baseline-report.json \
  --table-output /tmp/pdf-parser-baseline-report.md
```

Current fixture classes include clean born-digital text, academic two-column
layout, scientific formulas, image-only scans, mixed native/scan pages,
financial tables, AcroForms, and corrupt/adversarial PDFs. Financial table truth
can assert cell text plus `rowspan`, `colspan`, `role`, `page`, and bbox-aware
provenance. Form truth asserts field name/type/value sequences. Formula truth
can assert both text and simple structure records.

`pdf-parser benchmark` is the product-facing corpus runner. It emits a full
scorecard JSON plus optional record-oriented JSONL with `benchmark_run`,
`benchmark_lane`, `benchmark_document_result`, `benchmark_category_summary`,
`benchmark_regression`, and `benchmark_scorecard` records. Tool lanes are
neutral: use `pdf-parser:native`, `pdf-parser:adaptive`, or
`command:<id>=<command template with {pdf}>`. `--candidate-command` and
`--baseline-command` compare two pdf-parser-compatible executables and
`--fail-on-regression` makes the scorecard usable as a CI ingestion gate.

`benchmark/eval/corpus` is the tiny checked-in correctness and regression
corpus. Large public or private PDFs belong under ignored
`benchmark/eval/raw_cache/large`; use `benchmark/eval/fetch_large_corpus.py` to
download/derive local performance fixtures and `benchmark/eval/profile_lanes.py`
to measure native text, adaptive artifact JSONL, streaming JSONL, and OCR-routed
lanes before doing parser optimization. The profiler keeps OCR isolated by
default: adaptive JSONL lanes pass `--no-ocr`, while `ocr-routed` invokes
Tesseract and can be bounded with `--ocr-pages`. OCR routes default to 200 DPI
for the local Tesseract path and grayscale rasterization; pass `--ocr-dpi 300`
when validating high-resolution scan tradeoffs, or `--ocr-color` when comparing
against the older RGB raster path. Add `--hash-output` during optimization
validation runs when byte-for-byte output stability matters; hashes are computed
after the timed subprocess exits, and the analyzer summarizes hash stability
when hashes are present. `benchmark/eval/analyze_baseline.py`
turns comparator and profiler JSONL into grouped JSON/Markdown reports and
records whether manifest PDFs are locally present. It also ranks measured
optimization candidates and next actions, so the next slice is chosen from
evidence instead of hunches. `benchmark/eval/run_baseline.py --large` runs the
whole ReleaseFast baseline workflow and skips large profiling until the ignored
cache is populated.

## Requirements

- Zig 0.16.0
- Optional: `tesseract` and `pdftoppm` for OCR eval routes
- Optional: Python virtualenv with PyMuPDF, pypdfium2, and pdfplumber for
  cross-parser comparison

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
pdf-parser extract --adaptive -f jsonl doc.pdf
pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
pdf-parser extract --adaptive -f stream-jsonl doc.pdf
pdf-parser extract --adaptive -f rag-jsonl doc.pdf
pdf-parser extract --adaptive --no-ocr -f artifact-jsonl doc.pdf
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl \
  --emit-specialist-requests requests.jsonl
pdf-parser extract-adaptive --input doc.pdf --format artifact-jsonl --debug-assets-dir review-assets
pdf-parser extract --adaptive -f hocr doc.pdf
pdf-parser extract --adaptive -f alto doc.pdf
pdf-parser extract --adaptive -f debug-svg doc.pdf
pdf-parser extract --adaptive --trace doc.pdf
pdf-parser inspect complexity doc.pdf --format json
pdf-parser info document.pdf                 # Show document info
pdf-parser bench document.pdf                # Run benchmark
pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv \
  --tools pdf-parser:adaptive --output /tmp/pdf-parser-scorecard.json
```

Adaptive extraction keeps fast native extraction on the default path while
recording when a page or region should be routed elsewhere. Current route names
include `use_native`, `queue_ocr`, `candidate_layout`, `candidate_table`,
`candidate_formula`, and `candidate_table_formula`. The trace JSON reports page
index, region index, span count, route, confidence, signal scores, and reasons
such as `image_dominant`, `missing_tounicode`, `table_alignment`,
`formula_density`, and `low_reading_order_confidence`. Use `--no-ocr` when a
host pipeline wants adaptive structure and routing evidence without invoking
fresh OCR subprocesses.

Adaptive `json` emits the versioned public schema: a `document_manifest` plus
typed `span`, `block`, `table`, `form_field`, `route_trace`,
`specialist_request`, `specialist_response`, `specialist_result`, `rag_chunk`,
and `debug_asset` records. `artifact-jsonl` emits the same contract as a
manifest-first batch JSONL stream for host applications and ingestion
pipelines. `stream-jsonl` emits page-by-page lifecycle events and artifacts as
soon as each page is processed: `document_manifest`, `page_started`, route
traces, specialist requests/results, page artifacts, `page_finished`, optional
debug assets, then `document_finished`. `jsonl` remains a compatibility span
stream, and `rag-jsonl` remains chunk-only. The schema is documented in
[docs/output-schema.md](docs/output-schema.md).

Visual review assets are formal `debug_asset` records in schema `0.8.0`. By
default they are references with `path:null`, `uri:null`, and null hashes. Add
`--debug-assets-dir DIR` to materialize deterministic sidecar files such as
`page-0001.table-grid.svg`, `page-0001.ocr-routes.svg`, `document.hocr.html`,
and `document.route-trace.json`; the corresponding records then include file
path, byte length, SHA256, page scope, layers, and provenance.

For host applications, prefer the neutral adapter command:

```bash
pdf-parser extract-adaptive \
  --input doc.pdf \
  --source-id external-system-id \
  --format artifact-jsonl \
  --debug-assets-dir review-assets
```

`source_id` is a caller-owned external identity, separate from the parser's
`document_id`. It is emitted on the manifest, artifacts, chunks, and provenance
envelopes so any pipeline can join records back to its own source table,
object-store key, or ingestion run.

Encrypted PDFs are opened with a supplied known password, not cracked:

```bash
pdf-parser extract encrypted.pdf --password "$PDF_PASSWORD"
pdf-parser extract-adaptive \
  --input encrypted.pdf \
  --source-id external-system-id \
  --password-file .pdf-password \
  --format artifact-jsonl
```

`--password-file` reads one local file and ignores trailing CR/LF bytes. Do not
use it with secret files you do not intend the worker process to read. The
parser records encryption/authentication metadata in the document manifest, but
never emits the password.

### Packaging For Host Apps

Use three integration modes, in this order:

1. **CLI subprocess**: recommended default for workers, Siftable ingestion, and
   Cloud Run jobs. It is easiest to isolate, supervise, retry, and deploy:

   ```bash
   pdf-parser extract-adaptive \
     --input doc.pdf \
     --source-id external-system-id \
     --format artifact-jsonl
   pdf-parser extract-adaptive \
     --input doc.pdf \
     --source-id external-system-id \
     --format stream-jsonl
   ```

2. **C ABI**: use `zig build shared` and include `pdf_parser.h` for Python,
   Node, native, or other host bindings. The ABI returns the same versioned
   JSON/JSONL artifacts as allocated buffers; callers must release returned
   buffers with `pdf_parser_free_buffer(...)` or clear the full result with
   `pdf_parser_result_clear(...)`.

   ```c
   PdfParserAdaptiveOptions options = {
       .abi_version = PDF_PARSER_ABI_VERSION,
       .format = PDF_PARSER_FORMAT_ARTIFACT_JSONL,
       .input_path = "doc.pdf",
       .source_id = "external-system-id",
       .password = "known-password",
       .permissive = 1,
   };
   PdfParserAdaptiveResult result = {0};
   int status = pdf_parser_extract_adaptive_file(&options, &result);
   if (status == PDF_PARSER_STATUS_OK) {
       /* result.output/result.output_len is artifact JSONL */
   }
   pdf_parser_result_clear(&result);
   ```

   Python exposes the same surface as `zpdf.extract_adaptive(...,
   password="known-password")` or `password_file=".pdf-password"`. Node
   wrappers should prefer Node-API over direct V8 bindings for ABI stability,
   while Siftable can continue using the subprocess path first.

3. **HTTP server**: useful for later long-running batch corpora or internal
   services. It is a stateless wrapper around the same adapter:

   ```bash
   pdf-parser serve --host 0.0.0.0 --port 8080
   curl -s http://localhost:8080/v1/extract-adaptive \
     -H 'content-type: application/json' \
     -d '{"input_path":"doc.pdf","source_id":"external-system-id","format":"stream-jsonl"}'
   ```

   Endpoints are `GET /healthz`, `GET /v1/capabilities`, and
   `POST /v1/extract-adaptive`. Cloud Run services should bind to
   `0.0.0.0:$PORT`; Cloud Run jobs should use the CLI subprocess mode and exit
   when the document or manifest finishes.

The specialist protocol keeps the Zig kernel deterministic while making local
specialists swappable. Route traces identify regions that need OCR, table,
formula, layout, or entity review; `specialist_request` records include the
page/region bbox, route reasons, signal scores, native spans/blocks, optional
crop/debug asset references, and provenance. By default the parser emits
requests and does not invoke table/formula/layout/entity specialists. Existing
Tesseract OCR output is represented as `specialist_response` and
`specialist_result` records when OCR runs. Future subprocess specialists should
use JSONL-over-stdin/stdout: one request JSON object in, one response JSON
object out.

Optional specialist flags:

```bash
pdf-parser extract-adaptive \
  --input doc.pdf \
  --source-id external-system-id \
  --format artifact-jsonl \
  --emit-specialist-requests requests.jsonl \
  --specialist-config specialists.json
```

The minimal specialist config shape is a JSON object with optional `ocr`,
`table`, `formula`, `layout`, and `entity` entries. Each entry may include
`enabled`, `executable`, `args`, and `timeout_ms`. The config is accepted and
carried as adapter plumbing in this sprint; non-OCR specialist invocation is
intentionally not enabled by default.

The document manifest is the top-level intelligence summary: input SHA256,
parser/schema versions, page count, encrypted/corrupt flags, route counts,
OCR/table/form/formula extraction counts, output artifact hashes or stream hash
slots, warnings/errors, and capability coverage. That makes it suitable as the
stable run record for general pipelines, not just this CLI.

For Siftable-style ingestion, `stream-jsonl` maps naturally to durable
processing records: `document_manifest` as a manifest artifact,
`page_started`/`page_finished`/`document_finished` as status artifacts,
`span`/`block`/`table` as extracted text artifacts, `route_trace` and
`specialist_request` as metadata or OCR/specialist diagnostics,
`specialist_result` as returned specialist evidence, and `rag_chunk` as
chunk-index artifacts that can be queued for embeddings before the full
document finishes.

Table records are structured data artifacts: rows/cells, page-aware geometry,
logical multi-page table ids, continuation links, `rowspan`/`colspan`, roles
(`header`, `row_header`, `data`, `note`, `footer`), confidence, raw and
normalized text, deterministic numeric hints, and source span ids when
available. OCR remains local and deterministic: when a page or region is routed
to OCR, the adapter invokes Tesseract and reconciles the fresh OCR spans with
native PDF spans rather than replacing the whole page.

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
├── server.zig       # Stateless HTTP host adapter
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
├── stream.zig       # Page-by-page adaptive JSONL artifact streaming
├── reconcile.zig    # Provenance-preserving span/block/chunk outputs
├── specialists.zig  # Table/formula heuristics and adapter stubs
├── specialist_protocol.zig # Public JSONL protocol for local specialists
├── ocr.zig          # OCR routing adapter and Tesseract subprocess/C-FFI hooks
├── eval.zig         # Evaluation metrics
├── eval_runner.zig  # Eval CLI
├── benchmark_runner.zig # Corpus benchmark scorecards and regression gates
├── eval_corpus_writer.zig # Deterministic fixture writer
└── simd.zig         # SIMD-accelerated parsing

include/pdf_parser.h # Public C ABI header
python/zpdf/         # Python bindings (cffi, legacy package name)
benchmark/eval/      # Tiny eval corpus, truth labels, thresholds, scorecards, comparator
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

Adaptive mode adds a fourth reconstruction layer for harder pages: it scores
page/region complexity, reconstructs table rows and cells from layout geometry
and ruling lines, invokes OCR only for scanned routes, then reconciles native,
OCR, table, formula, and form spans with typed provenance.

The versioned JSON, artifact JSONL, and streaming JSONL schema is currently
`0.8.0`. Every emitted record carries a `provenance` envelope with document and
source identity, input hash context, artifact id, page/bbox, source kind,
confidence, related span/block/chunk ids, route trace ids, and route reasons.
This makes parser outputs usable as reviewable evidence in host pipelines
without removing the older top-level compatibility fields.

## Comparison

| Feature | pdf-parser | pdfium | MuPDF | pdfplumber |
|---------|------|--------|-------|------------|
| **Text Extraction** | | | |
| Stream order | Yes | Yes | Yes | Yes |
| Tagged/structure tree | Yes | No | Yes | No |
| Visual/layout reading order | Yes | No | Yes | Yes |
| Word bounding boxes | Yes | Yes | Yes | Yes |
| Local OCR route | Yes | No | No | No |
| AcroForm value extraction | Yes | Partial | Partial | Partial |
| Ruled table cell geometry | Yes | No | No | Yes |
| Rowspan/colspan/role output | Yes | No | No | Partial |
| **Font Support** | | | |
| WinAnsi/MacRoman | Yes | Yes | Yes | Yes |
| ToUnicode CMap | Yes | Yes | Yes | Yes |
| CID fonts (Type0) | Partial* | Yes | Yes | Yes |
| **Compression** | | | |
| FlateDecode, LZW, ASCII85/Hex | Yes | Yes | Yes | Yes |
| JBIG2, JPEG2000 | No | Yes | Yes | Via dependencies |
| **Other** | | | |
| Encrypted PDFs | Known password | Yes | Yes | Via dependencies |
| Rendering | No | Yes | Yes | No |

*\*CID fonts: Works when CMap is embedded directly.*

**Use pdf-parser when:** Batch extraction, deterministic Zig-native pipelines,
PDF/UA/tagged PDFs, local OCR fallback, financial table provenance, form values,
or RAG/debug outputs matter.

**Use pdfium when:** Browser integration, full PDF support, proven stability.

**Use MuPDF when:** Complex visual layouts, rendering needed.

**Use pdfplumber when:** Python table-extraction workflows and interactive
layout debugging matter more than a native Zig pipeline.

## License

MIT for new implementation work. This fork began from `Lulzx/zpdf` at commit
`5eba7ade759d32b0d425eb905c17106b484dee30`, which was released under CC0-1.0;
see `NOTICE.md` and `LICENSES/CC0-1.0.txt` for provenance.
