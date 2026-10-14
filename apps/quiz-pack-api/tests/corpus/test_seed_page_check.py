"""Keyword page check of the weekly fresh seeds (#202, founder 2026-10-14).

Why: the seed call no longer reads pages (web_fetch cost $6–16 per language),
so this check is what catches a seed whose source page is about something
else. It must drop a mismatch, but never drop a seed just because a page could
not be read (the per-question web fact-check still verifies facts), and it
must not miss Slovak / Czech names written with or without diacritics, or
declined — otherwise sk/cs, the languages with the most domestic seeds, would
lose good seeds.
"""

from __future__ import annotations

import httpx
import pytest
from app.corpus.seed_filters import Seed
from app.corpus.seed_page_check import check_pages, fetch_page_text, page_mentions

FILLER = " Lorem ipsum dolor sit amet, consectetur adipiscing elit." * 10


def _seed(subject, url="https://example.sk/a", wiki=None):
    return Seed(subject, "fact", "angle", url, wiki_title=wiki)


def test_names_match_without_diacritics_and_with_slavic_endings():
    assert page_mentions("Víťazom sa stal Simon Plesko." + FILLER, ["Šimon Pleško"])
    assert page_mentions("Rozhovor so Šimonom Pleškom" + FILLER, ["Simon Plesko"])


def test_a_page_about_something_else_does_not_match():
    assert not page_mentions(
        "Recenzia nového albumu skupiny Elán." + FILLER, ["Šimon Pleško"]
    )
    # Both words of a two-word name are needed: a shared first name is not enough.
    assert not page_mentions("Šimon Kováč vyhral súťaž." + FILLER, ["Šimon Pleško"])


@pytest.mark.asyncio
async def test_check_keeps_matches_drops_mismatches_and_keeps_unreadable_pages():
    seeds = [
        _seed("Šimon Pleško", "https://a.sk/1"),
        _seed("Stranger Things", "https://b.com/2", wiki="Stranger Things (season 5)"),
        _seed("Dune", "https://c.com/3"),
        _seed("Blocked", "https://d.com/4"),
        _seed("Tiny", "https://e.com/5"),
    ]
    pages = {
        "https://a.sk/1": "Simon Plesko vydal nový singel." + FILLER,
        "https://b.com/2": "Stranger Things returns for a final season." + FILLER,
        "https://c.com/3": "A review of Barbie." + FILLER,
        "https://d.com/4": None,  # fetch failed / blocked / not HTML
        "https://e.com/5": "Tiny",  # JS app or consent wall: too little text
    }

    async def fetch(url):
        return pages[url]

    kept, counts = await check_pages(seeds, fetch)
    assert [s.subject for s in kept] == [
        "Šimon Pleško",
        "Stranger Things",
        "Blocked",
        "Tiny",
    ]
    assert counts == {"page_ok": 2, "page_mismatch": 1, "page_unchecked": 2}


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_fetch_returns_visible_text_and_none_for_non_html_or_errors():
    html = (
        "<html><head><title>Šimon Pleško</title><script>var hidden='Barbie';</script>"
        "</head><body><p>Spevák &amp; moderátor</p></body></html>"
    )

    def handler(request):
        if request.url.path == "/page":
            return httpx.Response(200, html=html)
        if request.url.path == "/pdf":
            return httpx.Response(
                200, content=b"%PDF", headers={"content-type": "application/pdf"}
            )
        return httpx.Response(403, html="<p>blocked</p>")

    async with _client(handler) as client:
        text = await fetch_page_text(client, "https://x.sk/page")
        assert "Šimon Pleško" in text and "Spevák & moderátor" in text
        assert "Barbie" not in text  # script content is not page text
        assert await fetch_page_text(client, "https://x.sk/pdf") is None
        assert await fetch_page_text(client, "https://x.sk/blocked") is None

    def boom(request):
        raise httpx.ConnectTimeout("slow")

    async with _client(boom) as client:
        assert await fetch_page_text(client, "https://x.sk/page") is None
