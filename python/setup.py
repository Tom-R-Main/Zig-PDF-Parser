"""Build platform wheels containing the Zig shared library."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.build_py import build_py
from wheel.bdist_wheel import bdist_wheel


def _library_name() -> str:
    if sys.platform == "darwin":
        return "libpdf_parser.dylib"
    if sys.platform == "win32":
        return "pdf_parser.dll"
    return "libpdf_parser.so"


def _configured_library() -> tuple[str, Path] | None:
    for variable in ("PDF_PARSER_LIB", "ZPDF_LIB"):
        configured = os.environ.get(variable)
        if configured is None:
            continue
        path = Path(configured).expanduser().resolve()
        if not path.is_file():
            raise RuntimeError(f"{variable} does not name a file: {path}")
        return variable, path
    return None


class BinaryDistribution(Distribution):
    """Mark the CFFI ABI package as platform-dependent."""

    def has_ext_modules(self) -> bool:
        return True


class BuildPyWithZig(build_py):
    def run(self) -> None:
        package_root = Path(__file__).resolve().parent
        repo_root = package_root.parent
        library_name = _library_name()
        configured = _configured_library()

        if configured is not None:
            _, source = configured
        elif (repo_root / "build.zig").is_file():
            subprocess.run(
                ["zig", "build", "shared", "-Doptimize=ReleaseFast", "--summary", "all"],
                cwd=repo_root,
                check=True,
            )
            source = repo_root / "zig-out" / "lib" / library_name
        else:
            raise RuntimeError(
                "the source distribution does not contain the Zig project; "
                "build from a repository checkout or set PDF_PARSER_LIB"
            )

        if not source.is_file():
            raise RuntimeError(f"native pdf-parser library was not produced at {source}")

        super().run()
        destination = Path(self.build_lib) / "zpdf" / library_name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


class PlatformWheel(bdist_wheel):
    """Use a Python-independent but platform-specific wheel tag."""

    def finalize_options(self) -> None:
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        _, _, platform_tag = super().get_tag()
        if sys.platform == "darwin" and platform_tag.endswith("_universal2"):
            platform_tag = platform_tag[: -len("_universal2")] + f"_{platform.machine()}"
        return "py3", "none", platform_tag


setup(
    distclass=BinaryDistribution,
    cmdclass={"build_py": BuildPyWithZig, "bdist_wheel": PlatformWheel},
)
