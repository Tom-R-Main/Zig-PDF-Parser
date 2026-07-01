import os
import sys
from pathlib import Path
from cffi import FFI

ffi = FFI()

_cdef_path = Path(__file__).parent / "_cdef.h"
with open(_cdef_path) as f:
    ffi.cdef(f.read())

def _find_library():
    candidates = []

    if "PDF_PARSER_LIB" in os.environ:
        candidates.append(Path(os.environ["PDF_PARSER_LIB"]))
    if "ZPDF_LIB" in os.environ:
        candidates.append(Path(os.environ["ZPDF_LIB"]))

    pkg_dir = Path(__file__).parent
    if sys.platform == "darwin":
        candidates.append(pkg_dir / "libpdf_parser.dylib")
        candidates.append(pkg_dir / "libzpdf.dylib")
    elif sys.platform == "win32":
        candidates.append(pkg_dir / "pdf_parser.dll")
        candidates.append(pkg_dir / "zpdf.dll")
    else:
        candidates.append(pkg_dir / "libpdf_parser.so")
        candidates.append(pkg_dir / "libzpdf.so")

    repo_root = pkg_dir.parent.parent
    lib_dir = repo_root / "zig-out" / "lib"
    if sys.platform == "darwin":
        candidates.append(lib_dir / "libpdf_parser.dylib")
        candidates.append(lib_dir / "libzpdf.dylib")
    elif sys.platform == "win32":
        candidates.append(lib_dir / "pdf_parser.dll")
        candidates.append(lib_dir / "zpdf.dll")
    else:
        candidates.append(lib_dir / "libpdf_parser.so")
        candidates.append(lib_dir / "libzpdf.so")

    for path in candidates:
        if path.exists():
            return str(path)

    raise ImportError(f"Could not find pdf-parser library. Searched: {candidates}")

lib = ffi.dlopen(_find_library())
