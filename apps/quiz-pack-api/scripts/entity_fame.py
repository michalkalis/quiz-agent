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
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import httpx  # noqa: E402

from app.sourcing.wiki_fame import HEADERS, top, views  # noqa: E402  (logic: #202)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mode", choices=("top", "views"))
    parser.add_argument("titles", nargs="*", help="article titles (views mode)")
    parser.add_argument("--lang", required=True, help="wiki language code: en / sk / cs")
    parser.add_argument("--month", required=True, help="YYYY-MM (a finished month)")
    parser.add_argument("--limit", type=int, default=100, help="top mode: rows to print")
    args = parser.parse_intermixed_args()
    year, month = (int(part) for part in args.month.split("-"))

    with httpx.Client(headers=HEADERS, timeout=30) as client:
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
