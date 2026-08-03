# Provenance

This project began from the public-domain `Lulzx/zpdf` codebase:

- Source: https://github.com/Lulzx/zpdf
- Imported base commit: `5eba7ade759d32b0d425eb905c17106b484dee30`
- Upstream license at import: CC0-1.0

The inherited CC0 license text is preserved in
`LICENSES/CC0-1.0.txt`. New implementation work in this repository is
licensed under the MIT License in `LICENSE`.

The public package/tool identity for this fork is `pdf-parser` for CLI usage
and `pdf_parser` for Zig artifacts. Existing `zpdf_*` C/WASM symbols remain as
compatibility exports while the native parser model is being rebuilt.

Generated predefined CMap and CID-to-Unicode tables in
`src/cmap_resources.zig` and `src/cmap_resources.bin` derive from Adobe's
BSD-3-Clause resources:

- `adobe-type-tools/cmap-resources`, revision
  `f5cf3bca7fdfeaceb77aa82847e974f2306c20b4`
- `adobe-type-tools/mapping-resources-pdf`, revision
  `2dd5e53fb74a01718b9dfd448a0d1cce6fff2aa5`

Their license notices are preserved in
`LICENSES/Adobe-CMap-Resources-BSD-3-Clause.txt`.
