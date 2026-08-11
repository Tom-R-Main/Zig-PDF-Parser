"""Functional smoke test for an installed platform wheel."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

import zpdf
from zpdf import _ffi


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: wheel_smoke.py WHEEL FIXTURE EXPECTED_LIBRARY")

    wheel = Path(sys.argv[1]).resolve()
    fixture = Path(sys.argv[2]).resolve()
    expected_library = sys.argv[3]
    package_dir = Path(zpdf.__file__).resolve().parent
    selected_library = Path(_ffi._find_library()).resolve()

    assert selected_library.parent == package_dir
    assert selected_library.name == expected_library
    assert "-none-any.whl" not in wheel.name

    with zipfile.ZipFile(wheel) as archive:
        native_members = [
            name
            for name in archive.namelist()
            if name.endswith((".so", ".dylib", ".dll"))
        ]
    assert native_members == [f"zpdf/{expected_library}"], native_members

    with zpdf.Document(fixture) as document:
        text = document.extract_all()
    assert "Clean born digital text" in text

    artifacts = zpdf.extract_adaptive(
        fixture,
        source_id="wheel-smoke",
        format="artifact-jsonl",
    )
    assert '"record_type":"document_manifest"' in artifacts.splitlines()[0]


if __name__ == "__main__":
    main()
