"""Wikimedia requires an identifying User-Agent (#167 sourcing block).

Why these scenarios:

- ``test_every_wikimedia_request_sends_user_agent``: Wikimedia now answers
  UA-less ``api.php`` requests with HTTP 403 (phabricator T400119). Without the
  header EVERY grounded sourcing run silently gets 0 Wikipedia facts, which is
  how this went unnoticed. The header must ride on the client used for all
  Wikimedia calls, not on one hand-patched call site.
- ``test_http_error_logs_warning_and_returns_empty``: one rejected source must
  not kill the sourcing run (the other sources still run, so the return
  contract stays "a list"), but it must be visible — the pre-fix code collapsed
  a 403 into an empty list that looked exactly like "no facts for this topic".

No network: httpx's transport layer is replaced with a handler double, so a
real request would fail loudly.
"""

from __future__ import annotations

import json
import logging

import httpx
import pytest
from app.sourcing import wikipedia_source
from app.sourcing.wikipedia_source import USER_AGENT, WikipediaSource

WIKI_LOGGER = wikipedia_source.__name__

_SEARCH_PAYLOAD = {
    "query": {
        "search": [
            {
                "title": "Taylor Swift",
                "snippet": "an American singer-songwriter whose <b>narrative</b> "
                "songwriting has been widely acclaimed by critics",
            }
        ]
    }
}


def _install_transport(monkeypatch: pytest.MonkeyPatch, handler) -> list[httpx.Request]:
    """Route every ``httpx.AsyncClient`` in the module through ``handler``.

    The real client class is kept (only a mock transport is injected) so the
    header merging under test is httpx's own, not a stub's.
    """
    seen: list[httpx.Request] = []
    real_client = httpx.AsyncClient

    def recording_handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    def factory(**kwargs):
        return real_client(transport=httpx.MockTransport(recording_handler), **kwargs)

    monkeypatch.setattr(wikipedia_source.httpx, "AsyncClient", factory)
    return seen


async def test_every_wikimedia_request_sends_user_agent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen = _install_transport(
        monkeypatch,
        lambda request: httpx.Response(200, text=json.dumps(_SEARCH_PAYLOAD)),
    )

    facts = await WikipediaSource().get_facts(count=5, topics=["Taylor Swift", "Oscars"])

    assert seen, "no Wikimedia request was made — the test would pass vacuously"
    for request in seen:
        assert request.headers.get("user-agent") == USER_AGENT
    # Wikimedia's policy wants a product string plus a way to reach us; a bare
    # library default (what httpx sends unasked) is what gets 403'd.
    assert "QuizAgentBot" in USER_AGENT
    assert "michal.kalis@gmail.com" in USER_AGENT
    assert facts, "a 200 response with results must still yield facts"


async def test_http_error_logs_warning_and_returns_empty(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    _install_transport(
        monkeypatch,
        lambda request: httpx.Response(403, text="Please set a user-agent"),
    )

    with caplog.at_level(logging.WARNING, logger=WIKI_LOGGER):
        facts = await WikipediaSource().get_facts(count=5, topics=["Taylor Swift"])

    assert facts == []
    logged = [r.getMessage() for r in caplog.records if r.name == WIKI_LOGGER]
    assert any("403" in m and "Taylor Swift" in m for m in logged), logged
