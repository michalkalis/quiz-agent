"""#249.6 — a shared daily challenge arrives in a chat as a link whose preview
is a score card.

Why these matter: the preview is the whole message for the friend, and it is
built by a crawler that reads only the page's Open Graph tags. So the tags must
carry the sender's score in the quiz language, point at an absolute image of
exactly 1200x630, never leak a question or an answer, and never fail: a link
whose share is unknown (or not a daily) still previews as a generic card.
These need no database: the page only reads one share.
"""

from __future__ import annotations

import io
import json
import re
from datetime import date
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from PIL import Image

from app.api.routes import share_card
from app.rate_limit import limiter
from app.shared_quiz.card import CardData, render
from app.shared_quiz.service import ShareError

pytestmark = pytest.mark.asyncio

TOKEN = "K7m2QxAb9"
SECRET_QUESTION = "Which planet is the Red Planet?"


def _share(**fields):
    base = dict(
        kind="daily",
        language="sk",
        sender_score=4.0,
        sender_total=5,
        sender_marks=[True, True, False, True, True],
        challenge_date=date(2026, 11, 26),
        sender_name="Jana",
        question_ids=["q-red-planet", "q2", "q3", "q4", "q5"],
        # Fields that must never reach a page:
        title=SECRET_QUESTION,
        topic="secret",
    )
    base.update(fields)
    return SimpleNamespace(**base)


class FakeService:
    def __init__(self, share=None, error=None):
        self.share, self.error = share, error

    async def by_token(self, token):
        if self.error:
            raise self.error
        if self.share is None:
            raise ShareError(404, "not_found", "Shared quiz not found")
        return self.share


async def _get(path, share=None, error=None, service=True):
    limiter.reset()
    app = FastAPI()
    app.state.limiter = limiter
    app.include_router(share_card.router)
    if service:
        app.state.shared_quiz = FakeService(share, error)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
        return await c.get(path)


def _tags(html: str) -> dict:
    return dict(re.findall(r'<meta property="([^"]+)" content="([^"]*)"', html))


async def test_link_page_tags_carry_the_score_in_the_quiz_language():
    resp = await _get(f"/play?s={TOKEN}", _share())
    tags = _tags(resp.text)
    assert resp.status_code == 200
    # The friend reads this line in the chat: who, how many, of how many.
    assert tags["og:title"] == "Jana má dnes 4 z 5"
    assert tags["og:description"] == "Tie isté otázky. Dáš viac?"
    # Absolute HTTPS, stable per share: WhatsApp caches the URL hard.
    assert tags["og:image"] == f"https://api.trubbo.app/og/play/{TOKEN}.png"
    assert (tags["og:image:width"], tags["og:image:height"]) == ("1200", "630")


@pytest.mark.parametrize(
    "language,expected",
    [
        ("cs", "Jana má dnes 4 z 5"),
        ("en", "Jana got 4 of 5 today"),
        ("uk", "Jana: сьогодні 4 з 5"),
    ],
)
async def test_title_follows_the_share_language(language, expected):
    resp = await _get(f"/play?s={TOKEN}", _share(language=language))
    assert _tags(resp.text)["og:title"] == expected


async def test_no_question_or_answer_can_reach_the_page():
    resp = await _get(f"/play?s={TOKEN}", _share())
    # A spoiler in a chat preview would ruin the day for every friend.
    assert SECRET_QUESTION not in resp.text
    assert "q-red-planet" not in resp.text
    assert "secret" not in resp.text


async def test_a_sender_name_cannot_inject_markup():
    resp = await _get(f"/play?s={TOKEN}", _share(sender_name='"><script>x()</script>'))
    # The name is typed by a player; a tag break-out would run on the page.
    assert "<script>x()" not in resp.text
    assert "&lt;script&gt;" in _tags(resp.text)["og:title"]


async def test_unknown_share_still_gets_a_generic_page_and_card():
    page = await _get(f"/play?s={TOKEN}", share=None)
    image = await _get(f"/og/play/{TOKEN}.png", share=None)
    # A deleted or mistyped link must preview, not error: no crash, no score.
    assert page.status_code == 200 and image.status_code == 200
    assert "Daily challenge in Trubbo" == _tags(page.text)["og:title"]
    assert Image.open(io.BytesIO(image.content)).size == (1200, 630)


async def test_lookup_failure_is_a_generic_card_not_a_500():
    resp = await _get(f"/play?s={TOKEN}", error=RuntimeError("db down"))
    # The database being down must not turn a chat preview into an error.
    assert resp.status_code == 200
    assert _tags(resp.text)["og:title"] == "Daily challenge in Trubbo"


async def test_no_service_and_garbage_token_are_generic():
    no_service = await _get(f"/play?s={TOKEN}", service=False)
    garbage = await _get("/play?s=%3Cb%3E")
    assert no_service.status_code == garbage.status_code == 200
    assert "<b>" not in garbage.text


async def test_a_round_share_gets_the_generic_card():
    resp = await _get(f"/play?s={TOKEN}", _share(kind="round"))
    # Only the daily has a card design; a round's score is not shown here.
    assert _tags(resp.text)["og:title"] == "Denná výzva v Trubbe"


async def test_image_endpoint_returns_a_1200x630_png():
    resp = await _get(f"/og/play/{TOKEN}.png", _share())
    assert resp.headers["content-type"] == "image/png"
    assert "max-age" in resp.headers["cache-control"]
    img = Image.open(io.BytesIO(resp.content))
    assert img.format == "PNG" and img.size == (1200, 630)


async def test_card_differs_with_the_score():
    a = render(CardData("sk", 4, 5, (True,) * 4 + (False,), 11, 26, "Jana"))
    b = render(CardData("sk", 2, 5, (True, True, False, False, False), 11, 26, "Jana"))
    # The card is the message: a different result must draw a different image.
    assert a != b


async def test_aasa_serves_play_for_both_apps_like_the_website():
    resp = await _get("/.well-known/apple-app-site-association")
    served = resp.json()["applinks"]["details"]
    site = (
        Path(__file__).parents[3]
        / "apps/website/public/.well-known/apple-app-site-association"
    )
    on_site = json.loads(site.read_text())["applinks"]["details"]
    # Same app ids, so a link here opens whichever Trubbo is installed.
    assert [d["appIDs"] for d in served] == [d["appIDs"] for d in on_site]
    for d in served:
        assert d["components"] == [{"/": "/play", "?": {"s": "?*"}}]
