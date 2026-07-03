# Large Benchmark Corpus

This directory contains manifests and source metadata for local performance
benchmarks. It does not contain the PDFs themselves. Full-size PDFs and qpdf
derivatives live under `benchmark/eval/raw_cache/large/`, which is ignored by
git.

Use this corpus for timing and memory work, not correctness scoring. The tiny
checked-in corpus under `benchmark/eval/corpus/` remains the labeled eval
corpus.

```sh
.venv/bin/python benchmark/eval/fetch_large_corpus.py --dry-run
.venv/bin/python benchmark/eval/fetch_large_corpus.py --download --derive
.venv/bin/python benchmark/eval/fetch_large_corpus.py --verify

.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/large/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl,ocr-routed \
  --ocr-pages 1-10 \
  --output benchmark/eval/outputs/profile/large.jsonl
```

Adaptive JSONL lanes disable OCR by default so full scanned documents do not
hide renderer costs behind Tesseract subprocess time. OCR profiling uses 200 DPI
grayscale rasterization by default, and `--ocr-pages` bounds only the
`ocr-routed` lane. Add `--ocr-color` for a compatibility A/B run against the
older RGB raster path.

The encrypted derivative uses the known benchmark password
`benchmark-password`. This is not a secret; it exists only to exercise
known-password parsing and should not be reused for private files.
