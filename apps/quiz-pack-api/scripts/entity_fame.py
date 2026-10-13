#!/usr/bin/env python3
"""How famous is a topic in the player's language? (#201 201.1)

Wikipedia pageviews are the popularity proxy (PopQA, arXiv 2212.10511): a
subject people actually read about is one a casual player can have a guess
at. Used when collecting seed facts for fresh entertainment runs — pick the
famous thing first, then look for the surprising angle.

Two modes, both against the keyless Wikimedia REST pageviews API:

    # most-read articles of a month (ideas for what is talked about)
    python scripts/entity_fame.py top --lang sk --month 2026-09 --limit 100

    # monthly views of given articles (fame of a seed's main subject)
    python scripts/entity_fame.py views --lang cs --month 2026-09 "StarDance" "Ewa Farna"

Prints ``views<TAB>title`` lines, highest first. A title with no data prints 0.
"""

from __future__ import annotations

import argparse
import calendar
import sys
from urllib.parse import quote

import httpx

_API = "https://wikimedia.org/api/rest_v1/metrics/pageviews"
# Wikimedia requires an identifying User-Agent for API clients.
_HEADERS = {"User-Agent": "TrubboQuiz/1.0 (https://trubbo.app; hi@trubbo.app)"}
# Namespace prefixes / portal pages that are not topics (en, sk, cs).
_NOT_TOPICS = (
    "Special:", "Špeciálne:", "Speciální:", "Main_Page", "Hlavná_stránka",
    "Hlavní_strana", "Wikipedia:", "Wikipédia:", "Wikipedie:", "wiki.phtml",
)


def top(client: httpx.Client, lang: str, year: int, month: int, limit: int) -> list[tuple[int, str]]:
    url = f"{_API}/top/{lang}.wikipedia/all-access/{year}/{month:02d}/all-days"
    resp = client.get(url)
    resp.raise_for_status()
    articles = resp.json()["items"][0]["articles"]
    rows = [
        (a["views"], a["article"].replace("_", " "))
        for a in articles
        if not a["article"].startswith(_NOT_TOPICS)
    ]
    return rows[:limit]


def views(client: httpx.Client, lang: str, year: int, month: int, title: str) -> int:
    last_day = calendar.monthrange(year, month)[1]
    article = quote(title.replace(" ", "_"), safe="")
    url = (
        f"{_API}/per-article/{lang}.wikipedia/all-access/user/{article}/monthly/"
        f"{year}{month:02d}0100/{year}{month:02d}{last_day}00"
    )
    resp = client.get(url, follow_redirects=True)
    if resp.status_code == 404:
        return 0
    resp.raise_for_status()
    return sum(item["views"] for item in resp.json().get("items", []))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=("top", "views"))
    parser.add_argument("titles", nargs="*", help="article titles (views mode)")
    parser.add_argument("--lang", required=True, help="wiki language code: en / sk / cs")
    parser.add_argument("--month", required=True, help="YYYY-MM (a finished month)")
    parser.add_argument("--limit", type=int, default=100, help="top mode: rows to print")
    args = parser.parse_intermixed_args()
    year, month = (int(part) for part in args.month.split("-"))

    with httpx.Client(headers=_HEADERS, timeout=30) as client:
        if args.mode == "top":
            rows = top(client, args.lang, year, month, args.limit)
        else:
            if not args.titles:
                parser.error("views mode needs at least one title")
            rows = [(views(client, args.lang, year, month, t), t) for t in args.titles]
    for count, title in sorted(rows, reverse=True):
        print(f"{count}\t{title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
