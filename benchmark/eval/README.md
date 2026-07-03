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
scanned/typewritten image-only input, financial tables, forms, and adversarial
page-tree recovery.

`benchmark/eval/corpus/metadata.jsonl` is the provenance sidecar for the tiny
checked-in corpus. Each row records the fixture id, source note, redistribution
status, PDF SHA256, and expected OCR/table/formula route counts. Manifest eval
loads this sidecar automatically when it sits next to `manifest.tsv` and fails
if the adaptive counters differ from those expectations. Large or raw third-party
corpora should live under `benchmark/eval/raw_cache/`, which is ignored by git;
checked-in PDFs should stay small, redistributable reductions.

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
truth file is present. Table truth emits `table_cell_accuracy`; reading-order
truth emits `reading_order_score`; formula truth emits `formula_bleu` and
`formula_edit_distance`; formula JSON truth emits `formula_structure_accuracy`
over formula page/text sequence; form JSON truth emits `form_field_accuracy`
over field name/type/value sequence. Richer table truth may include `rowspan`, `colspan`,
`role`, `bbox`, and `page`; when span fields are present the runner also emits
`table_span_accuracy`, and when role fields are present it emits
`table_role_accuracy`.

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
    adversarial_corrupt/
  ground_truth/
    page_text/
    spans/
    tables/
    formulas/
    formulas_json/
    form_fields/
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
identity, continuation links, and source-span coverage. The result schema also
has slots for table detection F1, TEDS, GriTS, and formula CDM so local
specialist adapters can report into the same records as they come online.

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

The full JSON scorecard and JSONL stream use benchmark schema `0.1.0`, separate
from adaptive extraction schemas. Records include `benchmark_run`,
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
marked `required`.

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

Install optional baselines in your own environment when you want strict
side-by-side numbers:

```sh
python3 -m pip install pymupdf pypdfium2 pdfplumber
```

The Tesseract row is intentionally staged as a placeholder until the OCR
pipeline lands; keep it in the table so OCR regressions have a stable future
slot.
