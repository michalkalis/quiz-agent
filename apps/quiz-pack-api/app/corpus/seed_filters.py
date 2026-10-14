"""Deterministic seed filters of the weekly fresh run (#202 task 202.2).

Split out of ``seed_research`` (file-size rule): the ``Seed`` row and the
uncited / low-credibility cut (``cite_filter``) and the bottom-third-fame cut
(``fame_cut``), all pure so tests pin them without a model call. The keyword
page check (``seed_page_check``) runs between the two. See ``seed_research``
for the why of each filter.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass

from app.sourcing.openai_web_search_source import _cited_url
from app.sourcing.web_search_source import _extract_domain, classify_credibility
from app.translation_verification.normalize import fold

MAX_SEEDS = 25
MAX_PER_SUBJECT = 2
WIKI_SUFFIX = re.compile(r"\s*\([^)]*\)\s*$")  # "Barbie (film)" -> "Barbie"

# Tabloid / social domains classify_credibility does not know (sk/cs press).
TABLOID_DOMAINS = frozenset(
    {
        "reddit.com",
        "facebook.com",
        "instagram.com",
        "tiktok.com",
        "x.com",
        "twitter.com",
        "cas.sk",
        "novycas.sk",
        "topky.sk",
        "pluska.sk",
        "blesk.cz",
        "ahaonline.cz",
        "super.cz",
        "expres.cz",
        "extra.cz",
        "dailymail.co.uk",
        "thesun.co.uk",
        "mirror.co.uk",
        "tmz.com",
        "pagesix.com",
    }
)


@dataclass
class Seed:
    subject: str
    fact: str
    angle: str
    source_url: str
    scope: str = "world"
    wiki_title: str | None = None
    event_date: str | None = None
    views: int | None = None


def _is_low_credibility(url: str) -> bool:
    domain = _extract_domain(url).lower()
    domain = domain.removeprefix("www.")
    tabloid = any(domain == d or domain.endswith("." + d) for d in TABLOID_DOMAINS)
    return tabloid or classify_credibility(url) == "low"


def cite_filter(
    items: list, trusted_urls: list[str]
) -> tuple[list[Seed], dict[str, int]]:
    """Drop malformed, uncited and low-credibility items; the URL kept is the tool's."""
    dropped: dict[str, int] = {}
    kept: list[Seed] = []
    for item in items:
        if (
            not isinstance(item, dict)
            or not item.get("subject")
            or not item.get("fact")
        ):
            _bump(dropped, "malformed")
            continue
        url = _cited_url(item.get("source_url"), trusted_urls)
        if url is None:
            _bump(dropped, "uncited")
            continue
        if _is_low_credibility(url):
            _bump(dropped, "low_credibility")
            continue
        kept.append(
            Seed(
                subject=str(item["subject"]).strip(),
                fact=str(item["fact"]).strip(),
                angle=str(item.get("angle") or "").strip(),
                source_url=url,
                scope="domestic" if item.get("scope") == "domestic" else "world",
                wiki_title=(str(item["wiki_title"]).strip() or None)
                if item.get("wiki_title")
                else None,
                event_date=str(item["event_date"]) if item.get("event_date") else None,
            )
        )
    return kept, dropped


def seed_names(seed: Seed) -> list[str]:
    """Subject and wiki title without a "(film)"-style suffix."""
    names = [seed.subject]
    if seed.wiki_title:
        names.append(WIKI_SUFFIX.sub("", seed.wiki_title))
    return names


def _subject_keys(seed: Seed) -> set[str]:
    """Folded names (same ``fold`` as ``seed_page_check``)."""
    return {key for key in (fold(n) for n in seed_names(seed)) if key}


def subject_cap(kept: list[Seed], dropped: dict[str, int]) -> list[Seed]:
    """At most ``MAX_PER_SUBJECT`` seeds per subject (founder: "Max. 2 na tému").

    Why: the 2026-10-14 sk dry run had 3 of 5 questions about one singer — the
    seed list is where one name can multiply. Seeds are compared by folded
    subject and wiki title, so "Šimon Pleško" and "Simon Plesko" (or the same
    article under another subject label) are one subject. Earlier seeds win;
    runs before ``fame_cut`` so the kept ones are the ones fame ranks.
    """
    counts: dict[str, int] = {}
    out: list[Seed] = []
    for seed in kept:
        keys = _subject_keys(seed)
        if any(counts.get(k, 0) >= MAX_PER_SUBJECT for k in keys):
            _bump(dropped, "same_subject")
            continue
        for k in keys:
            counts[k] = counts.get(k, 0) + 1
        out.append(seed)
    return out


def fame_cut(
    kept: list[Seed], fame_of: Callable[[str], int | None], dropped: dict[str, int]
) -> tuple[list[Seed], bool]:
    """Drop the bottom third by fame, then cap at ``MAX_SEEDS``.

    ``fame_of(wiki_title)`` returns monthly views or ``None`` when unknown; if
    no subject has a known value (Wikimedia down) the fame cut is skipped and
    the second return value is ``False``, so the summary shows it. ``dropped``
    is updated in place.
    """
    for seed in kept:
        seed.views = fame_of(seed.wiki_title) if seed.wiki_title else 0
    fame_checked = any(seed.views for seed in kept)
    if fame_checked:
        kept = sorted(kept, key=lambda s: s.views or 0, reverse=True)
        cut = len(kept) // 3
        if cut:
            kept = kept[:-cut]
            _bump(dropped, "low_fame", cut)
    if len(kept) > MAX_SEEDS:
        _bump(dropped, "over_cap", len(kept) - MAX_SEEDS)
        kept = kept[:MAX_SEEDS]
    return kept, fame_checked


def filter_seeds(
    items: list, trusted_urls: list[str], fame_of: Callable[[str], int | None]
) -> tuple[list[Seed], dict[str, int], bool]:
    """``cite_filter`` then ``fame_cut`` (no page check)."""
    kept, dropped = cite_filter(items, trusted_urls)
    kept, fame_checked = fame_cut(kept, fame_of, dropped)
    return kept, dropped, fame_checked


def _bump(counts: dict[str, int], reason: str, n: int = 1) -> None:
    counts[reason] = counts.get(reason, 0) + n


def domestic_share(lang: str, seeds: list[Seed]) -> float | None:
    if lang == "en" or not seeds:
        return None
    return round(sum(s.scope == "domestic" for s in seeds) / len(seeds), 2)
