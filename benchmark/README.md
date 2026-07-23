# Benchmarks

Scripts for measuring pdf-parser correctness, throughput, memory, and external
tool comparisons. Build ReleaseFast artifacts before using timings for parser
decisions.

## Requirements

- Build pdf-parser first: `zig build -Doptimize=ReleaseFast`
- Install MuPDF: `brew install mupdf` (macOS) or `apt install mupdf-tools` (Linux)
- Python 3 with tqdm: `pip install tqdm`

## Current Benchmark Surface

Use the product-facing benchmark and eval harness for current work:

```bash
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

.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/large/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl,ocr-routed \
  --repeat 3 \
  --hash-output \
  --output benchmark/eval/outputs/profile/large.jsonl

python3 benchmark/eval/ocr_form_quality.py \
  --parser zig-out/bin/pdf-parser \
  --output /tmp/pdf-parser-ocr-form-quality.json
```

`benchmark/eval/corpus` is the small checked-in correctness corpus.
The raster-only expenditure form has exact row, date, vendor, amount, and total
truth. `ocr_form_quality.py` applies absolute token-recall and numeric
exact-match floors and fails when OCR tools are unavailable; CI installs
Poppler and Tesseract specifically for this lane.
`benchmark/eval/large` describes ignored local performance fixtures for
100-page, 1k-page, image-heavy, object-stream-heavy, encrypted, and table-heavy
PDFs.

## veraPDF Corpus Benchmark

Legacy script for testing against 2,907 PDFs from the
[veraPDF test corpus](https://github.com/veraPDF/veraPDF-corpus). Prefer the
current benchmark runner above for release and optimization decisions.

### Setup

```bash
cd benchmark
git clone https://github.com/veraPDF/veraPDF-corpus.git verapdf
```

### Run

```bash
python3 verapdf_bench.py
```

### Results

Do not treat checked-in prose as the benchmark source of truth. Generate fresh
ReleaseFast scorecards and profile JSONL on the machine and corpus being used
for the decision.

## Accuracy Benchmark

Compare character-level accuracy against MuPDF reference output.

```bash
PYTHONPATH=../python python3 accuracy.py
```

Requires `pypdfium2`: `pip install pypdfium2`

## Memory Regression Guard

Check repeated full-document extraction for accuracy-mode memory regressions.

```bash
PYTHONPATH=../python python3 memory_guard.py --pdf docs/pdf_reference.pdf
```

If you want this check in pytest as well, run:

```bash
ZPDF_RUN_MEMORY_GUARDS=1 PYTHONPATH=python python3 -m pytest -q python/tests/test_memory_regression.py
```
