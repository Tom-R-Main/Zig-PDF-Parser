# Versioned Output Schema

The adaptive JSON and artifact JSONL outputs are the public document
intelligence contract. Internal Zig structs may change; consumers should depend
on the records documented here.

## Version

Current schema version: `0.1.0`

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
`document_manifest` record.

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

## CLI

```bash
pdf-parser extract --adaptive -f json doc.pdf
pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
```

`jsonl` remains a compatibility format for reconciled span JSONL. Use
`artifact-jsonl` for the full versioned stream.
