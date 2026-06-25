"""Filesystem helpers that locate repo files by walking *up* from a known
module, instead of indexing a fixed number of parent directories.

Why this module exists (issue #60.P3, twin of #70): code that needs the repo
root -- alembic ``env.py`` in both apps, and the quiz-pack-api ARQ worker --
used ``Path(__file__).resolve().parents[N]`` with a hard-coded ``N``. That index
is correct only for the local checkout. In the Docker image the app is copied to
``/app``, so there are *fewer* parent levels than locally and ``parents[N]``
raised ``IndexError`` -- which crashed in-container ``alembic upgrade head`` in
both apps (the ``.env`` lookup runs unconditionally at import time). Walking up
until the filesystem root is exhausted can never raise, so it is robust to
whatever depth the code is mounted at and degrades to a no-op when the target is
absent (the ``/app`` layout has no repo ``.env`` above it).
"""

from __future__ import annotations

from pathlib import Path


def find_in_ancestors(start: Path, relative: str | Path) -> Path | None:
    """Return ``ancestor / relative`` for the *closest* ancestor of ``start``
    where that path is a file, or ``None`` if no ancestor contains it.

    ``start`` is treated as a file path (pass ``Path(__file__)``); the search
    begins at its containing directory and walks toward the filesystem root.
    Never raises when nothing is found -- a missing target must degrade
    gracefully, not crash a migration or worker bootstrap (see module docstring).
    """
    start_dir = start.resolve().parent
    relative = Path(relative)
    for directory in (start_dir, *start_dir.parents):
        candidate = directory / relative
        if candidate.is_file():
            return candidate
    return None


def load_dotenv_from_ancestors(start: Path, filename: str = ".env") -> Path | None:
    """Find the closest ``.env`` above ``start`` and load it (without overriding
    already-set environment variables), returning its path or ``None``.

    Returns ``None`` -- never raises -- when python-dotenv is not installed or no
    ``.env`` exists above ``start`` (e.g. the Docker ``/app`` layout). Callers run
    this at import time on the migration bootstrap path, where failure to find a
    ``.env`` must fall through to the real OS environment variables.
    """
    try:
        from dotenv import load_dotenv
    except ImportError:
        return None

    env_path = find_in_ancestors(start, filename)
    if env_path is not None:
        load_dotenv(env_path, override=False)
    return env_path
