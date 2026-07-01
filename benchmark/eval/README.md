# Evaluation Harness

`pdf-parser` treats evaluation as a first-class build target:

```sh
zig build eval -- corpus/clean_born_digital/example.pdf \
  --truth-text ground_truth/page_text/example.txt \
  --category clean_born_digital \
  --doc-id example \
  --output outputs/pdf-parser/example.jsonl
```

The runner emits one JSONL record per document with text, layout-adjacent,
table/formula, latency, RSS, and provenance counters. Missing specialist ground
truth is represented as `null`, so the same schema works for native text-only
fixtures and richer labeled corpora.

External task evaluators can feed their scores into the same record:

```sh
zig build eval -- corpus/scientific_math/example.pdf \
  --truth-text ground_truth/page_text/example.txt \
  --category scientific_math \
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
and reading-order LCS when order labels are supplied. The result schema also has
slots for table detection F1, TEDS, GriTS, formula BLEU, formula edit distance,
and CDM so local specialist adapters can report into the same records as they
come online.

Use `zig build native-eval` for checked-in synthetic correctness fixtures and
`zig build eval -- ...` for real corpus documents.
