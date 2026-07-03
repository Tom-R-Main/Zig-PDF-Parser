# AGENTS.md

Repository-specific guidance for work in `/Users/thomasmain/projects/pdf-parser`.

## Project Posture

- This is a capable pre-1.0 Zig PDF parser, not an alpha toy. Treat public claims conservatively, but assume the core architecture is real and worth preserving.
- Target Zig is `0.16.0`; check `.zig-version`, `build.zig`, nearby code, and `zig version` before changing Zig APIs.
- The default integration surface is deterministic CLI/JSONL: `pdf-parser extract-adaptive --input ... --format artifact-jsonl|stream-jsonl`.
- Keep Siftable useful, but keep the parser neutral. Do not add Siftable-specific tables, enums, paths, or assumptions inside parser code.

## Architecture

- Preserve the layered model:
  - native PDF kernel: parser, xref, pagetree, decompression, encryption, encoding, interpreter, struct tree, layout.
  - adaptive pipeline: native spans -> layout blocks -> complexity routes -> OCR/specialist/table/form/formula paths -> reconciler -> outputs.
  - public boundary: versioned schema, artifact JSONL, streaming JSONL, C ABI, Python binding, server wrapper.
  - quality boundary: fixtures, eval, benchmark runner, external comparator, lane profiler.
- Prefer span-first, provenance-first designs. Public artifacts should retain page, bbox, source kind, confidence, stable ids, route reasons, and source/input identity where available.
- Internal Zig structs may evolve freely; documented JSON/JSONL schemas are the public contract.
- Do not make OCR/table/formula specialists part of the Zig kernel. Use deterministic routing plus protocol records and local subprocess/FFI adapters.

## Implementation Rules

- Match the existing Zig 0.16 style: explicit allocators, explicit writers, `errdefer` for partial initialization, and clear ownership of allocated buffers.
- Use `apply_patch` for manual edits. Avoid broad formatting churn unless it is part of the requested task.
- Keep changes small and reviewable. Do not rewrite unrelated parser layers while fixing one capability.
- Avoid destructive git or filesystem operations unless the user explicitly asks. Build caches such as `.zig-cache` and `zig-out` may be removed only when cleanup is requested.
- Never print secrets. Do not open `.env`, key, certificate, or password files unless explicitly requested.
- Large or redistribution-unclear PDFs belong under ignored benchmark cache paths, not in git.

## Public Schema Discipline

- Current adaptive schema version is defined in `src/specialist_protocol.zig` and re-exported through `src/schema.zig`.
- If a public JSON/JSONL field is added, removed, renamed, retyped, or changes meaning, update `docs/output-schema.md`, tests, and the schema version according to the documented policy.
- Preserve compatibility fields when adding richer records unless the user explicitly requests a breaking cleanup.
- Every public artifact type should include `schema_name`, `schema_version`, `record_type`, `source_id`, and `provenance` unless a test intentionally documents an exception.
- `artifact-jsonl` is batch manifest-first JSONL. `stream-jsonl` is page-by-page lifecycle JSONL. Keep their ordering deterministic.

## Tests And Gates

Run the narrowest meaningful checks first, then broaden. For normal Zig changes:

```sh
zig fmt --check $(git ls-files '*.zig')
zig build test --summary all
zig build --summary all
```

For shared-library or host-integration changes:

```sh
zig build shared --summary all
```

For adaptive, schema, OCR, table, encryption, or fixture changes, also consider:

```sh
zig build eval -- --adaptive --ocr-executable tesseract --ocr-rasterizer pdftoppm --manifest benchmark/eval/corpus/manifest.tsv
pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv --tools pdf-parser:adaptive --output /tmp/pdf-parser-scorecard.json
```

For performance claims, use ReleaseFast and benchmark tooling. Do not claim speedups from Debug builds or one-off timings:

```sh
zig build -Doptimize=ReleaseFast --summary all
.venv/bin/python benchmark/eval/profile_lanes.py --manifest benchmark/eval/corpus/manifest.tsv --lanes native-text,adaptive-artifact-jsonl --output /tmp/pdf-parser-profile.jsonl
```

## Fixture And Benchmark Policy

- The checked-in corpus under `benchmark/eval/corpus` is for small deterministic correctness tests.
- Large public or private performance PDFs belong under ignored `benchmark/eval/raw_cache/large`.
- Commit manifests, metadata, scripts, and small/redacted fixtures when appropriate; do not commit bulky raw downloads.
- Keep external tool comparisons explicit and neutral. Use ReleaseFast comparator paths when measuring `pdf-parser`.
- If a synthetic fixture passes too easily, add a harder real-world or derived fixture before tuning behavior around it.

## Git Hygiene

- Work on the current branch unless the user asks for a branch.
- Stage only files relevant to the requested change.
- Before committing, check `git status --short` and avoid including unrelated local output, caches, virtualenv files, or benchmark run products.
- Commit messages should name the capability or boundary changed, for example `Add encrypted PDF manifest metadata` or `Profile adaptive JSONL lanes`.

## Documentation Tone

- Keep README claims evidence-backed and command-oriented.
- Prefer “capable pre-1.0 parser” over “alpha” or hype.
- When comparing with other parsers, describe measured local lanes and feature boundaries rather than broad universal rankings.
- Document host integration as neutral artifact mapping, not as Siftable-only behavior.
