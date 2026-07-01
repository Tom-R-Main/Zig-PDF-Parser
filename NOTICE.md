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
