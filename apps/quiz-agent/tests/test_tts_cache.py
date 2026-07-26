"""The TTS cache must survive a deploy.

WHY this matters -- not just what it does: ``TTSService`` defaults its cache to
``./data/tts_cache``, which inside the container resolves to
``/app/data/tts_cache`` -- an ephemeral image layer. ``main.py`` used to
construct a bare ``TTSService()``, so every ``fly deploy`` threw the whole
cached corpus away and the next sessions re-paid OpenAI TTS for questions that
had already been synthesized. The Fly volume mounts at ``/data``, so the fix is
the same env-var indirection the sibling stores use (``RATINGS_DATABASE_URL``,
``TRANSLATION_CACHE_URL``): prod sets ``TTS_CACHE_DIR=/data/tts_cache``. These
tests fail if the construction site stops honouring that env var -- i.e. if the
cache silently moves back onto the throwaway layer.
"""

from __future__ import annotations

import pytest


class _StopAfterTTS(Exception):
    """Aborts the lifespan right after the TTS service is constructed."""


async def _lifespan_tts_kwargs(monkeypatch, tmp_path) -> dict:
    """Boot main's lifespan far enough to capture the TTSService kwargs.

    Everything the lifespan needs before that point is stubbed onto tmp_path;
    the schema check is neutralized because it would need a live Postgres.
    """
    from app import main, startup_checks

    monkeypatch.setenv("OPENAI_API_KEY", "sk-test-dummy")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost:5432/quiz")
    monkeypatch.setenv("RATINGS_DATABASE_URL", f"sqlite:///{tmp_path}/ratings.db")
    monkeypatch.setenv("TRANSLATION_CACHE_URL", f"sqlite:///{tmp_path}/translations.db")

    # The lifespan asserts it runs from apps/quiz-agent (an "app" dir must
    # exist) and creates ./data — keep both inside tmp_path.
    workdir = tmp_path / "wd"
    (workdir / "app").mkdir(parents=True)
    monkeypatch.chdir(workdir)

    async def _at_head(*args, **kwargs):
        return None

    monkeypatch.setattr(startup_checks, "assert_migrations_at_head", _at_head)

    captured: dict = {}

    def _spy_tts(**kwargs):
        captured.update(kwargs)
        raise _StopAfterTTS

    monkeypatch.setattr(main, "TTSService", _spy_tts)

    with pytest.raises(_StopAfterTTS):
        async with main.lifespan(main.app):
            pass

    return captured


@pytest.mark.asyncio
async def test_main_tts_cache_dir_honours_env(monkeypatch, tmp_path):
    """TTS_CACHE_DIR wins — that is what puts the cache on the Fly volume."""
    volume_cache = tmp_path / "volume" / "tts_cache"
    monkeypatch.setenv("TTS_CACHE_DIR", str(volume_cache))

    kwargs = await _lifespan_tts_kwargs(monkeypatch, tmp_path)

    assert kwargs["cache_dir"] == str(volume_cache)


@pytest.mark.asyncio
async def test_main_tts_cache_dir_defaults_to_local_data(monkeypatch, tmp_path):
    """Without the env var the default stays ./data/tts_cache — local dev and
    tests must be unchanged by the prod indirection."""
    monkeypatch.delenv("TTS_CACHE_DIR", raising=False)

    kwargs = await _lifespan_tts_kwargs(monkeypatch, tmp_path)

    assert kwargs["cache_dir"] == "./data/tts_cache"
