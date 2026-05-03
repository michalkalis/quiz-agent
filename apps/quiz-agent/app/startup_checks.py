"""Startup invariants that must hold before the API begins serving traffic.

Each check raises a clear `RuntimeError` on failure. Failures crash the worker
during Fly's health-check grace period so the deploy rolls back cleanly.
"""

from __future__ import annotations

import os
from pathlib import Path


def _read_proc_mounts() -> list[str]:
    """Return non-empty lines from /proc/mounts, or [] if unreadable."""
    try:
        with open("/proc/mounts", "r", encoding="utf-8") as f:
            return [line.strip() for line in f if line.strip()]
    except OSError:
        return []


def verify_chroma_path_on_volume(chroma_path: str) -> None:
    """Assert that `chroma_path` lives on a mounted Fly volume in production.

    Background: see memory `project_prod_chroma_mount.md`. Twice now, the
    `CHROMA_PATH` env var has drifted out of sync with `fly.toml [[mounts]]
    destination`, leaving ChromaDB writing to the ephemeral container
    filesystem. Every deploy then silently wipes the question database.

    This check runs only when `FLY_APP_NAME` is set (i.e. on a Fly machine),
    and compares the device id of `chroma_path` with the device id of `/`.
    A mounted volume always has a different device id; a path on the root
    filesystem (ephemeral) shares it. If they match, raise loudly so the
    health check fails and the deploy rolls back instead of silently
    corrupting prod state.
    """
    if not os.getenv("FLY_APP_NAME"):
        return

    path = Path(chroma_path)
    if not path.exists():
        raise RuntimeError(
            f"CHROMA_PATH does not exist after makedirs: {chroma_path}. "
            "This should be impossible — investigate filesystem permissions."
        )

    chroma_dev = path.stat().st_dev
    root_dev = Path("/").stat().st_dev

    if chroma_dev != root_dev:
        return

    mounts = _read_proc_mounts()
    mount_lines = "\n  ".join(mounts) if mounts else "(unable to read /proc/mounts)"
    raise RuntimeError(
        "CHROMA_PATH is on the ephemeral container filesystem, not on a "
        "mounted Fly volume. Every deploy will wipe the question database.\n\n"
        f"  CHROMA_PATH = {chroma_path}\n"
        f"  device id   = {chroma_dev} (same as / — ephemeral)\n\n"
        "Fix: align the `CHROMA_PATH` Fly secret with the `[[mounts]] destination` "
        "in `apps/quiz-agent/fly.toml`. See memory `project_prod_chroma_mount.md`.\n\n"
        f"Current /proc/mounts:\n  {mount_lines}"
    )
