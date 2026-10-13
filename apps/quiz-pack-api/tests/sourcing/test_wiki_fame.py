"""`app.sourcing.wiki_fame` — Wikimedia pageviews as a popularity proxy (#201, #202).

Why: seed selection drops the bottom third of ideas by fame, so a wrong URL
(daily vs monthly endpoint) or a portal page leaking in as a "topic" skews the
whole seed list. No network: httpx.MockTransport records the URLs.
"""

from __future__ import annotations

from datetime import date

import httpx
from app.sourcing import wiki_fame


def _client(payload: dict, seen: list[str], status: int = 200) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(status, json=payload)

    return httpx.Client(transport=httpx.MockTransport(handler))


_TOP = {
    "items": [
        {
            "articles": [
                {"article": "Main_Page", "views": 999},
                {"article": "Špeciálne:Hľadať", "views": 500},
                {"article": "StarDance", "views": 300},
                {"article": "Ewa_Farna", "views": 200},
            ]
        }
    ]
}


def test_top_daily_hits_the_per_day_endpoint_and_drops_portal_pages() -> None:
    seen: list[str] = []
    rows = wiki_fame.top_daily(_client(_TOP, seen), "cs", date(2026, 10, 7), limit=10)
    assert seen == [f"{wiki_fame.PAGEVIEWS_API}/top/cs.wikipedia/all-access/2026/10/07"]
    assert rows == [(300, "StarDance"), (200, "Ewa Farna")]


def test_top_monthly_uses_all_days_and_honours_limit() -> None:
    seen: list[str] = []
    rows = wiki_fame.top(_client(_TOP, seen), "sk", 2026, 9, limit=1)
    assert seen[0].endswith("/top/sk.wikipedia/all-access/2026/09/all-days")
    assert rows == [(300, "StarDance")]


def test_views_sums_the_month_and_unknown_title_is_zero() -> None:
    seen: list[str] = []
    payload = {"items": [{"views": 40}, {"views": 2}]}
    assert wiki_fame.views(_client(payload, seen), "en", 2026, 2, "Ewa Farna") == 42
    assert "/Ewa_Farna/monthly/2026020100/2026022800" in seen[0]
    assert wiki_fame.views(_client({}, [], status=404), "en", 2026, 2, "Nope") == 0
