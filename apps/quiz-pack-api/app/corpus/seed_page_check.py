"""Keyword page check of the weekly fresh seeds (#202, founder 2026-10-14).

The seed call no longer reads pages (``web_fetch`` made its context, and so its
cost, grow with every page). Instead each seed's ``source_url`` is fetched here
with plain httpx and the seed is kept only when the page mentions its subject.
No model call: the founder chose "via keywords", and the later web fact-check
of every generated question verifies the facts themselves.

Rule (``page_mentions``): the page text and the names are folded (casefold,
diacritics dropped, punctuation to spaces: "Šimon Pleško" == "Simon Plesko").
A name is the subject or the wiki title without a "(film)"-style suffix. Its
tokens are the words of 3+ letters minus a few generic words ("the", "season",
"film" ...), or all words when nothing is left ("U2"). A token is on the page
when a page word equals it or, for tokens of 5+ letters, starts with the token
minus its last two letters — Slovak / Czech decline names ("Pleškovi").
A name matches when at least two thirds of its tokens (rounded up, so both of
a two-word name) are on the page; the seed passes when either name matches.

Fetch failure, non-200, non-HTML or a near-empty page (JS app, consent wall)
→ the seed is kept but counted ``page_unchecked``: an unreadable page is no
evidence against the seed.
"""

from __future__ import annotations

import asyncio
import html
import logging
import math
import re
from collections.abc import Awaitable, Callable

import httpx

from app.corpus.seed_filters import Seed, seed_names
from app.translation_verification.normalize import fold

logger = logging.getLogger(__name__)

TIMEOUT_S = 10.0
MAX_BYTES = 800_000
CONCURRENCY = 8
MIN_TEXT_CHARS = 300
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/129.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5",
    "Accept-Language": "en,sk;q=0.9,cs;q=0.9",
}
GENERIC_WORDS = frozenset(
    {"the", "and", "season", "series", "film", "movie", "song", "album", "show"}
)

_DROP_BLOCKS = re.compile(
    r"<(script|style|noscript|template)\b.*?</\1\s*>|<!--.*?-->",
    re.IGNORECASE | re.DOTALL,
)
_TAG = re.compile(r"<[^>]+>")

FetchText = Callable[[str], Awaitable[str | None]]


def html_to_text(raw: str) -> str:
    return html.unescape(_TAG.sub(" ", _DROP_BLOCKS.sub(" ", raw)))


def _name_tokens(name: str) -> list[str]:
    words = fold(name).split()
    tokens = [w for w in words if len(w) >= 3 and w not in GENERIC_WORDS]
    return tokens or words


def _on_page(token: str, words: set[str]) -> bool:
    if token in words:
        return True
    if len(token) < 5:
        return False
    stem = token[:-2]
    return any(w.startswith(stem) for w in words)


def page_mentions(text: str, names: list[str]) -> bool:
    words = set(fold(text).split())
    for name in names:
        tokens = _name_tokens(name)
        if not tokens:
            continue
        found = sum(_on_page(t, words) for t in tokens)
        if found >= math.ceil(len(tokens) * 2 / 3):
            return True
    return False


async def fetch_page_text(client: httpx.AsyncClient, url: str) -> str | None:
    """Visible text of the first ``MAX_BYTES`` of an HTML page, else ``None``."""
    try:
        async with client.stream("GET", url) as resp:
            if resp.status_code != 200:
                return None
            if "html" not in resp.headers.get("content-type", "").lower():
                return None
            buf = bytearray()
            async for chunk in resp.aiter_bytes():
                buf += chunk
                if len(buf) >= MAX_BYTES:
                    break
            encoding = resp.encoding or "utf-8"
        return html_to_text(bytes(buf[:MAX_BYTES]).decode(encoding, errors="replace"))
    except Exception as exc:  # noqa: BLE001 — any failure = unchecked, not dropped
        logger.info("seed page %s unreadable: %s", url, exc)
        return None


async def check_pages(
    seeds: list[Seed], fetch: FetchText | None = None
) -> tuple[list[Seed], dict[str, int]]:
    """Keep seeds whose page mentions the subject (or is unreadable) + counts."""
    counts = {"page_ok": 0, "page_mismatch": 0, "page_unchecked": 0}
    if not seeds:
        return [], counts
    sem = asyncio.Semaphore(CONCURRENCY)

    async def _all(fetch_one: FetchText) -> list[str | None]:
        async def _one(url: str) -> str | None:
            async with sem:
                return await fetch_one(url)

        return await asyncio.gather(*(_one(s.source_url) for s in seeds))

    if fetch is None:
        async with httpx.AsyncClient(
            timeout=TIMEOUT_S, follow_redirects=True, headers=HEADERS
        ) as client:
            texts = await _all(lambda url: fetch_page_text(client, url))
    else:
        texts = await _all(fetch)

    kept: list[Seed] = []
    for seed, text in zip(seeds, texts, strict=True):
        if text is None or len(text.strip()) < MIN_TEXT_CHARS:
            counts["page_unchecked"] += 1
            kept.append(seed)
        elif page_mentions(text, seed_names(seed)):
            counts["page_ok"] += 1
            kept.append(seed)
        else:
            counts["page_mismatch"] += 1
            logger.info(
                "seed %r dropped: %s does not mention it", seed.subject, seed.source_url
            )
    return kept, counts
