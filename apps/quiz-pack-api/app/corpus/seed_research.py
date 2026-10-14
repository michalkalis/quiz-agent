"""Seed facts for the weekly fresh-entertainment run (#202 task 202.2).

Two steps per language (founder 2026-10-14: "čítanie celých stránok môže robiť
Haiku" — the cheap model reads, the strong one decides):

1. **Gather** (``seed_gather``): Haiku 5.5 with ``web_search`` only writes a
   news digest; every search hit is harvested into it too.
2. **Pick** (here): Opus 5.5, no tools, effort medium, reads the digest and
   picks ~36 candidate seeds by the #201 recipe's "Seeds" rules
   (``docs/setup/fresh-entertainment-recipe.md``): a subject people in the
   player's country talked about, a surprising angle, a digest URL as source.

Deterministic filters then cut them to ~25:

1. **uncited** — the stated ``source_url`` is not a URL of the merged digest,
   i.e. not a page web search returned (same integrity rule as
   ``app/sourcing/openai_web_search_source.py``; the shipped URL is the tool's).
2. **low_credibility** — ``classify_credibility`` says low, or the domain is a
   known tabloid / social site (Reddit is never a source, recipe rule).
3. **page_mismatch** — the source page, fetched without a model
   (``seed_page_check``), does not mention the subject.
4. **same_subject** — more than 2 seeds about one subject (founder: "Max. 2 na
   tému"; diacritics-insensitive, ``subject_cap``), applied before the fame cut.
5. **low_fame** — the bottom third by monthly Wikipedia views of the subject
   (``wiki_fame.views``); a famous subject is one a casual player can guess at.

Cost: the gather's own (Haiku tokens + search fees, stopped at
``FRESH_TOPUP_SEED_MAX_USD``) plus the pick's Opus tokens. The pick input is
bounded (digest capped at ~120 lines / ~15k tokens), so it needs no loop; one
pick plus one JSON nudge at ``PICK_MAX_TOKENS`` stays under
``PICK_WORST_USD``. The result carries its own cost, which the job adds to the
pipeline spend — nothing here reports into the ``UsageRecorder``.

Ideas come from the most-read Wikipedia articles (last 7 days + last finished
month) in the player's language; both steps see them.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app import llm_usage
from app.corpus import seed_gather
from app.corpus.fresh_brief import AUDIENCE, freshness_window
from app.corpus.seed_filters import (
    Seed,
    cite_filter,
    domestic_share,
    fame_cut,
    subject_cap,
)
from app.corpus.seed_gather import WIKI_LANGUAGE, ModelCall
from app.corpus.seed_page_check import FetchText, check_pages
from app.sourcing import wiki_fame
from app.sourcing.openai_web_search_source import _anthropic_text_and_urls

logger = logging.getLogger(__name__)

PICK_MODEL = "claude-opus-5-5"
PICK_EFFORT = "medium"
PICK_MAX_TOKENS = 16000
# One pick (~20k in) + one nudge (~36k in), both at PICK_MAX_TOKENS out: $0.86.
PICK_WORST_USD = 1.0
DEFAULT_SEED_MAX_USD = seed_gather.DEFAULT_SEED_MAX_USD
TARGET_CANDIDATES = 36
IDEAS_LIMIT = 60

_SCENE = {
    "en": (
        "Every seed is global entertainment (film, TV and streaming, music, video "
        "games, viral pop-culture moments) that a casual fan anywhere in the world, "
        'not only in the US, would recognise. Use scope "world".'
    ),
    "sk": (
        'About 7 in 10 seeds come from the Slovak scene (scope "domestic"): Slovak '
        "celebrities, reality and TV shows, domestic hits and moments people in "
        "Slovakia talked about. The rest are world mega-hits well known in Slovakia "
        '(scope "world"). Skip the Czech scene unless it is genuinely shared.'
    ),
    "cs": (
        'About 7 in 10 seeds come from the Czech scene (scope "domestic"): Czech '
        "celebrities, reality and TV shows, domestic hits and moments people in "
        "Czechia talked about. The rest are world mega-hits well known in Czechia "
        '(scope "world"). Skip the Slovak scene unless it is genuinely shared.'
    ),
}

_PROMPT = """Today is {today}. From the news digest below, pick {count} seed facts for a voice trivia quiz played by {audience}.

A seed is one thing people talked about, one surprising angle a question can ask about, and the digest URL of the page that states the fact.

What to pick:
- Fame first: pick a subject an ordinary adult who follows film, TV, music and celebrities only loosely has heard of, then find the surprising angle.
- {scene}
- Freshness: most seeds are about things that happened or came out {window}; the rest may be surprising facts about mega-famous films, songs, shows or games.
- Skip award categories ("who won X"), directors, producers, puppeteers and other crew (famous singers and songwriters are fine), and topics only US audiences or fans would know.
- Skip current politics and current wars or armed conflicts (including countries involved in one); historical events and dark themes inside films, series or games are fine. No gossip.
- At most 2 seeds about the same subject.
- Sources: Wikipedia first, then domain authorities, then reputable media. Never tabloids, aggregators, social media or Reddit.
- Every source_url MUST be copied exactly from one digest line, and that line must support the fact. Lines without a fact sentence are bare search results: use one only when its title states the fact. Never invent a URL.

Ideas: the most-read {wiki} Wikipedia articles of the last week and the last month (many are politics, crime or sport; ignore those):
{ideas}

Digest (headline | date | URL | fact):
{digest}

Reply with ONLY a JSON array, no prose and no code fence, one object per seed:
[{{"subject": "<the famous thing>", "wiki_title": "<exact title of the subject's article on {wiki} Wikipedia, or null>", "scope": "domestic|world", "event_date": "<YYYY-MM-DD, or null if evergreen>", "fact": "<one checkable sentence>", "angle": "<the surprising detail a question would ask about>", "source_url": "<URL copied from the digest line that states the fact>"}}]"""


@dataclass
class SeedResult:
    seeds: list[Seed] = field(default_factory=list)
    candidates: int = 0
    digest_lines: int = 0
    harvested: int = 0
    dropped: dict[str, int] = field(default_factory=dict)
    domestic_share: float | None = None
    fame_checked: bool = False
    page_check: dict[str, int] = field(default_factory=dict)
    budget_stopped: bool = False
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
    gather_cents: float = 0.0
    pick_cents: float = 0.0
    cost_cents: float = 0.0
    error: str | None = None


def build_pick_prompt(
    lang: str, today: date, ideas: list[str], digest: list[str]
) -> str:
    return _PROMPT.format(
        today=today.isoformat(),
        count=TARGET_CANDIDATES,
        audience=AUDIENCE[lang],
        scene=_SCENE[lang],
        window=freshness_window(today),
        wiki=WIKI_LANGUAGE[lang],
        ideas="\n".join(ideas) or "- (none available today)",
        digest="\n".join(digest),
    )


def gather_ideas(lang: str, today: date, client=None) -> list[str]:
    """Most-read articles: last 7 days (daily) + last finished month, merged."""
    client = client or wiki_fame.make_client()
    totals: dict[str, int] = {}

    def _merge(rows) -> None:
        for views, title in rows:
            totals[title] = totals.get(title, 0) + views

    for back in range(1, 8):
        try:
            _merge(wiki_fame.top_daily(client, lang, today - timedelta(days=back)))
        except Exception as exc:  # noqa: BLE001 — one missing day must not lose the rest
            logger.warning(
                "wiki top %s %s failed: %s", lang, today - timedelta(days=back), exc
            )
    last_month = today.replace(day=1) - timedelta(days=1)
    try:
        _merge(wiki_fame.top(client, lang, last_month.year, last_month.month, 100))
    except Exception as exc:  # noqa: BLE001 — ideas are optional input
        logger.warning("wiki monthly top %s failed: %s", lang, exc)
    ranked = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)[:IDEAS_LIMIT]
    return [f"- {title} ({views} views)" for title, views in ranked]


async def _pick_call(messages: list[dict]) -> Any:
    """Opus 5.5 without tools: the digest is all it reads."""
    client = llm_factory.anthropic_client(timeout=900.0)
    async with client.messages.stream(
        model=PICK_MODEL,
        max_tokens=PICK_MAX_TOKENS,
        output_config={"effort": PICK_EFFORT},
        messages=messages,
    ) as stream:
        return await stream.get_final_message()


def _add_pick_usage(result: SeedResult, response: Any) -> None:
    usage = getattr(response, "usage", None)
    if usage is None:
        return
    tokens_in, tokens_out = usage.input_tokens or 0, usage.output_tokens or 0
    cents = llm_usage.cost_cents_for(PICK_MODEL, tokens_in, tokens_out)
    result.input_tokens += tokens_in
    result.output_tokens += tokens_out
    result.pick_cents += cents
    result.cost_cents += cents


JSON_NUDGE = (
    "Reply now with ONLY the JSON array of seed objects described above: "
    "no prose, no code fence."
)


def _parse_seed_array(text: str) -> list:
    """First JSON array of objects anywhere in ``text``, or ``[]``.

    Prose before the array may itself contain ``[`` (a citation mark, a
    bracketed aside), so every ``[`` is tried, not only the first one.
    """
    decoder = json.JSONDecoder()
    start = text.find("[")
    while start != -1:
        try:
            data, _ = decoder.raw_decode(text[start:])
        except ValueError:
            data = None
        if isinstance(data, list) and any(isinstance(x, dict) for x in data):
            return [x for x in data if isinstance(x, dict)]
        start = text.find("[", start + 1)
    return []


async def _pick(result: SeedResult, prompt: str, call: ModelCall) -> list | None:
    """Pick call + one JSON nudge → items, or ``None`` with ``result.error`` set."""
    messages: list[dict] = [{"role": "user", "content": prompt}]
    try:
        response = await call(messages)
        _add_pick_usage(result, response)
        if response.stop_reason not in ("end_turn", "stop_sequence"):
            result.error = f"seed pick ended {response.stop_reason!r}"
            return None
        text = _anthropic_text_and_urls(response.content)[0]
        items = _parse_seed_array(text)
        if not items:
            # One nudge: a reply with prose but no array (sk, 2026-10-14 dry run).
            response = await call(
                messages
                + [
                    {"role": "assistant", "content": list(response.content)},
                    {"role": "user", "content": JSON_NUDGE},
                ]
            )
            _add_pick_usage(result, response)
            text = _anthropic_text_and_urls(response.content)[0]
            items = _parse_seed_array(text)
    except Exception as exc:  # API error: spend so far still counted
        logger.exception("seed pick failed")
        result.error = f"seed pick failed: {type(exc).__name__}: {exc}"
        return None
    if not items:
        result.error = f"seed reply had no JSON array: {text[:200]!r}"
        return None
    return items


async def research_seeds(
    lang: str,
    today: date,
    *,
    gather_call: ModelCall | None = None,
    pick_call: ModelCall | None = None,
    ideas: list[str] | None = None,
    fame_of: Callable[[str], int | None] | None = None,
    fetch_page: FetchText | None = None,
) -> SeedResult:
    """Gather (Haiku) → pick (Opus) → filtered seeds + own cost."""
    if ideas is None:
        ideas = await asyncio.to_thread(gather_ideas, lang, today)
    g = await seed_gather.gather_digest(lang, today, ideas, call=gather_call)
    result = SeedResult(
        digest_lines=g.digest_lines,
        harvested=g.harvested,
        budget_stopped=g.budget_stopped,
        input_tokens=g.input_tokens,
        output_tokens=g.output_tokens,
        searches=g.searches,
        gather_cents=g.cost_cents,
        cost_cents=g.cost_cents,
    )
    if g.unsourced:
        result.dropped["digest_unsourced"] = g.unsourced
    if g.error:
        result.error = g.error
        return result
    prompt = build_pick_prompt(lang, today, ideas, g.digest)
    items = await _pick(result, prompt, pick_call or _pick_call)
    if items is None:
        return result
    result.candidates = len(items)
    seeds, dropped = cite_filter(items, g.urls)
    dropped.update(result.dropped)
    seeds, result.page_check = await check_pages(seeds, fetch_page)
    if result.page_check["page_mismatch"]:
        dropped["page_mismatch"] = result.page_check["page_mismatch"]
    seeds = subject_cap(seeds, dropped)
    if fame_of is None:
        fame_of = _wiki_fame_lookup(lang, today)
    seeds, fame_checked = await asyncio.to_thread(fame_cut, seeds, fame_of, dropped)
    result.seeds, result.dropped, result.fame_checked = seeds, dropped, fame_checked
    result.domestic_share = domestic_share(lang, seeds)
    return result


def _wiki_fame_lookup(lang: str, today: date) -> Callable[[str], int | None]:
    """Monthly views of the last finished month; ``None`` on any API error."""
    client = wiki_fame.make_client()
    month = today.replace(day=1) - timedelta(days=1)

    def _views(title: str) -> int | None:
        try:
            return wiki_fame.views(client, lang, month.year, month.month, title)
        except Exception as exc:  # noqa: BLE001 — unknown fame, not a failure
            logger.warning("wiki views %s %r failed: %s", lang, title, exc)
            return None

    return _views
