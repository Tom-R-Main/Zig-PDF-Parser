#!/usr/bin/env python3
"""Render one PDF page through PDFium using the pdftoppm OCR contract."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-q", action="store_true", help="Accepted for pdftoppm compatibility")
    parser.add_argument("-png", action="store_true", help="Emit PNG output")
    parser.add_argument("-gray", action="store_true", help="Emit an 8-bit grayscale PNG")
    parser.add_argument("-singlefile", action="store_true", help="Emit <prefix>.png")
    parser.add_argument("-r", type=positive_int, default=200, metavar="DPI")
    parser.add_argument("-f", type=positive_int, required=True, metavar="PAGE")
    parser.add_argument("-l", type=positive_int, required=True, metavar="PAGE")
    parser.add_argument("input_pdf", type=Path)
    parser.add_argument("output_prefix", type=Path)
    return parser


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def output_path(prefix: Path, singlefile: bool, page_number: int) -> Path:
    if singlefile:
        return Path(f"{prefix}.png")
    return Path(f"{prefix}-{page_number}.png")


def render_page(input_pdf: Path, page_number: int, dpi: int, grayscale: bool, destination: Path) -> None:
    try:
        import pypdfium2 as pdfium  # type: ignore
    except ImportError as err:
        raise RuntimeError("pypdfium2 is required for the PDFium rasterizer") from err

    document = pdfium.PdfDocument(str(input_pdf))
    try:
        if page_number > len(document):
            raise RuntimeError(f"page {page_number} is outside the {len(document)}-page document")
        page = document[page_number - 1]
        try:
            bitmap = page.render(scale=dpi / 72.0)
            try:
                image = bitmap.to_pil().copy()
            finally:
                close = getattr(bitmap, "close", None)
                if close is not None:
                    close()
        finally:
            page.close()
    finally:
        document.close()

    destination.parent.mkdir(parents=True, exist_ok=True)
    image.convert("L" if grayscale else "RGB").save(destination, format="PNG")


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not args.png:
        raise SystemExit("PDFium rasterizer requires -png")
    if args.f != args.l:
        raise SystemExit("PDFium rasterizer supports one page per invocation")
    destination = output_path(args.output_prefix, args.singlefile, args.f)
    try:
        render_page(args.input_pdf, args.f, args.r, args.gray, destination)
    except Exception as err:
        print(f"pdfium rasterizer: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
