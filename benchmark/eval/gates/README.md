# Capability Gates

These small manifests pair homogeneous document capabilities with absolute
quality thresholds. Keep heterogeneous or intentionally unsupported documents
out of a gate instead of weakening one global floor until it becomes
meaningless.

The normal scorecard remains useful for broad observation. A capability gate
must also pass `--fail-on-regression`, which now enforces `required`, `minimum`,
and `maximum` constraints without needing a baseline executable.

```sh
pdf-parser benchmark \
  --manifest benchmark/eval/gates/born-digital.tsv \
  --suite-id born-digital-gate \
  --tools pdf-parser:native \
  --thresholds benchmark/eval/gates/born-digital-thresholds.json \
  --fail-on-regression \
  --fail-on-skipped
```

`hard-fonts.tsv` applies the same exact CER/WER/token contract to native text
from the checked-in ActualText, Type3, CID, vertical CJK, Symbol, and legacy
mathematical-font fixtures. `zig build benchmark-eval` runs both gates.
