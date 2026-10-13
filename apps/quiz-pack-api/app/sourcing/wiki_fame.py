"""How famous is a topic in the player's language? (#201 201.1, #202)

Wikipedia pageviews are the popularity proxy (PopQA, arXiv 2212.10511): a
subject people actually read about is one a casual player can have a guess
at. Used when collecting seed facts for fresh entertainment runs — pick the
famous thing first, then look for the surprising angle.

Library home of what ``scripts/entity_fame.py`` used to hold inline, so the
weekly fresh-topup job (#202) shares it. Everything talks to the keyless
Wikimedia REST pageviews API through a caller-supplied sync ``httpx.Client``
(build one with :func:`make_client`); every function returns plain
``(views, title)`` rows or an int, highest views first where ordered.
"""

from __future__ import annotations

import calendar
from datetime import date
from urllib.parse import quote

import httpx

PAGEVIEWS_API = "https://wikimedia.org/api/rest_v1/metrics/pageviews"
# Wikimedia requires an identifying User-Agent for API clients.
HEADERS = {"User-Agent": "TrubboQuiz/1.0 (https://trubbo.app; hi@trubbo.app)"}
# Namespace prefixes / portal pages that are not topics (en, sk, cs).
NOT_TOPICS = (
    "Special:", "Špeciálne:", "Speciální:", "Main_Page", "Hlavná_stránka",
    "Hlavní_strana", "Wikipedia:", "Wikipédia:", "Wikipedie:", "wiki.phtml",
)


def make_client(timeout: float = 30) -> httpx.Client:
    """A client with the identifying User-Agent Wikimedia asks for."""
    return httpx.Client(headers=HEADERS, timeout=timeout)


def _topic_rows(articles: list[dict], limit: int) -> list[tuple[int, str]]:
    rows = [
        (a["views"], a["article"].replace("_", " "))
        for a in articles
        if not a["article"].startswith(NOT_TOPICS)
    ]
    return rows[:limit]


def top(
    client: httpx.Client, lang: str, year: int, month: int, limit: int
) -> list[tuple[int, str]]:
    """Most-read articles of a finished month (ideas for what is talked about)."""
    url = f"{PAGEVIEWS_API}/top/{lang}.wikipedia/all-access/{year}/{month:02d}/all-days"
    resp = client.get(url)
    resp.raise_for_status()
    return _topic_rows(resp.json()["items"][0]["articles"], limit)


def top_daily(
    client: httpx.Client, lang: str, day: date, limit: int = 100
) -> list[tuple[int, str]]:
    """Most-read articles of one day — the per-day twin of :func:`top`.

    The weekly job calls this for each of the last days to see what is being
    read *now*, where the monthly list is a month late.
    """
    url = (
        f"{PAGEVIEWS_API}/top/{lang}.wikipedia/all-access/"
        f"{day.year}/{day.month:02d}/{day.day:02d}"
    )
    resp = client.get(url)
    resp.raise_for_status()
    return _topic_rows(resp.json()["items"][0]["articles"], limit)


def views(client: httpx.Client, lang: str, year: int, month: int, title: str) -> int:
    """Monthly views of one article (fame of a seed's main subject); 0 if unknown."""
    last_day = calendar.monthrange(year, month)[1]
    article = quote(title.replace(" ", "_"), safe="")
    url = (
        f"{PAGEVIEWS_API}/per-article/{lang}.wikipedia/all-access/user/{article}/monthly/"
        f"{year}{month:02d}0100/{year}{month:02d}{last_day}00"
    )
    resp = client.get(url, follow_redirects=True)
    if resp.status_code == 404:
        return 0
    resp.raise_for_status()
    return sum(item["views"] for item in resp.json().get("items", []))
