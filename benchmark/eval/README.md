# Evaluation Harness

`pdf-parser` treats evaluation as a first-class build target:

```sh
zig build eval-corpus

zig build eval -- benchmark/eval/corpus/clean_born_digital/clean-native.pdf \
  --truth-text benchmark/eval/ground_truth/page_text/clean_born_digital/clean-native.txt \
  --category clean_born_digital \
  --doc-id clean-native
```

Use adaptive mode when you want route decisions, reconciliation, and OCR
adapters included in the measured output:

```sh
zig build eval -- benchmark/eval/corpus/scanned_typewritten/image-only-page.pdf \
  --adaptive \
  --ocr-rasterizer pdftoppm \
  --ocr-executable tesseract \
  --truth-text benchmark/eval/ground_truth/page_text/scanned_typewritten/image-only-page.txt \
  --category scanned_typewritten \
  --doc-id image-only-page
```

The tiny checked-in corpus is manifest-driven:

```sh
zig build eval -- --manifest benchmark/eval/corpus/manifest.tsv
```

That command emits one JSONL record for each current fixture category:
clean born-digital text, academic two-column layout, scientific math notation,
scanned/typewritten image-only input, real public-domain JBIG2 and JPX scans,
financial tables, forms, weird-font fixtures, visual truth fixtures, and
adversarial page-tree recovery.

`benchmark/eval/corpus/metadata.jsonl` is the provenance sidecar for the tiny
checked-in corpus. Each row records the fixture id, source note, redistribution
status, PDF SHA256, and expected OCR/table/formula route counts. Manifest eval
loads this sidecar automatically when it sits next to `manifest.tsv` and fails
if the adaptive counters differ from those expectations. Large or raw third-party
corpora should live under `benchmark/eval/raw_cache/`, which is ignored by git;
checked-in PDFs should stay small and redistributable. The
`jbig2-public-domain-preface` fixture is a deterministic page-10 derivative of
Austin Cary's public-domain 1909 manual: it preserves the original 600-DPI
JBIG2 image stream in a roughly 40 KB one-page PDF. Reproduce it from the
ignored large-corpus source with:

```sh
qpdf --deterministic-id --object-streams=disable \
  benchmark/eval/raw_cache/large/image-heavy-scan.pdf \
  --pages . 10 -- \
  benchmark/eval/corpus/scanned_typewritten/jbig2-public-domain-preface.pdf
```

The large-corpus source inventory pins the 295-page input SHA256 as well as the
one-page derivative SHA256, so the recipe cannot silently accept replacement
source bytes.

The blocking real-scan gate verifies the fixture hash and JBIG2 filter before
checking OCR provenance, a completed selected attempt, absolute token floors,
and exact semantic phrase recall:

```sh
python3 benchmark/eval/ocr_hard_document_quality.py \
  --output /tmp/pdf-parser-ocr-hard-document-quality.json
```

The companion `jpx-public-domain-map-cover` fixture is a deterministic page-2
derivative of the same source. Its main page image is a 1192 by 1920, 300-DPI
color JPX map/cover; the remaining JBIG2 object is only the small Google
watermark mask. The roughly 188 KB fixture forces rasterization of real JPX
content and gates the selected 300-DPI sparse-text fallback and readable cover
labels separately from noisy map detail. OCR-derived table/formula region counts
are recorded but remain observational because the pinned Linux and current macOS
toolchains segment the map differently while recovering the same required text:

```sh
qpdf --deterministic-id --object-streams=disable \
  benchmark/eval/raw_cache/large/image-heavy-scan.pdf \
  --pages . 2 -- \
  benchmark/eval/corpus/scanned_typewritten/jpx-public-domain-map-cover.pdf
python3 benchmark/eval/ocr_hard_document_quality.py \
  --pdf benchmark/eval/corpus/scanned_typewritten/jpx-public-domain-map-cover.pdf \
  --truth benchmark/eval/ground_truth/ocr_text/scanned_typewritten/jpx-public-domain-map-cover.json \
  --output /tmp/pdf-parser-ocr-jpx-hard-document-quality.json
```

The ignored large corpus explicitly inventories a real technical reference with
CID Identity/no-ToUnicode cases and the full public-domain scan containing
JBIG2 and JPX images. These exercise honest fallback and routed OCR behavior;
one JBIG2 page and one JPX page are now promoted into the checked-in blocking
corpus, while real predefined-collection CJK and Type3 PDFs remain acquisition
targets rather than being represented by synthetic fixtures alone.

Font-fidelity sidecars live under `benchmark/eval/ground_truth/fonts/`. They are
discovered from `metadata.jsonl` instead of extra manifest columns so existing
text/table/formula eval lanes stay compatible. The current `weird_fonts`
category covers ActualText repair, Type3 fonts, broken Identity-H, vertical
CJK, predefined Adobe Japan1/GB1/CNS1/Korea1 mappings without ToUnicode, and
redistribution-safe Sleisenger reductions for Symbol glyph names and
family-scoped MathematicalPi-One private names:

```sh
.venv/bin/python benchmark/eval/font_compare.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --output /tmp/pdf-parser-font-diff.jsonl
```

The font comparator scores `pdf-parser extract --format text` for native
Unicode accuracy and separately runs `extract-adaptive --format artifact-jsonl
--debug-assets-dir ...` to read `page-*.glyph-trace.jsonl`. It compares the
same PDFs with Poppler `pdftotext`, PyMuPDF, and pypdfium2 when those optional
tools are present. Every checked-in font truth sidecar requires exact text.
Declared ActualText, Unicode-map, writing-mode, and glyph-trace expectations
are blocking checks rather than observational annotations.
Use `--require-baselines` when missing Python baselines should fail the run.
This is a differential accuracy harness: the sidecar truth defines the expected
behavior, while MuPDF/PDFium-backed tools provide useful contrast rather than an
absolute oracle.

The predefined CMap tables are generated from pinned Adobe BSD-3-Clause source
revisions. The generator rejects source checkouts whose `HEAD` does not match
those revisions, preserves scalar and multi-codepoint CID mappings, and packs
common 16-bit CMap records to keep native/WASM artifacts bounded. Keep source
clones in the ignored benchmark cache, regenerate, then verify determinism with:

```sh
python3 benchmark/eval/generate_cmap_resources.py \
  --cmap-root benchmark/eval/raw_cache/cmap-resources \
  --mapping-root benchmark/eval/raw_cache/mapping-resources-pdf \
  --output src/cmap_resources.zig \
  --binary-output src/cmap_resources.bin \
  --check
```

CI repeats this check from sparse checkouts of the pinned Adobe revisions and
enforces a 3,250,000-byte budget for the ReleaseSmall WASM artifact.

Render-oracle sidecars live under
`benchmark/eval/ground_truth/render_oracle/`. They keep visual expectations out
of the main manifest while allowing optional pixel-backed checks for rotated
pages, clipped text, invisible OCR-style layers, ruled tables, and mixed image
regions:

```sh
.venv/bin/python benchmark/eval/render_oracle.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --category visual_truth \
  --output /tmp/pdf-parser-render-oracle.jsonl
```

The render oracle is benchmark evidence, not parser core code. It requires
Pillow in the Python environment, then runs
`pdf-parser extract-adaptive --format artifact-jsonl --debug-assets-dir ...`,
renders pages with Poppler `pdftoppm` at 144 DPI by default, maps public
PDF-coordinate bboxes into raster pixels using the materialized page overlay
SVG `viewBox`, and emits JSONL records with coverage signals. Optional
renderers are available through `--renderer all` when pypdfium2 or `mutool draw`
are installed; use `--require-renderers` when missing optional engines should
fail. `--materialize-dir` writes rendered pages and low-coverage crops for
review, but generated PNGs/crops are local outputs and should not be committed.

Financial table stress fixtures live under `benchmark/eval/table_stress/`.
They are checked-in synthetic reductions for real-world table shapes: SEC
statement continuation pages, borderless bank transactions, wrapped invoice
totals, procurement nested headers, and legal schedules drawn out of content
order. The stress pack has its own manifest so the tiny default correctness
corpus stays quick:

```sh
zig build eval -- --adaptive --manifest benchmark/eval/table_stress/manifest.tsv
.venv/bin/python benchmark/eval/table_compare.py \
  --manifest benchmark/eval/table_stress/manifest.tsv \
  --output /tmp/pdf-parser-table-stress.jsonl
```

`table_compare.py` treats `pdf-parser`, PyMuPDF `Page.find_tables()`, and
optional pdfplumber as neutral lanes. Missing optional baselines emit skipped
records unless `--require-baselines` is supplied. Truth sidecars preserve the
simple `rows/cells` shape and may add `bbox`, `page`, `role`, `rowspan`,
`colspan`, `numeric`, continuation ids, and source-span requirements.

Table comparator records use schema `0.3.0`. Sequence metrics ignore empty
grid placeholders covered by row/column spans and leading or trailing padding
in ragged rows, while preserving semantic empty cells between populated cells.
Per-document
`table_quality_floors` in `table_stress/metadata.jsonl` are enforced for the
named tool; the checked-in floors gate `pdf-parser`, while optional baseline
tools remain observational. The checked-in suite gates ruled, borderless,
wrapped-cell, nested-header, continuation, and out-of-content-order cases.

Large performance manifests live under `benchmark/eval/large/`. Those manifests
point at `benchmark/eval/raw_cache/large/` and are intended for timing, memory,
and profiling work rather than truth-labeled correctness scoring:

```sh
.venv/bin/python benchmark/eval/fetch_large_corpus.py --dry-run
.venv/bin/python benchmark/eval/fetch_large_corpus.py --download --derive
.venv/bin/python benchmark/eval/fetch_large_corpus.py --verify
```

The runner emits one JSONL record per document with text, layout-adjacent,
table/formula, latency, RSS, and provenance counters. Missing specialist ground
truth is represented as `null`, so the same schema works for native text-only
fixtures and richer labeled corpora.

Manifest rows have four required TSV columns:
`category`, `doc_id`, `pdf_path`, and `truth_text_path`. Three optional columns
can follow: `truth_table_json_path`, `truth_reading_order_path`, and
`truth_formula_path`. An eighth optional column, `truth_formula_json_path`, can
carry structured formula labels, and a ninth optional column,
`truth_form_json_path`, can carry value-bearing AcroForm labels. Empty optional columns are allowed when a later specialist
truth file is present. A tenth optional column,
`truth_reading_graph_path`, can carry the internal relation-aware reading-order
truth described below. Table truth emits `table_cell_accuracy`; reading-order
truth emits `reading_order_score`; formula truth emits `formula_bleu` and
`formula_edit_distance`; formula JSON truth emits `formula_structure_accuracy`
over formula page/text sequence; form JSON truth emits `form_field_accuracy`
over field name/type/value sequence. Richer table truth may include `rowspan`, `colspan`,
`role`, `bbox`, and `page`; when span fields are present the runner also emits
`table_span_accuracy`, and when role fields are present it emits
`table_role_accuracy`. Table truth with bbox, numeric, header/footer/note, or
continuation labels also enables `table_bbox_iou`, `table_numeric_accuracy`,
`table_header_accuracy`, `table_footnote_accuracy`, and
`table_continuation_accuracy`.

External task evaluators can feed their scores into the same record:

```sh
zig build eval -- corpus/scientific_math/example.pdf \
  --truth-text ground_truth/page_text/example.txt \
  --truth-table-json ground_truth/tables/example.json \
  --truth-reading-order ground_truth/reading_order/example.txt \
  --truth-formula ground_truth/formulas/example.txt \
  --truth-formula-json ground_truth/formulas_json/example.json \
  --truth-form-json ground_truth/form_fields/example.json \
  --category scientific_math \
  --adaptive \
  --reading-order-score 0.88 \
  --table-f1 0.72 \
  --teds 0.64 \
  --grits 0.69 \
  --formula-bleu 0.81 \
  --formula-cdm 0.77 \
  --ocr-pages 2 \
  --table-regions 3 \
  --formula-regions 5
```

## Reading-order graph V0 experiment

`benchmark/eval/reading_order/` is a separate deterministic experiment pack;
it does not replace or regenerate the primary corpus. Its 16 one-page fixtures
cover eight matched development/holdout families: spanning headings,
asymmetric columns, sidebars, captions, footnotes, text wrapping around a
figure, tables interleaved with prose, and content-stream order that conflicts
with visual order. Regenerate it with:

```sh
python3 benchmark/eval/generate_reading_order_corpus.py
```

Graph truth is versioned independently of the public extraction schema. Text
anchors must resolve to exactly one internal live block; an absent, ambiguous,
or colliding anchor fails evaluation.

```json
{
  "version": 1,
  "nodes": [
    {"id": "heading", "page_index": 0, "text_anchor": "Results"},
    {"id": "body", "page_index": 0, "text_anchor": "Body opening"},
    {"id": "sidebar", "page_index": 0, "text_anchor": "Context note"},
    {"id": "caption", "page_index": 0, "text_anchor": "Figure 1"},
    {"id": "figure", "page_index": 0, "text_anchor": "Figure region"}
  ],
  "required_precedence": [["heading", "body"]],
  "forbidden_precedence": [["body", "heading"]],
  "ambiguous_pairs": [["sidebar", "body"]],
  "relations": [{"type": "caption_of", "from": "caption", "to": "figure"}],
  "valid_orders": []
}
```

The runner supports matched internal treatments without changing JSON/JSONL,
the C ABI, or Python bindings:

```sh
# Output-preserving graph diagnostics with full evidence.
zig build eval -- --adaptive --disable-ocr \
  --manifest benchmark/eval/reading_order/manifest.tsv \
  --reading-order-mode diagnostic

# Geometry/semantic ablation and structure demotion treatment.
zig-out/bin/pdf-parser-eval --adaptive --disable-ocr \
  --manifest benchmark/eval/reading_order/manifest.tsv \
  --reading-order-mode diagnostic --reading-order-no-structure
zig-out/bin/pdf-parser-eval --adaptive --disable-ocr \
  --manifest benchmark/eval/reading_order/manifest.tsv \
  --reading-order-mode diagnostic --reading-order-soft-structure
```

The evaluator emits precedence precision/recall/F1, required-edge recall,
forbidden-path rate, caption/footnote F1, cycle rate, ambiguity preservation,
valid-projection rate, graph eligibility/fallback counts, and the existing text
quality metrics. `diagnostic` constructs the graph but never changes extraction
order; `graph` applies its stable projection only to eligible native,
horizontal, non-OCR pages. The default remains `legacy`.

The frozen V0 run did not meet promotion gates. On the eight holdouts,
geometry-only graph and legacy both measured 97.73% macro precedence F1 (a
0-point gain). Full structure-tree evidence measured 92.37%, 95.83% required
recall, a 12.5% forbidden-path rate, and 87.5% valid projections. Demoting
structure edges from hard to soft produced the same result because the
conflicting tagged order still outranked geometry. Both graph variants
preserved 0% of declared ambiguous pairs. Caption relation F1 was 0%, while
footnote relation F1 was 100%. Cycle rate remained zero. These results falsify
H1-H3 for this V0 evidence model, so graph mode is retained as diagnostic
infrastructure rather than made the adaptive default. Five matched ReleaseFast
runs measured a 2.31% median
graph-mode latency overhead, inside the 15% guardrail. Five artifact JSONL runs
were byte-identical. Stream JSONL record order and payloads were also stable,
but exact files differed in the pre-existing `document_finished.elapsed_ms`
lifecycle measurement; exact stream bytes therefore did not pass the stated
promotion gate either.

### Real-page representation preflight

`PDF-READORDER-02` tested the block graph's representation boundary before
changing geometric evidence. `generate_reading_order_real_corpus.py` verifies
the exact SHA-256 of the existing ignored `table-heavy-sec.pdf` cache entry and
derives six development and six frozen holdout pages from a real annual report:

```sh
python3 benchmark/eval/generate_reading_order_real_corpus.py
zig build eval -- --adaptive --disable-ocr \
  --manifest benchmark/eval/reading_order_real/manifest.tsv \
  --reading-order-mode diagnostic --reading-order-no-structure \
  --reading-graph-audit --output /tmp/reading-graph-audit.jsonl
```

The derived PDFs and full page-text transcriptions stay ignored and must be
regenerated locally; the source digest, page selection, relation truth,
metadata, and audit result are checked in. This avoids treating a
redistribution-unclear annual report as ordinary fixture material.

The frozen preflight was not representable by the current live-block graph.
All 12 fixtures failed the evaluator's required unique-anchor contract before
edge scoring: six `NodeAnchorNotFound`, five `NodeAnchorCollision`, and one
`NodeAnchorAmbiguous`. Visual review and debug overlays showed the dominant
failure class: the layout layer often merges text from parallel columns,
callouts, and side labels into one `LayoutBlock`, while some intended regions
are removed as furniture. A graph over those blocks cannot repair order inside
the merged node.

Five bounded treatments were tested and removed after failing the same frozen
gate. Sparse global occupancy plus repeated row-gap recovery resolved 81 of 96
anchors as written, but remained below the 95% threshold and regressed the
existing two-column footer control. Replacing content-stream spans with the
current glyph-first line spans resolved only 59 of 96 anchors, even when given
the native gutter or opt-in row-gap recovery. Splitting large horizontal gaps
inside those native lines produced the identical 59-of-96 outcome. A subsequent
section-local treatment exposed a deeper failure: using the existing native
baseline groups resolved only 15 anchors because some groups had already
interleaved adjacent lines. Rebuilding strict bands from glyph bounding boxes
prevented that specific corruption but resolved only 49 anchors, below the
corrected baseline, because flat vertical joins still did not recover stable
paragraph and semantic-region boundaries. The exact treatment results are
recorded in `reading_order_real/representation-audit.json`.

The evidence rules out another global-gutter or flat-region threshold pass. The
next dependency is a hierarchical rectilinear representation that preserves
glyph-to-line-to-leaf-to-parent identity, represents whitespace cuts at multiple
scales, and classifies recurrent furniture independently. Only after that
representation gate passes should graph edges or structure-tree corroboration
be retested.

`--reading-graph-audit` is an evaluator-only diagnostic. It emits every truth
anchor status and match, every live graph node, and every layout block,
including removed furniture, with text and geometry. It does not alter normal
evaluation JSONL or any extraction schema. Four objective straight-versus-curly
apostrophe transcription mismatches were corrected in the generated truth. The
corrected audit finds 52 of 96 anchors mapped one-to-one, 32 collisions, five
ambiguous anchors, and seven not-found anchors. Every remaining missing phrase
is present in a block incorrectly removed as a page header. The dominant parser
failure is therefore block granularity and furniture classification, not text
recall.

Two repeated audit runs and five repeated artifact JSONL extractions were
byte-identical. Five stream JSONL runs had identical record order and payloads
after removing `document_finished.elapsed_ms`; raw stream bytes differed only in
that runtime observation. The audit records this existing lifecycle-field caveat
instead of treating it as reading-order nondeterminism.

## Corpus Layout

```text
benchmark/eval/
  corpus/
    clean_born_digital/
    academic_two_column/
    scientific_math/
    scanned_typewritten/
    patents/
    financial_tables/
    legal_contracts/
    manuals/
    forms/
    weird_fonts/
    visual_truth/
    financial_table_stress/
    adversarial_corrupt/
  ground_truth/
    page_text/
    spans/
    tables/
    formulas/
    formulas_json/
    form_fields/
    fonts/
    render_oracle/
    reading_order/
  outputs/
    pdf-parser/
    pymupdf/
    pypdfium/
    liteparse/
    nlm_ingestor/
    openparse/
    tesseract_pipeline/
    optional_vlm_oracle/
  table_stress/
    manifest.tsv
    metadata.jsonl
    corpus/
    ground_truth/
```

## Metrics

The Zig harness currently computes CER, WER, token precision/recall/F1,
normalized edit distance, BLEU-4, local alignment, latency summaries, peak RSS,
reading-order text alignment when order labels are supplied, table cell
accuracy when table JSON labels are supplied, and formula BLEU/edit distance
when formula text labels are supplied. Formula JSON labels add formula structure
accuracy for page/text sequence. Form JSON labels add field accuracy for
value-bearing AcroForm name/type/value sequence. Table JSON labels with role,
rowspan, colspan, page, or continuation fields add structure accuracy metrics
for header/row-header/data/note/footer semantics, row spans, column spans, page
identity, continuation links, and source-span coverage. Benchmark schema
`0.2.0` adds the compatible table metrics `table_bbox_iou`,
`table_numeric_accuracy`, `table_header_accuracy`, and
`table_footnote_accuracy`. The result schema also has slots for table detection
F1, TEDS, GriTS, and formula CDM so local specialist adapters can report into
the same records as they come online.

Reading-graph truth adds `reading_graph_precedence_precision`,
`reading_graph_precedence_recall`, `reading_graph_precedence_f1`,
`reading_graph_legacy_precedence_f1`, `reading_graph_required_recall`,
`reading_graph_forbidden_path_rate`, `reading_graph_caption_f1`,
`reading_graph_footnote_f1`, `reading_graph_cycle_rate`,
`reading_graph_ambiguity_preservation`, `reading_graph_valid_projection`, and
eligible/fallback page counts. A metric is `null` only when its truth contract
has no applicable assertions; a declared but entirely missed relation has F1
zero.

Use `zig build native-eval` for checked-in synthetic correctness fixtures and
`zig build eval -- ...` for real corpus documents.

## Benchmark Scorecards

Use `pdf-parser benchmark` when evaluation needs to behave like a product
quality gate instead of a one-off report:

```sh
pdf-parser benchmark \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --suite-id tiny-corpus \
  --tools pdf-parser:adaptive,pdf-parser:native \
  --thresholds benchmark/eval/thresholds.json \
  --output benchmark/eval/outputs/scorecards/tiny-corpus.json \
  --jsonl benchmark/eval/outputs/scorecards/tiny-corpus.records.jsonl
```

The full JSON scorecard and JSONL stream use benchmark schema `0.3.0`, separate
from adaptive extraction schemas. Benchmark versions follow the public output
schema policy: compatible additive metrics use a MINOR bump. Records include
`benchmark_run`,
`benchmark_suite`, `benchmark_lane`, `benchmark_document_result`,
`benchmark_category_summary`, `benchmark_regression`, and
`benchmark_scorecard`. Each record carries `run_id`, `suite_id`,
`manifest_sha256`, `tool_id`, `category`, timing fields, status, and any
warnings/errors represented as skipped document results.

Tool lanes are explicit:

```sh
pdf-parser benchmark --tools pdf-parser:native,pdf-parser:adaptive
pdf-parser benchmark --tools 'command:my-tool=my-extractor --text {pdf}'
```

Unknown optional tools are emitted as skipped unless `--require-tools` is set.
The legacy Python comparator remains useful for PyMuPDF, pypdfium2, and
pdfplumber; a host can wrap those as `command:<id>=...` lanes when it needs them
inside the Zig scorecard.

Parser version comparison is executable-based:

```sh
pdf-parser benchmark \
  --manifest private/manifest.tsv \
  --baseline-command ./releases/pdf-parser-0.7.0 \
  --candidate-command ./zig-out/bin/pdf-parser \
  --thresholds benchmark/eval/thresholds.json \
  --fail-on-regression
```

`benchmark/eval/thresholds.json` defines conservative default regression
tolerance. Lower-is-better metrics such as `cer`, `wer`, normalized edit
distance, latency, and RSS may increase only by their configured
`max_regression`. Higher-is-better metrics such as token F1, reading order,
table structure, formula structure, and form accuracy may decrease only by
their configured `max_regression`. Metrics that are `null` do not fail unless
marked `required`. Schema `0.3.0` also accepts optional `minimum` and `maximum`
values. Those absolute bounds apply to every document in a `candidate` lane and
do not require a baseline executable, preventing two equally degraded versions
from passing a relative-only comparison.

For a standalone candidate gate, select a capability-specific manifest and set
only the metrics that every document in that manifest must produce:

```json
{
  "benchmark_schema_version": "0.3.0",
  "metrics": {
    "token_f1": {
      "direction": "higher",
      "max_regression": 0.02,
      "required": true,
      "minimum": 0.95
    }
  }
}
```

```sh
pdf-parser benchmark \
  --manifest private/hard-fonts.tsv \
  --candidate-command ./zig-out/bin/pdf-parser \
  --thresholds private/hard-fonts-thresholds.json \
  --fail-on-regression
```

Checked-in homogeneous gates live under `benchmark/eval/gates/`. CI runs the
born-digital and hard-font gates alongside the broad tiny-corpus scorecard;
table, OCR, render, and encrypted-twin checks retain their specialist
comparators because their success contracts include structure, routing, pixels,
or twin equivalence rather than text metrics alone.

For Siftable or another ingestion pipeline, map the scorecard JSONL directly:
`benchmark_run` to the processing run, `benchmark_document_result` to per-source
quality evidence, `benchmark_category_summary` to class-level gates, and
`benchmark_regression` to reviewable blocking annotations.

## Comparator Baselines

Use the lightweight comparator for a side-by-side view over the manifest:

```sh
python3 benchmark/eval/compare.py --ensure-releasefast
```

It reports CER, WER, token F1, latency, and RSS for `pdf-parser`, PyMuPDF,
`pypdfium2`, `pdfplumber`, and a named Tesseract lane. The `pdf-parser` lane
uses `zig-out/bin/pdf-parser-eval` by default. With `--ensure-releasefast`
enabled, it runs `zig build -Doptimize=ReleaseFast` before measuring even when
the binary already exists; this avoids accidentally timing a Debug binary after
a normal `zig build`. Its `latency_ms` is parser reported latency, while
`wall_ms` captures subprocess overhead. Use
`--pdf-parser-runner zig-build` only for legacy compatibility. Python baselines
are optional by default; unavailable libraries are shown as skipped so
first-party eval stays runnable on a clean machine. To require all
installed-library baselines and write JSONL:

```sh
python3 benchmark/eval/compare.py \
  --ensure-releasefast \
  --require-baselines \
  --jsonl \
  --output benchmark/eval/outputs/comparison/tiny-corpus.jsonl
```

Add `--pdf-parser-adaptive` when the first-party lane should run adaptive
extraction and OCR-routed pages:

```sh
python3 benchmark/eval/compare.py --require-baselines --pdf-parser-adaptive
```

## Structural qpdf Comparison

Use the structural comparator when changing xref, object stream, encryption,
stream-length, or page-tree recovery. It runs `pdf-parser check --format json`
and `qpdf --check` over the same manifest, then emits one JSONL record per
document:

```sh
.venv/bin/python benchmark/eval/structural_compare.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --output benchmark/eval/outputs/structural/tiny-corpus.jsonl
```

Classifications are intentionally coarse: `both_ok`, `both_warn`,
`pdf_parser_more_strict`, `qpdf_more_strict`, `parser_failed`, and `skipped`.
Exact warning text does not need to match qpdf; the useful signal is whether
the parser can recover, whether qpdf also warns, and which fixture class
regressed. `--strict` runs the first-party check without permissive recovery.

## Lane Profiling

Profile extraction surfaces before tuning parser internals:

```sh
.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/large/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl,ocr-routed \
  --ocr-pages 1-10 \
  --repeat 3 \
  --output benchmark/eval/outputs/profile/large.jsonl
```

The profiler writes one JSONL record per document/lane/repeat with wall time,
peak RSS when `/usr/bin/time` exposes it, input SHA256, output byte count, and
stream parser latency when the lane emits a `document_finished` record. Its
default `--ensure-releasefast` mode also rebuilds ReleaseFast before measuring,
so profiler output stays comparable after local Debug builds. Use the tiny
checked-in manifest for CI smoke tests and the large manifest after populating
`raw_cache/large`. Adaptive JSONL lanes pass `--no-ocr` by default so structured
rendering and OCR subprocess overhead stay separate; add
`--enable-ocr-in-adaptive-lanes` only when intentionally measuring the combined
path. `--ocr-pages` bounds only the OCR lane, which keeps full-manifest native
and adaptive runs useful without OCRing every scanned page. The profiler skips
unbounded `ocr-routed` runs for `scanned_typewritten` documents unless `--pages`,
`--ocr-pages`, or `--allow-full-ocr` is supplied; this prevents an accidental
full-book OCR run from dominating a routine baseline. OCR profiling defaults to
`--ocr-dpi 200` with grayscale rasterization; use `--ocr-dpi 300` when
comparing against older high-resolution runs or validating harder low-quality
scans, and `--ocr-color` to preserve the older RGB raster path for an A/B run.
Pass `--ocr-rasterizer benchmark/eval/pdfium-rasterizer` to exercise the same
OCR lane through PDFium instead of Poppler. The adapter intentionally implements
only the single-page PNG subset invoked by the parser and remains an optional
host-side compatibility component.
Use `--hash-output` for optimization validation runs where byte-for-byte output
stability matters. The hash is computed after each timed subprocess completes,
so it does not change `wall_ms`, but it can add total profiler runtime on very
large JSONL outputs. When hashes are present, `analyze_baseline.py` reports
whether each lane/category group was byte-stable or produced distinct outputs.

For the full baseline workflow, use the wrapper:

```sh
.venv/bin/python benchmark/eval/run_baseline.py --large
```

It builds ReleaseFast, runs the tiny comparator, profiles tiny native/adaptive
lanes, profiles the OCR lane when `tesseract` and `pdftoppm` are present, and
writes the grouped JSON/Markdown report. `--large` profiles
`benchmark/eval/large/manifest.tsv` only when every referenced PDF exists. The
large native/adaptive profile excludes the scanned corpus class by default, then
adds a bounded scanned OCR sample with `--large-ocr-pages 1-10`; this keeps the
baseline representative without OCRing a 295-page scanned book multiple times.
Add `--require-large` when CI should fail instead of skipping missing local
cache inputs. Add `--hash-output` to the wrapper when you want every profiler
lane in the baseline report to include byte-stability hashes.

Summarize comparator and profiler output before choosing an optimization target:

```sh
.venv/bin/python benchmark/eval/analyze_baseline.py \
  --compare-jsonl benchmark/eval/outputs/comparison/tiny-corpus.jsonl \
  --profile-jsonl benchmark/eval/outputs/profile/large.jsonl \
  --manifest benchmark/eval/large/manifest.tsv \
  --output benchmark/eval/outputs/profile/baseline-report.json \
  --table-output benchmark/eval/outputs/profile/baseline-report.md
```

The JSON report groups accuracy by parser/category and performance by
lane/category, records whether manifest PDFs are locally present, ranks measured
optimization candidates, and emits next-action commands for missing corpus or
before/after tuning work. The Markdown table is intended for quick triage and
PR notes; keep public claims conservative unless they cite these ReleaseFast
artifacts. Files written under `benchmark/eval/outputs/` are ignored local run
artifacts; commit scripts, manifests, and docs, not machine-specific timings.

For isolated substring-search evidence, compare the scalar loop, Zig standard
library, and existing SIMD implementation in-process:

```sh
zig build simd-bench -Doptimize=ReleaseFast -- \
  --warmup 100 --repeat 1000 --format json
```

The command reports its Zig version, optimization mode, architecture, resolved
vector width, buffer distribution, iteration counts, medians, and median
absolute deviations. It emits no verdict outside ReleaseFast. A kernel result
is only isolated evidence; pair it with corpus exposure before changing parser
code, and accept “no qualifying target” when representative workloads do not
reach that kernel at vector-sized lengths.

Install optional baselines in your own environment when you want strict
side-by-side numbers:

```sh
python3 -m pip install pymupdf pypdfium2 pdfplumber
```

The Tesseract row is intentionally staged as a placeholder until the OCR
pipeline lands; keep it in the table so OCR regressions have a stable future
slot.
