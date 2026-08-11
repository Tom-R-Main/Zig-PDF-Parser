import os
import sys
from pathlib import Path
from cffi import FFI

ffi = FFI()

_cdef_path = Path(__file__).parent / "_cdef.h"
with open(_cdef_path) as f:
    ffi.cdef(f.read())


def _library_names():
    if sys.platform == "darwin":
        return ("libpdf_parser.dylib", "libzpdf.dylib")
    if sys.platform == "win32":
        return ("pdf_parser.dll", "zpdf.dll")
    return ("libpdf_parser.so", "libzpdf.so")


def _find_library():
    for variable in ("PDF_PARSER_LIB", "ZPDF_LIB"):
        configured = os.environ.get(variable)
        if configured is None:
            continue
        path = Path(configured).expanduser().resolve()
        if not path.is_file():
            raise ImportError(f"{variable} does not name a file: {path}")
        return str(path)

    pkg_dir = Path(__file__).parent
    repo_root = pkg_dir.parent.parent
    library_names = _library_names()
    candidates = []

    # A source checkout must exercise the current Zig build, not a stale binary
    # copied beside the Python package. Installed wheels have no build.zig and
    # therefore skip this checkout-only path.
    if (repo_root / "build.zig").is_file():
        lib_dir = repo_root / "zig-out" / "lib"
        candidates.extend(lib_dir / name for name in library_names)

    candidates.extend(pkg_dir / name for name in library_names)

    for path in candidates:
        if path.is_file():
            return str(path.resolve())

    raise ImportError(f"Could not find pdf-parser library. Searched: {candidates}")

lib = ffi.dlopen(_find_library())
