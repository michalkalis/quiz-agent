"""Next-question query embeddings are remembered in memory (#235 — tests beyond the happy path).

Why this matters to a player: the query texts of the next-question lookup are
few and repeat. Without memory every lookup waits on the paid embeddings
provider, so a slow or down provider degrades ranking for texts the server
already knows. The provider is mocked; nothing here waits on a clock.
"""

from __future__ import annotations

import asyncio

import pytest
from app.retrieval import question_retriever as r

pytestmark = pytest.mark.asyncio


class _Provider:
    def __init__(self, behaviour="fast"):
        self.behaviour = behaviour
        self.texts: list[str] = []

    async def __call__(self, text, **kwargs):
        self.texts.append(text)
        if self.behaviour == "slow":
            await asyncio.Event().wait()
        if self.behaviour == "error":
            raise RuntimeError("503 upstream overloaded")
        return [float(len(text)), 0.0]


@pytest.fixture
def provider(monkeypatch):
    fake = _Provider()
    monkeypatch.setattr(r, "generate_embedding_async", fake)
    monkeypatch.setattr(r, "QUERY_EMBED_TIMEOUT_S", 0.01)
    return fake


async def test_repeated_text_is_not_sent_to_the_provider_again(provider):
    """Money and latency: a repeated text must cost nothing the second time."""
    first = await r.embed_query("history medium en")
    second = await r.embed_query("history medium en")

    assert first == second
    assert provider.texts == ["history medium en"]


async def test_cached_text_is_served_while_provider_is_slow_or_down(provider):
    """The point of the cache: a known text ranks even if the provider dies."""
    await r.embed_query("history medium en")

    for behaviour in ("slow", "error"):
        provider.behaviour = behaviour
        assert await asyncio.wait_for(r.embed_query("history medium en"), 1.0)
    assert len(provider.texts) == 1


async def test_failure_and_timeout_are_not_cached(provider):
    """A transient outage must not pin a text to the unranked fallback."""
    for behaviour in ("error", "slow"):
        provider.behaviour = behaviour
        with pytest.raises(r.QueryEmbeddingUnavailable):
            await r.embed_query("art hard sk")

    provider.behaviour = "fast"
    assert await r.embed_query("art hard sk")  # retried, now succeeds
    assert len(provider.texts) == 3


async def test_cap_evicts_least_recently_used(provider, monkeypatch):
    """Free-form custom topics must not grow memory without limit."""
    monkeypatch.setattr(r, "QUERY_EMBED_CACHE_MAX", 2)
    await r.embed_query("a")
    await r.embed_query("bb")
    await r.embed_query("a")  # refresh "a"; "bb" is now the oldest
    await r.embed_query("ccc")  # evicts "bb"

    assert len(r._query_embed_cache) == 2
    provider.texts.clear()
    await r.embed_query("a")
    assert provider.texts == []
    await r.embed_query("bb")
    assert provider.texts == ["bb"]


async def test_concurrent_misses_return_complete_vectors(provider):
    """Two requests racing on one new text may both call out, never get a half result."""
    a, b = await asyncio.gather(r.embed_query("same"), r.embed_query("same"))

    assert a == b == [4.0, 0.0]
    assert await r.embed_query("same") == [4.0, 0.0]
