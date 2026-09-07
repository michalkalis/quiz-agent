"""GET /api/v1/languages is the app's language menu — #168 SK/CS, T21 (DD14/DD15).

Why it matters: before this endpoint the iOS picker hard-coded all ten
languages, so hiding one (or bringing one back once its translated corpus is
approved) needed a code change and a TestFlight build. The whole point of the
endpoint is that the *contents* come from the environment — if these tests ever
pass against a hard-coded list, the deploy-time flip is dead and the language
rollout is back to needing App Store review.

``quiz`` and ``pack_order`` are deliberately different lists: packs are
generated in English and only stamped with the ordered code (DD15), so ordering
a non-EN pack would silently deliver English.
"""

from __future__ import annotations

import httpx
import pytest

from app.main import app


async def _get_languages() -> httpx.Response:
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        return await client.get("/api/v1/languages")


@pytest.mark.asyncio
async def test_defaults_are_servable_three_and_english_packs(monkeypatch):
    """No env set → the DD14/DD15 defaults, not the full ten-language list."""
    monkeypatch.delenv("SERVABLE_QUIZ_LANGUAGES", raising=False)
    monkeypatch.delenv("PACK_ORDER_LANGUAGES", raising=False)

    response = await _get_languages()

    assert response.status_code == 200
    assert response.json() == {"quiz": ["en", "sk", "cs"], "pack_order": ["en"]}


@pytest.mark.asyncio
async def test_adding_a_language_is_an_env_flip(monkeypatch):
    """Re-enabling Polish must not require a code change or a client build."""
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,sk,cs,pl")

    response = await _get_languages()

    assert response.json()["quiz"] == ["en", "sk", "cs", "pl"]
    # Pack ordering is a separate lever and must not follow along (DD15).
    assert response.json()["pack_order"] == ["en"]


@pytest.mark.asyncio
async def test_unknown_env_code_is_ignored_not_served(monkeypatch):
    """A typo in the env var must never reach the client as a real language."""
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "en,xx,sk")

    assert (await _get_languages()).json()["quiz"] == ["en", "sk"]


@pytest.mark.asyncio
async def test_all_unknown_env_falls_back_to_defaults(monkeypatch):
    """A fully bogus env var must not leave the app offering *no* languages.

    An empty ``quiz`` list would make every picker empty and every session
    unstartable — a worse outage than the typo it came from.
    """
    monkeypatch.setenv("SERVABLE_QUIZ_LANGUAGES", "xx,yy")

    assert (await _get_languages()).json()["quiz"] == ["en", "sk", "cs"]


@pytest.mark.asyncio
async def test_endpoint_needs_no_auth():
    """The client fetches this at launch, before it has any identity."""
    assert (await _get_languages()).status_code == 200
