# Versioned Output Schema

The adaptive JSON, artifact JSONL, and streaming JSONL outputs are the public
document intelligence contract. Internal Zig structs may change; consumers
should depend on the records documented here.

## Version

Current schema version: `0.2.0`

The project is still pre-`1.0.0`, so incompatible schema changes may happen.
Every fixture-tested schema change should still update the schema version.

- PATCH: output bug fix with no field, removal, type, or meaning change.
- MINOR: additive compatible fields or new record types.
- MAJOR: removal, rename, type change, enum meaning change, required-field
  change, or bbox/page/index semantic change.

Every public JSON object includes:

- `schema_name`
- `schema_version`
- `record_type`

JSON output is a `document_manifest` object with arrays of typed records.
`artifact-jsonl` emits one typed record per line and always starts with the
`document_manifest` record. `stream-jsonl` also emits one typed record per line,
but records are produced page by page so host applications can persist partial
artifacts and enqueue embeddings before the document finishes.

## Records

### `document_manifest`

Document/run summary with `document_id`, parser version, optional input SHA256,
source path, page count, encryption state, extraction options, route counts,
artifact counts, warnings, and available output formats.

### `span`

Reconciled text span with `span_id`, page index, PDF-coordinate `bbox`, text,
source/chosen source, source mask, confidence, duplicate count, font metadata,
block id, line id, and MCID.

### `block`

Layout/reconciled block with `block_id`, page index, kind, bbox, text, source
mask, confidence, span range, and optional candidate kind.

### `table`

Logical table with `table_id`, page index, block range, bbox, confidence,
column count, and rows. Cells include page index, row, column, rowspan, colspan,
role, confidence, text, bbox, and source span ids when available.

### `form_field`

AcroForm field with field id, name, type, value, page/bbox when known,
source span id when emitted as text, and review flags for visible/value
mismatch and missing appearance.

### `route_trace`

Page, region, or stage routing record with page/region scope, stage, route,
confidence, reasons, counts, signals, bbox, and specialist metadata when
available.

### `rag_chunk`

Chunk record with chunk id, source id, content, block range, page range, bbox,
source mask, confidence, and source block/span references.

### `debug_asset`

Reference to debug artifacts such as debug SVG overlays, route trace JSON,
hOCR, and ALTO outputs. Each record includes kind, media type, output format,
URI when materialized, page/region scope, and producing stage.

### Streaming lifecycle records

`stream-jsonl` adds lifecycle records with the same schema/version header:

- `page_started`: page index, page bbox, event index, sequence scope, and
  running status.
- `page_finished`: page index, page bbox, per-page artifact counts, route
  counts, warnings, and completed status.
- `document_finished`: final artifact counts, route totals, elapsed time, and
  completed status.

Streamed artifact records keep their batch shapes and add `event_type`,
`event_index`, and `sequence_scope`. Page-scoped records already carry
`page_index`.

Streaming order is deterministic:

```text
document_manifest
page_started
route_trace*
span*
block*
table*
rag_chunk*
page_finished
debug_asset*
document_finished
```

The page block repeats for each requested page.

## Siftable Artifact Mapping

`stream-jsonl` is designed to map cleanly onto Siftable-style
`processing_runs` and `stage_artifacts`:

- `document_manifest` -> `manifest`
- `page_started`, `page_finished`, `document_finished` -> `status`
- `span`, `block`, `table` -> `extracted_text_ref`
- `route_trace` -> `metadata` or `ocr_ref`
- `rag_chunk` -> `chunk_index_ref`
- `debug_asset` -> `external_ref`

## CLI

```bash
pdf-parser extract --adaptive -f json doc.pdf
pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
pdf-parser extract --adaptive -f stream-jsonl doc.pdf
```

`jsonl` remains a compatibility format for reconciled span JSONL. Use
`artifact-jsonl` for the full batch versioned stream, and `stream-jsonl` when
the caller wants page-level progress and early chunks.
