# pdf-parser Python bindings

Python bindings for the Zig pdf-parser library. The package is named
`pdf-parser`, while the import path remains `zpdf` for compatibility with the
inherited API.

## Install

Published wheels are platform-specific. From a source checkout, build a wheel
from the current Zig shared library with:

```bash
python3 -m pip install build
python3 -m build --wheel python
```

Repository imports prefer an explicit `PDF_PARSER_LIB` (or legacy `ZPDF_LIB`),
then the current `zig-out/lib` build, and finally a library bundled in an
installed wheel. An explicit override must name an existing file.

## Usage

```python
from zpdf import Document

with Document("paper.pdf") as doc:
    print(doc.page_count)

    # Extract all text (reading order)
    text = doc.extract_all()

    # Extract single page
    page_text = doc.extract_page(0)

    # Extract as markdown
    md = doc.extract_all_markdown()

    # Get text with bounding boxes
    spans = doc.extract_bounds(0)
    for span in spans:
        print(f"{span.text} at ({span.x0}, {span.y0})")
```

### From bytes

```python
with open("doc.pdf", "rb") as f:
    data = f.read()

with Document(data) as doc:
    text = doc.extract_all()
```

## Benchmark

Build the native library in ReleaseFast mode, then use the repository benchmark
harness for current timings:

```bash
zig build -Doptimize=ReleaseFast --summary all
.venv/bin/python benchmark/eval/compare.py \
  --pdf-parser-adaptive \
  --tools pdf-parser,pymupdf,pypdfium2,pdfplumber \
  --ensure-releasefast \
  --manifest benchmark/eval/corpus/manifest.tsv
```

Avoid copying old prose timing tables into reports. Use generated scorecards
and profiler JSONL from the corpus and machine you are evaluating.

## License

MIT for new implementation work. The inherited native base came from
`Lulzx/zpdf` under CC0-1.0; see the repository `NOTICE.md`.
