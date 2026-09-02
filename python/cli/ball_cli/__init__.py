"""``ball_cli`` — the ``ball`` command-line interface for the Python toolchain.

Public API: :func:`ball_cli.cli.run` (``run(argv, stdout, stderr) -> int``), the
in-process entry point every test drives. ``python -m ball_cli`` / the ``ball``
console script wrap it.
"""

from __future__ import annotations

_DIST_NAME = "ball-lang"
#: Reported when running from a checkout rather than an installed distribution.
SOURCE_VERSION = "0.0.0+source"


def _installed_version() -> str | None:
    """The installed ``ball-lang`` distribution version, or ``None`` in a checkout.

    Single-sourced from the installed metadata rather than a hardcoded literal:
    ``.github/workflows/publish-pypi.yml`` injects the version from the
    ``python-pypi/vX.Y.Z`` tag it is triggered by, so a hardcoded constant here
    would drift from what PyPI actually serves (issue #496).
    """
    try:
        from importlib.metadata import PackageNotFoundError, version
    except ImportError:  # pragma: no cover - stdlib since 3.8
        return None
    try:
        return version(_DIST_NAME)
    except PackageNotFoundError:
        return None


__version__: str = _installed_version() or SOURCE_VERSION


def version_line() -> str:
    """The one-line ``ball --version`` banner."""
    if _installed_version() is None:
        return f"ball {SOURCE_VERSION} (Python toolchain, running from a source checkout)"
    return f"ball {__version__} (Python toolchain)"


from .cli import run  # noqa: E402 — after __version__, which cli.py imports

__all__ = ["run", "version_line", "__version__", "SOURCE_VERSION"]
