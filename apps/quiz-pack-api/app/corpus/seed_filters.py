"""Deterministic seed filters of the weekly fresh run (#202 task 202.2).

Split out of ``seed_research`` (file-size rule): the ``Seed`` row and the
uncited / low-credibility / bottom-third-fame cut, all pure so tests pin them
without a model call. See ``seed_research`` for the why of each filter.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from app.sourcing.openai_web_search_source import _cited_url
from app.sourcing.web_search_source import _extract_domain, classify_credibility

MAX_SEEDS = 25

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


def filter_seeds(
    items: list, trusted_urls: list[str], fame_of: Callable[[str], int | None]
) -> tuple[list[Seed], dict[str, int], bool]:
    """Apply the uncited / low-credibility / bottom-third-fame filters.

    ``fame_of(wiki_title)`` returns monthly views or ``None`` when unknown; if
    no subject has a known value (Wikimedia down) the fame cut is skipped and
    the third return value is ``False``, so the summary shows it.
    """
    dropped: dict[str, int] = {}

    def _drop(reason: str, n: int = 1) -> None:
        dropped[reason] = dropped.get(reason, 0) + n

    kept: list[Seed] = []
    for item in items:
        if (
            not isinstance(item, dict)
            or not item.get("subject")
            or not item.get("fact")
        ):
            _drop("malformed")
            continue
        url = _cited_url(item.get("source_url"), trusted_urls)
        if url is None:
            _drop("uncited")
            continue
        if _is_low_credibility(url):
            _drop("low_credibility")
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

    for seed in kept:
        seed.views = fame_of(seed.wiki_title) if seed.wiki_title else 0
    fame_checked = any(seed.views for seed in kept)
    if fame_checked:
        kept.sort(key=lambda s: s.views or 0, reverse=True)
        cut = len(kept) // 3
        if cut:
            kept = kept[:-cut]
            _drop("low_fame", cut)
    if len(kept) > MAX_SEEDS:
        _drop("over_cap", len(kept) - MAX_SEEDS)
        kept = kept[:MAX_SEEDS]
    return kept, dropped, fame_checked


def domestic_share(lang: str, seeds: list[Seed]) -> float | None:
    if lang == "en" or not seeds:
        return None
    return round(sum(s.scope == "domestic" for s in seeds) / len(seeds), 2)
