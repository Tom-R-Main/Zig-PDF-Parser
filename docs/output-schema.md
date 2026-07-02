# Versioned Output Schema

The adaptive JSON, artifact JSONL, and streaming JSONL outputs are the public
document intelligence contract. Internal Zig structs may change; consumers
should depend on the records documented here.

## Version

Current schema version: `0.7.0`

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
- `source_id`, or `null` when the caller did not provide one
- `provenance`

JSON output is a `document_manifest` object with arrays of typed records.
`artifact-jsonl` emits one typed record per line and always starts with the
`document_manifest` record. `stream-jsonl` also emits one typed record per line,
but records are produced page by page so host applications can persist partial
artifacts and enqueue embeddings before the document finishes.

Schema `0.7.0` adds specialist protocol records. These are additive and keep the
native Zig kernel deterministic: the parser can emit page/region requests for
local OCR, table, formula, layout, or entity specialists without requiring any
specific external model package.

## Provenance Envelope

Every top-level record carries a shared `provenance` object. Table cells also
carry the same envelope because they are reviewable extraction artifacts.
Existing top-level fields remain for compatibility, but new consumers should
prefer provenance for evidence and routing context.

`provenance` contains:

- `document_id`
- `source_id`, or `null` when the caller did not provide one
- `input_sha256`, or `null` when the caller did not provide one
- `artifact_id`
- `page_index`, or `null` for document-scoped records
- `bbox`, or `null` for document-scoped records
- `source_kind`: `native`, `embedded_ocr`, `fresh_ocr`, `table_model`, `form`,
  `formula`, `debug`, `lifecycle`, `mixed`, or `unknown`
- `confidence`
- `span_ids`
- `block_ids`
- `chunk_ids`
- `route_trace_ids`
- `route_reasons`

Route provenance is matched to the most specific known extraction route:
intersecting region route first, then page route, then stage trace fallback.

## Records

### `document_manifest`

Document/run summary with `document_id`, optional caller-owned `source_id`,
parser version, optional input SHA256, source path, page count, encryption and
corrupt flags, extraction options, route counts, OCR/table/form/formula
extraction counts, artifact counts, output artifact hashes, capability
coverage, warnings, errors, and available output formats.

The manifest is intended to be a durable document-intelligence run record. Batch
JSON and `artifact-jsonl` include `output_artifacts` entries with SHA256 hashes
over canonical record payloads for each artifact family. Streaming manifests
open before page artifacts exist, so they include the same artifact slots with
`sha256:null`; the final `document_finished` event carries final counts.

`capability_coverage` reports implemented and advertised parser capabilities
such as native text, span modeling, layout reconstruction, complexity routing,
reconciliation, table reconstruction, form fields, OCR adapter support, formula
routing, specialist protocol support, debug assets, and streaming. Formula
recognition is currently marked false because formulas are routed but not yet
recognized by a specialist in the default path.

### `span`

Reconciled text span with `span_id`, page index, PDF-coordinate `bbox`, text,
source/chosen source, source mask, confidence, duplicate count, font metadata,
block id, line id, and MCID.

### `block`

Layout/reconciled block with `block_id`, page index, kind, bbox, text, source
mask, confidence, span range, and optional candidate kind.

### `table`

Logical table data artifact with `table_id`, `logical_table_id`,
`table_part_index`, continuation links, page index, block range, bbox,
confidence, column count, table-level source span ids, and rows. Cells include
their own `table_cell` schema header, stable `cell_id`, page index, row, column,
rowspan, colspan, role, confidence, text, raw text, normalized text, deterministic
numeric parse hints, bbox, source span ids, and provenance.

Cell roles are `header`, `row_header`, `data`, `note`, and `footer`. `data` is
the current body-cell role name. Multi-page financial tables are represented as
page-local table records linked by the same `logical_table_id`; each page record
keeps its own geometry and provenance.

### `form_field`

AcroForm field with field id, name, type, value, page/bbox when known,
source span id when emitted as text, and review flags for visible/value
mismatch and missing appearance.

### `route_trace`

Page, region, or stage routing record with page/region scope, stage, route,
confidence, reasons, counts, signals, bbox, and specialist metadata when
available. Route traces include `specialist_request_ids` and
`specialist_status` when a route maps to a request.

### `specialist_request`

Request record for a swappable local specialist. The parser emits these records
when routing says a page or region would benefit from OCR, table, formula,
layout, or entity handling. Default extraction emits requests but does not
invoke table/formula/layout/entity specialists.

Stable fields include `request_id`, `document_id`, optional `source_id`,
optional `input_sha256`, `page_index`, optional `region_index`, page-aware
`bbox`, `route`, `route_reasons`, `signals`, `requested_kind`,
`requested_outputs`, `span_ids`, compact native `spans`, `block_ids`, compact
native `blocks`, `ruling_lines`, optional `crop_image_path`,
`debug_asset_ids`, and provenance with `source_kind:"lifecycle"`.

`requested_kind` is one of `ocr`, `table`, `formula`, `layout`, or `entity`.

### `specialist_response`

Response record from a specialist boundary. Existing Tesseract OCR output is
represented this way when OCR runs. Future subprocess specialists should return
one response JSON object per request through JSONL-over-stdin/stdout.

Stable fields include `request_id`, `response_id`, `specialist_id`,
`specialist_kind`, `status`, `confidence`, returned `spans`, `tables`, `blocks`,
`formulas`, `entities`, `debug_assets`, `warnings`, `errors`, and provenance.

### `specialist_result`

Compact result summary tying returned specialist artifacts back to their
request. Current OCR results report fresh OCR span ids and counts. Future table,
formula, layout, and entity specialists should use the same provenance-bearing
artifact ids.

### `rag_chunk`

Chunk record with chunk id, source id, content, block range, page range, bbox,
source mask, confidence, and source block/span references.

### `debug_asset`

Reference to visual review and coordinate artifacts. Debug assets are always
declared in the public schema; sidecar files are written only when the caller
passes `--debug-assets-dir` or sets the equivalent adapter/schema option.

Debug asset records include `debug_asset_id`, `asset_kind`, compatibility
`kind`, `media_type`, `output_format`, `uri`, `path`, `sha256`, `byte_length`,
`page_index`, `region_index`, `layers`, `stage`, `source_id`, and provenance.
When no asset directory is supplied, `uri`, `path`, `sha256`, and `byte_length`
are `null`.

Current `asset_kind` values:

- `page_overlay_svg`
- `low_confidence_overlay_svg`
- `table_grid_overlay_svg`
- `ocr_route_overlay_svg`
- `span_block_id_overlay_svg`
- `hocr`
- `alto`
- `route_trace_json`

Materialized page assets use deterministic filenames such as
`page-0001.page-overlay.svg`, `page-0001.table-grid.svg`,
`page-0001.ocr-routes.svg`, and `page-0001.span-block-ids.svg`. Document-level
assets include `document.debug.svg`, `document.hocr.html`,
`document.alto.xml`, and `document.route-trace.json`.

### Streaming lifecycle records

`stream-jsonl` adds lifecycle records with the same schema/version header:

- `page_started`: page index, page bbox, event index, sequence scope, and
  running status.
- `page_finished`: page index, page bbox, per-page artifact counts, route
  counts, warnings, and completed status.
- `document_finished`: final artifact counts, route totals, elapsed time, and
  completed status. It also repeats extraction counts and output artifact slots
  with final stream counts; stream artifact hashes remain `null` because records
  are emitted incrementally.

Streamed artifact records keep their batch shapes and add `event_type`,
`event_index`, and `sequence_scope`. Page-scoped records already carry
`page_index`.

Streaming order is deterministic:

```text
document_manifest
page_started
route_trace*
specialist_request*
specialist_response*
specialist_result*
span*
block*
table*
rag_chunk*
debug_asset*
page_finished
debug_asset*
document_finished
```

When `--debug-assets-dir` is provided, page-scoped `debug_asset` records are
emitted before that page's `page_finished` event. Document-scoped debug assets
are emitted near the end of the stream before `document_finished`.

## Siftable Artifact Mapping

`source_id` is intentionally neutral: callers can set it to a database id,
object-store key, URL, CMS id, processing-run source id, or any other external
identifier. The parser does not interpret it.

`stream-jsonl` is designed to map cleanly onto host application artifact
pipelines, including Siftable-style `processing_runs` and `stage_artifacts`:

- `document_manifest` -> `manifest` or run summary, including input hash,
  parser version, page count, encryption/corruption flags, route totals,
  extraction counts, output artifact hash slots, diagnostics, and capability
  coverage
- `page_started`, `page_finished`, `document_finished` -> `status`
- `span`, `block`, `table` -> `extracted_text_ref`
- `route_trace` -> `metadata` or `ocr_ref`
- `specialist_request` -> `metadata`, `specialist_queue_ref`, or review prompt
- `specialist_response`, `specialist_result` -> specialist evidence artifacts
- `rag_chunk` -> `chunk_index_ref`
- `debug_asset` -> `external_ref`

## CLI

```bash
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format stream-jsonl
pdf-parser extract-adaptive --input doc.pdf --format artifact-jsonl --debug-assets-dir review-assets
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 \
  --format artifact-jsonl --emit-specialist-requests requests.jsonl \
  --specialist-config specialists.json
pdf-parser extract --adaptive -f json doc.pdf
pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
pdf-parser extract --adaptive -f stream-jsonl doc.pdf
```

`jsonl` remains a compatibility format for reconciled span JSONL. Use
`artifact-jsonl` for the full batch versioned stream, and `stream-jsonl` when
the caller wants page-level progress and early chunks.

Minimal specialist config shape:

```json
{
  "ocr": { "enabled": true, "executable": "tesseract", "args": [], "timeout_ms": 30000 },
  "table": { "enabled": false, "executable": null, "args": [], "timeout_ms": 30000 },
  "formula": { "enabled": false, "executable": null, "args": [], "timeout_ms": 30000 },
  "layout": { "enabled": false, "executable": null, "args": [], "timeout_ms": 30000 },
  "entity": { "enabled": false, "executable": null, "args": [], "timeout_ms": 30000 }
}
```

The config format is intentionally small. In schema `0.7.0`, it is adapter
plumbing for future local subprocess invocation; the kernel never depends on a
specific Python package or hosted model.
