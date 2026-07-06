"""Tests for startup_checks: verify_chroma_path_on_volume + warn_if_insecure_production."""

from __future__ import annotations

import logging
import os
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from app.startup_checks import verify_chroma_path_on_volume, warn_if_insecure_production


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


# ── warn_if_insecure_production (#65) ────────────────────────────────────────


def _settings(required: bool, app_id: str | None = None) -> SimpleNamespace:
    return SimpleNamespace(app_attest_required=required, app_attest_app_id=app_id)


def _security_errors(records: list[logging.LogRecord]) -> list[str]:
    return [
        r.getMessage()
        for r in records
        if r.levelno == logging.ERROR and "SECURITY" in r.getMessage()
    ]


def test_warn_prod_app_attest_inert_logs_error(caplog) -> None:
    """Prod with App Attest off → a loud SECURITY error (does not raise)."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "production", logger)
    errors = _security_errors(caplog.records)
    assert errors and "INERT" in errors[0]


def test_warn_development_is_silent(caplog) -> None:
    """Non-prod boots never warn, even with App Attest off."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(_settings(required=False), "development", logger)
    assert _security_errors(caplog.records) == []


def test_warn_prod_required_but_no_app_id_logs_error(caplog) -> None:
    """Required-on but APP_ATTEST_APP_ID unset → the second loud error path."""
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id=None), "production", logger
        )
    errors = _security_errors(caplog.records)
    assert errors and "APP_ATTEST_APP_ID" in errors[0]


def test_warn_prod_fully_configured_is_silent(caplog, monkeypatch) -> None:
    """Required-on with an app id and grace off → no warning."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "off")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    assert _security_errors(caplog.records) == []


def test_warn_prod_grace_on_logs_error(caplog, monkeypatch) -> None:
    """Grace on in production → loud SECURITY error, even when App Attest is
    fully configured (#65 follow-up, founder decision #5 2026-07-05)."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="TEAMID.com.missinghue.hangs"),
            "production",
            logger,
        )
    errors = _security_errors(caplog.records)
    assert errors and "LEGACY_USER_ID_GRACE" in errors[0]


def test_warn_development_grace_is_silent(caplog, monkeypatch) -> None:
    """Grace on outside production stays silent — it is the intended dev default."""
    monkeypatch.setenv("LEGACY_USER_ID_GRACE", "on")
    logger = logging.getLogger("test.startup_checks")
    with caplog.at_level(logging.ERROR):
        warn_if_insecure_production(
            _settings(required=True, app_id="x"), "development", logger
        )
    assert _security_errors(caplog.records) == []
