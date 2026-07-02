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

The runner emits one JSONL record per document with text, layout-adjacent,
table/formula, latency, RSS, and provenance counters. Missing specialist ground
truth is represented as `null`, so the same schema works for native text-only
fixtures and richer labeled corpora.

Manifest rows have four required TSV columns:
`category`, `doc_id`, `pdf_path`, and `truth_text_path`. Three optional columns
can follow: `truth_table_json_path`, `truth_reading_order_path`, and
`truth_formula_path`. Empty optional columns are allowed when a later specialist
truth file is present. Table truth emits `table_cell_accuracy`; reading-order
truth emits `reading_order_score`; formula truth emits `formula_bleu` and
`formula_edit_distance`.

External task evaluators can feed their scores into the same record:

```sh
zig build eval -- corpus/scientific_math/example.pdf \
  --truth-text ground_truth/page_text/example.txt \
  --truth-table-json ground_truth/tables/example.json \
  --truth-reading-order ground_truth/reading_order/example.txt \
  --truth-formula ground_truth/formulas/example.txt \
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
when formula labels are supplied. The result schema also has slots for table
detection F1, TEDS, GriTS, and formula CDM so local specialist adapters can
report into the same records as they come online.

Use `zig build native-eval` for checked-in synthetic correctness fixtures and
`zig build eval -- ...` for real corpus documents.

## Comparator Baselines

Use the lightweight comparator for a side-by-side view over the manifest:

```sh
python3 benchmark/eval/compare.py
```

It reports CER, WER, token F1, latency, and RSS for `pdf-parser`, PyMuPDF,
`pypdfium2`, `pdfplumber`, and a named Tesseract lane. Python baselines are
optional by default; unavailable libraries are shown as skipped so first-party
eval stays runnable on a clean machine. To require all installed-library
baselines and write JSONL:

```sh
python3 benchmark/eval/compare.py \
  --require-baselines \
  --jsonl \
  --output benchmark/eval/outputs/comparison/tiny-corpus.jsonl
```

Add `--pdf-parser-adaptive` when the first-party lane should run adaptive
extraction and OCR-routed pages:

```sh
python3 benchmark/eval/compare.py --require-baselines --pdf-parser-adaptive
```

Install optional baselines in your own environment when you want strict
side-by-side numbers:

```sh
python3 -m pip install pymupdf pypdfium2 pdfplumber
```

The Tesseract row is intentionally staged as a placeholder until the OCR
pipeline lands; keep it in the table so OCR regressions have a stable future
slot.
