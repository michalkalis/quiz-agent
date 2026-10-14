"""Seed facts for the weekly fresh-entertainment run (#202 task 202.2).

One Claude call per language with the server-side ``web_search`` and
``web_fetch`` tools does what the #201 recipe's "Seeds" step did by hand
(``docs/setup/fresh-entertainment-recipe.md``): collect ~36 candidate facts
people in the player's country talked about, each with a surprising angle and
a source page. Deterministic filters then cut them to ~25 seeds:

1. **uncited** — the stated ``source_url`` is not a page the tools really
   returned (search hit, fetched page or text citation). Same integrity rule as
   ``app/sourcing/openai_web_search_source.py``; the shipped URL is the tool's.
2. **low_credibility** — ``classify_credibility`` says low, or the domain is a
   known tabloid / social site (Reddit is never a source, recipe rule).
3. **low_fame** — the bottom third by monthly Wikipedia views of the subject
   (``wiki_fame.views``); a famous subject is one a casual player can guess at.

Ideas come from the most-read Wikipedia articles (last 7 days + last finished
month) in the player's language. The result carries its own cost (tokens at
list price + $10/1k searches; fetch is not metered), which the job adds to the
pipeline spend — nothing here reports into the ``UsageRecorder``, so nothing is
counted twice.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app import llm_usage
from app.corpus.fresh_brief import AUDIENCE, freshness_window
from app.corpus.seed_filters import Seed, domestic_share, filter_seeds
from app.sourcing import wiki_fame
from app.sourcing.openai_web_search_source import (
    _anthropic_text_and_urls,
    _parse_fact_array,
)

logger = logging.getLogger(__name__)

SEED_MODEL = "claude-opus-5-5"
MAX_SEARCHES = 20
MAX_FETCHES = 15
MAX_FETCH_CONTENT_TOKENS = 6000
MAX_TOKENS = 32000
EFFORT = "high"
MAX_PAUSE_RESUMES = 4
TARGET_CANDIDATES = 36
SEARCH_FEE_CENTS = 1.0  # $10 per 1,000 web searches; web fetch has no fee
IDEAS_LIMIT = 60

TOOLS = [
    {"type": "web_search_20260209", "name": "web_search", "max_uses": MAX_SEARCHES},
    {
        "type": "web_fetch_20260209",
        "name": "web_fetch",
        "max_uses": MAX_FETCHES,
        "max_content_tokens": MAX_FETCH_CONTENT_TOKENS,
    },
]

WIKI_LANGUAGE = {"en": "English", "sk": "Slovak", "cs": "Czech"}
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

_PROMPT = """Today is {today}. Research {count} seed facts for a voice trivia quiz played by {audience}.

A seed is one thing people talked about, one surprising angle a question can ask about, and a trusted source page that you actually opened with web search or web fetch and that states the fact.

What to pick:
- Fame first: pick a subject an ordinary adult who follows film, TV, music and celebrities only loosely has heard of, then find the surprising angle.
- {scene}
- Freshness: most seeds are about things that happened or came out {window}; the rest may be surprising facts about mega-famous films, songs, shows or games.
- Skip award categories ("who won X"), directors, producers, puppeteers and other crew (famous singers and songwriters are fine), and topics only US audiences or fans would know.
- Skip current politics and current wars or armed conflicts (including countries involved in one); historical events and dark themes inside films, series or games are fine. No gossip.
- Sources: Wikipedia first, then domain authorities, then reputable media. Never tabloids, aggregators, social media or Reddit. Reddit and forums may give you ideas, never a fact or a source.

Ideas: the most-read {wiki} Wikipedia articles of the last week and the last month (many are politics, crime or sport; ignore those):
{ideas}

Reply with ONLY a JSON array, no prose and no code fence, one object per seed:
[{{"subject": "<the famous thing>", "wiki_title": "<exact title of the subject's article on {wiki} Wikipedia, or null>", "scope": "domestic|world", "event_date": "<YYYY-MM-DD, or null if evergreen>", "fact": "<one checkable sentence>", "angle": "<the surprising detail a question would ask about>", "source_url": "<URL of the page you opened that states the fact>"}}]"""


@dataclass
class SeedResult:
    seeds: list[Seed] = field(default_factory=list)
    candidates: int = 0
    dropped: dict[str, int] = field(default_factory=dict)
    domestic_share: float | None = None
    fame_checked: bool = False
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
    fetches: int = 0
    cost_cents: float = 0.0
    error: str | None = None


ModelCall = Callable[[list[dict]], Awaitable[Any]]


def build_seed_prompt(lang: str, today: date, ideas: list[str]) -> str:
    return _PROMPT.format(
        today=today.isoformat(),
        count=TARGET_CANDIDATES,
        audience=AUDIENCE[lang],
        scene=_SCENE[lang],
        window=freshness_window(today),
        wiki=WIKI_LANGUAGE[lang],
        ideas="\n".join(ideas) or "- (none available today)",
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


async def _default_call(messages: list[dict]) -> Any:
    client = llm_factory.anthropic_client(timeout=900.0)
    async with client.messages.stream(
        model=SEED_MODEL,
        max_tokens=MAX_TOKENS,
        tools=TOOLS,
        output_config={"effort": EFFORT},
        messages=messages,
    ) as stream:
        return await stream.get_final_message()


def _add_usage(result: SeedResult, response: Any) -> None:
    usage = getattr(response, "usage", None)
    if usage is None:
        return
    tokens_in, tokens_out = usage.input_tokens or 0, usage.output_tokens or 0
    tools = getattr(usage, "server_tool_use", None)
    searches = getattr(tools, "web_search_requests", 0) or 0
    result.input_tokens += tokens_in
    result.output_tokens += tokens_out
    result.searches += searches
    result.fetches += getattr(tools, "web_fetch_requests", 0) or 0
    result.cost_cents += (
        llm_usage.cost_cents_for(SEED_MODEL, tokens_in, tokens_out)
        + searches * SEARCH_FEE_CENTS
    )


async def research_seeds(
    lang: str,
    today: date,
    *,
    call: ModelCall | None = None,
    ideas: list[str] | None = None,
    fame_of: Callable[[str], int | None] | None = None,
) -> SeedResult:
    """One research call (pause_turn resumed) → filtered seeds + own cost."""
    call = call or _default_call
    if ideas is None:
        ideas = await asyncio.to_thread(gather_ideas, lang, today)
    prompt = build_seed_prompt(lang, today, ideas)
    messages: list[dict] = [{"role": "user", "content": prompt}]
    result = SeedResult()
    response = None
    try:
        for _ in range(1 + MAX_PAUSE_RESUMES):
            response = await call(messages)
            _add_usage(result, response)
            if response.stop_reason != "pause_turn":
                break
            messages = [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": response.content},
            ]
    except Exception as exc:  # API error: no seeds, spend so far still counted
        logger.exception("seed research %s failed", lang)
        result.error = f"seed call failed: {type(exc).__name__}: {exc}"
        return result
    if response is None or response.stop_reason not in ("end_turn", "stop_sequence"):
        result.error = f"seed call ended {getattr(response, 'stop_reason', None)!r}"
        return result

    text, urls = _anthropic_text_and_urls(response.content)
    items = _parse_fact_array(text)
    result.candidates = len(items)
    if fame_of is None:
        fame_of = _wiki_fame_lookup(lang, today)
    seeds, dropped, fame_checked = await asyncio.to_thread(
        filter_seeds, items, urls, fame_of
    )
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
