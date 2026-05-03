"""Tests for startup_checks.verify_chroma_path_on_volume."""

from __future__ import annotations

import os
from pathlib import Path
from unittest.mock import patch

import pytest

from app.startup_checks import verify_chroma_path_on_volume


class _FakeStat:
    def __init__(self, dev: int) -> None:
        self.st_dev = dev


def _make_path_factory(path_to_dev: dict[str, int], existing: set[str]):
    """Build a factory that returns a Path-like object with controlled stat/exists."""

    def factory(arg: str):
        dev = path_to_dev.get(arg, path_to_dev.get("__default__", 1))
        exists = arg in existing

        class _P:
            def exists(self_inner) -> bool:
                return exists

            def stat(self_inner) -> _FakeStat:
                return _FakeStat(dev)

        return _P()

    return factory


def test_skipped_outside_fly(tmp_path: Path) -> None:
    """Local dev (no FLY_APP_NAME) must not raise even when path is on root fs."""
    with patch.dict(os.environ, {}, clear=False):
        os.environ.pop("FLY_APP_NAME", None)
        verify_chroma_path_on_volume(str(tmp_path))


def test_passes_when_path_on_separate_volume() -> None:
    """On Fly with chroma on a real mounted volume, no error."""
    factory = _make_path_factory(
        path_to_dev={"/data/chroma": 99, "/": 1},
        existing={"/data/chroma"},
    )
    with patch.dict(os.environ, {"FLY_APP_NAME": "quiz-agent-api"}):
        with patch("app.startup_checks.Path", side_effect=factory):
            verify_chroma_path_on_volume("/data/chroma")


def test_raises_when_path_on_root_fs() -> None:
    """On Fly with chroma sharing device id with /, raise with diagnostic info."""
    factory = _make_path_factory(
        path_to_dev={"/app/data/chroma": 42, "/": 42},
        existing={"/app/data/chroma"},
    )
    with patch.dict(os.environ, {"FLY_APP_NAME": "quiz-agent-api"}):
        with patch("app.startup_checks.Path", side_effect=factory):
            with patch(
                "app.startup_checks._read_proc_mounts",
                return_value=["/dev/vdb /data ext4 rw 0 0"],
            ):
                with pytest.raises(RuntimeError) as excinfo:
                    verify_chroma_path_on_volume("/app/data/chroma")

    msg = str(excinfo.value)
    assert "/app/data/chroma" in msg
    assert "ephemeral" in msg.lower()
    assert "fly.toml" in msg


def test_raises_when_path_missing() -> None:
    """If somehow the path doesn't exist after makedirs, raise loudly."""
    factory = _make_path_factory(
        path_to_dev={"/data/chroma": 99},
        existing=set(),
    )
    with patch.dict(os.environ, {"FLY_APP_NAME": "quiz-agent-api"}):
        with patch("app.startup_checks.Path", side_effect=factory):
            with pytest.raises(RuntimeError, match="does not exist"):
                verify_chroma_path_on_volume("/data/chroma")
