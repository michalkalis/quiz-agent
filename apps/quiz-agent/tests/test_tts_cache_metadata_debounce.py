"""Reads must not pay for the whole metadata file.

WHY this matters -- not just what it does: ``TTSCache.get`` used to call
``_save_metadata()`` on every cache HIT, rewriting the entire ``metadata.json``
just to record a new access time. That is an O(entries) JSON write on the read
hot path -- every question audio playback -- and it gets slower as the cached
corpus grows, which is exactly the direction the corpus moves. Access times only
feed eviction order, so they are debounced: kept exact in memory, written at
most once per ``METADATA_FLUSH_INTERVAL_S``, plus immediately on writes and on
shutdown. These tests pin both halves of that trade: no per-read write, and no
lost bookkeeping (eviction order stays correct, disk state survives a stop).
"""

from __future__ import annotations

import json

import pytest
from app.tts import cache as cache_module
from app.tts.cache import TTSCache

VOICE = "nova"
BLOB = b"x" * 400_000  # 0.4 MB — three of these overflow a 1 MB cache


@pytest.fixture
def cache(tmp_path):
    """A 1 MB cache on tmp_path — never the real ./data/tts_cache."""
    return TTSCache(cache_dir=str(tmp_path / "tts_cache"), max_size_mb=1)


def _saves(monkeypatch, cache: TTSCache) -> list:
    """Record every metadata write this cache performs."""
    calls: list = []
    original = cache._save_metadata

    def _counted():
        calls.append(1)
        original()

    monkeypatch.setattr(cache, "_save_metadata", _counted)
    return calls


def test_cache_hit_does_not_rewrite_metadata(cache, monkeypatch):
    """The read hot path performs zero metadata writes within the interval."""
    cache.set("question one", VOICE, BLOB)
    saves = _saves(monkeypatch, cache)

    for _ in range(5):
        assert cache.get("question one", VOICE) == BLOB

    assert saves == []


def test_cache_hit_still_wins_eviction(cache):
    """Debouncing must not corrupt LRU order: an entry read after another was
    written must survive the eviction that the untouched one loses. Otherwise
    the debounce would evict exactly the audio being played most."""
    cache.set("old", VOICE, BLOB)
    cache.set("stale", VOICE, BLOB)

    cache.get("old", VOICE)  # touched — now the most recently used

    cache.set("new", VOICE, BLOB)  # 1.2 MB > 1 MB cap → one eviction

    cached = {cache._hash(t, VOICE) for t in ("old", "new")}
    assert set(cache.lru) == cached
    assert cache.get("stale", VOICE) is None


def test_writes_persist_immediately(cache, tmp_path):
    """A `set` changes which files exist, so it still writes through: a restart
    that missed it would re-synthesize audio already paid for and on disk."""
    cache.set("question one", VOICE, BLOB)

    reloaded = TTSCache(cache_dir=str(tmp_path / "tts_cache"), max_size_mb=1)
    assert reloaded.get("question one", VOICE) == BLOB


def test_flush_persists_debounced_access_times(cache, tmp_path):
    """A normal shutdown must not drop the debounced access times — main.py
    calls flush() on lifespan shutdown."""
    cache.set("question one", VOICE, BLOB)
    key = cache._hash("question one", VOICE)
    written_at = json.loads(cache.metadata_path.read_text())[key]["last_access"]

    cache.get("question one", VOICE)
    touched_at = cache.lru[key].last_access
    assert touched_at > written_at  # in-memory bookkeeping is exact...
    on_disk = json.loads(cache.metadata_path.read_text())[key]["last_access"]
    assert on_disk == written_at  # ...and deliberately not yet on disk

    cache.flush()

    assert json.loads(cache.metadata_path.read_text())[key]["last_access"] == touched_at


def test_hit_writes_once_the_interval_has_elapsed(cache, monkeypatch):
    """The debounce is a delay, not a drop: once the interval passes, the next
    read persists — a long-running process never accumulates unbounded drift."""
    cache.set("question one", VOICE, BLOB)
    saves = _saves(monkeypatch, cache)
    monkeypatch.setattr(cache_module, "METADATA_FLUSH_INTERVAL_S", 0.0)

    cache.get("question one", VOICE)

    assert len(saves) == 1
