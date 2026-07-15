# Financial Table Stress Pack

This pack is for table accuracy, not general parser speed. Checked-in PDFs are
small deterministic reductions that model common real-world shapes:

- `sec-statement-continuation`: repeated headers, continuation links, footnotes,
  and accountant notation.
- `bank-statement-borderless`: sparse transaction rows and right-aligned
  numeric columns without ruling lines.
- `invoice-wrapped-totals`: wrapped descriptions and footer totals.
- `procurement-nested-header`: nested headers and mixed units/prices.
- `legal-schedule-out-of-order`: cells drawn out of visual reading order.

Run the first-party eval lane:

```sh
zig build eval -- --adaptive --manifest benchmark/eval/table_stress/manifest.tsv
```

Run the optional comparator:

```sh
.venv/bin/python benchmark/eval/table_compare.py \
  --manifest benchmark/eval/table_stress/manifest.tsv \
  --output /tmp/pdf-parser-table-stress.jsonl
```

`sources.tsv` is for larger public or private source PDFs and derived page-window
reductions. Keep bulky or redistribution-unclear files under ignored cache paths
such as `benchmark/eval/raw_cache/table_stress/`.
