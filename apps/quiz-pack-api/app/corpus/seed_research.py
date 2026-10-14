"""Seed facts for the weekly fresh-entertainment run (#202 task 202.2).

One Claude call per language (Haiku 5.5 picks the seeds; founder 2026-10-14:
"Novinky hľadá Haiku") with the server-side ``web_search`` tool only does
what the #201 recipe's "Seeds" step did by hand (``docs/setup/fresh-entertainment-recipe.md``): collect ~36
candidate facts people in the player's country talked about, each with a
surprising angle and a source page. Deterministic filters then cut them to ~25:

1. **uncited** — the stated ``source_url`` is not a page web search really
   returned (search hit or text citation). Same integrity rule as
   ``app/sourcing/openai_web_search_source.py``; the shipped URL is the tool's.
2. **low_credibility** — ``classify_credibility`` says low, or the domain is a
   known tabloid / social site (Reddit is never a source, recipe rule).
3. **page_mismatch** — the source page, fetched without a model
   (``seed_page_check``), does not mention the subject.
4. **same_subject** — more than 2 seeds about one subject (founder: "Max. 2 na
   tému"; diacritics-insensitive, ``subject_cap``), applied before the fame cut.
5. **low_fame** — the bottom third by monthly Wikipedia views of the subject
   (``wiki_fame.views``); a famous subject is one a casual player can guess at.

Cost (founder decision 2026-10-14, after a dry run spent $6.17 en / $15.89 sk
on seeds alone; the third run still cost ~$3.1 per language on Opus, so seeds
moved to Haiku 5.5 at $0.10 / $0.50 per MTok for prompts up to 100k tokens,
$0.50 / $2.50 beyond — the larger tier is not modelled in ``llm_usage``, the
$10/1k searches fee dominates anyway): no ``web_fetch`` (every server-tool
iteration re-reads all earlier results, so fetched pages multiplied the input
tokens), searches capped
by ``FRESH_TOPUP_SEED_SEARCHES`` (default 8), and no further ``pause_turn``
resume once the call has cost ``FRESH_TOPUP_SEED_MAX_USD`` (default $1.00) —
the seeds then come from whatever text the call has produced. A seed call can
therefore overshoot that max by at most one segment.

Ideas come from the most-read Wikipedia articles (last 7 days + last finished
month) in the player's language. The result carries its own cost (tokens at
list price + $10/1k searches), which the job adds to the pipeline spend —
nothing here reports into the ``UsageRecorder``, so nothing is counted twice.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app import llm_usage
from app.corpus.fresh_brief import AUDIENCE, freshness_window
from app.corpus.seed_filters import (
    Seed,
    cite_filter,
    domestic_share,
    fame_cut,
    subject_cap,
)
from app.corpus.seed_page_check import FetchText, check_pages
from app.sourcing import wiki_fame
from app.sourcing.openai_web_search_source import _anthropic_text_and_urls

logger = logging.getLogger(__name__)

SEED_MODEL = "claude-haiku-5-5"
DEFAULT_MAX_SEARCHES = 8
DEFAULT_SEED_MAX_USD = 1.0
MAX_TOKENS = 32000
EFFORT = "high"
MAX_PAUSE_RESUMES = 4
TARGET_CANDIDATES = 36
SEARCH_FEE_CENTS = 1.0  # $10 per 1,000 web searches
IDEAS_LIMIT = 60


def seed_tools() -> list[dict]:
    """Web search only (no web_fetch: pages are checked in ``seed_page_check``)."""
    searches = int(os.getenv("FRESH_TOPUP_SEED_SEARCHES") or DEFAULT_MAX_SEARCHES)
    return [{"type": "web_search_20260209", "name": "web_search", "max_uses": searches}]


def seed_max_cents() -> float:
    return float(os.getenv("FRESH_TOPUP_SEED_MAX_USD") or DEFAULT_SEED_MAX_USD) * 100


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

A seed is one thing people talked about, one surprising angle a question can ask about, and a trusted source page that your web search returned and that states the fact.

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
[{{"subject": "<the famous thing>", "wiki_title": "<exact title of the subject's article on {wiki} Wikipedia, or null>", "scope": "domestic|world", "event_date": "<YYYY-MM-DD, or null if evergreen>", "fact": "<one checkable sentence>", "angle": "<the surprising detail a question would ask about>", "source_url": "<URL of a web search result that states the fact>"}}]"""


@dataclass
class SeedResult:
    seeds: list[Seed] = field(default_factory=list)
    candidates: int = 0
    dropped: dict[str, int] = field(default_factory=dict)
    domestic_share: float | None = None
    fame_checked: bool = False
    page_check: dict[str, int] = field(default_factory=dict)
    budget_stopped: bool = False
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
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
        tools=seed_tools(),
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
    reported = getattr(tools, "web_search_requests", 0) or 0
    # Haiku 5.5 reported 0 searches for a reply with two search blocks
    # (smoke test 2026-10-14), so the blocks are counted too; the larger wins.
    blocks = sum(
        1
        for b in getattr(response, "content", None) or []
        if getattr(b, "type", None) == "server_tool_use"
        and getattr(b, "name", None) == "web_search"
    )
    searches = max(reported, blocks)
    result.input_tokens += tokens_in
    result.output_tokens += tokens_out
    result.searches += searches
    token_cents = llm_usage.cost_cents_for(SEED_MODEL, tokens_in, tokens_out)
    if tokens_in > HAIKU_LONG_PROMPT_TOKENS:
        # Long prompts bill at 5x ($0.50/$2.50); the price table can't tell.
        token_cents *= 5
    result.cost_cents += token_cents + searches * SEARCH_FEE_CENTS


HAIKU_LONG_PROMPT_TOKENS = 100_000


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


async def research_seeds(
    lang: str,
    today: date,
    *,
    call: ModelCall | None = None,
    ideas: list[str] | None = None,
    fame_of: Callable[[str], int | None] | None = None,
    fetch_page: FetchText | None = None,
) -> SeedResult:
    """One research call (pause_turn resumed) → filtered seeds + own cost."""
    call = call or _default_call
    if ideas is None:
        ideas = await asyncio.to_thread(gather_ideas, lang, today)
    prompt = build_seed_prompt(lang, today, ideas)
    messages: list[dict] = [{"role": "user", "content": prompt}]
    result = SeedResult()
    response = None
    # A resumed response carries only its own new blocks, so every segment's
    # blocks are kept: resent as the assistant prefix and searched for cited URLs.
    blocks: list = []
    max_cents = seed_max_cents()
    try:
        for _ in range(1 + MAX_PAUSE_RESUMES):
            response = await call(messages)
            _add_usage(result, response)
            blocks.extend(response.content)
            if response.stop_reason != "pause_turn":
                break
            if result.cost_cents >= max_cents:
                result.budget_stopped = True
                logger.warning(
                    "seed research %s: $%.2f spent, not resuming",
                    lang,
                    result.cost_cents / 100,
                )
                break
            messages = [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": list(blocks)},
            ]
    except Exception as exc:  # API error: no seeds, spend so far still counted
        logger.exception("seed research %s failed", lang)
        result.error = f"seed call failed: {type(exc).__name__}: {exc}"
        return result
    stop = getattr(response, "stop_reason", None)
    if not result.budget_stopped and stop not in ("end_turn", "stop_sequence"):
        result.error = f"seed call ended {stop!r}"
        return result

    # Budget stop: the reply is unfinished, so use any text of every segment.
    all_text, urls = _anthropic_text_and_urls(blocks)
    text = (
        all_text
        if result.budget_stopped
        else _anthropic_text_and_urls(response.content)[0]
    )
    items = _parse_seed_array(text)
    if not items and not result.budget_stopped and result.cost_cents < max_cents:
        # One nudge: the reply had prose but no array (sk, 2026-10-14 dry run).
        try:
            response = await call(
                [
                    {"role": "user", "content": prompt},
                    {"role": "assistant", "content": list(blocks)},
                    {"role": "user", "content": JSON_NUDGE},
                ]
            )
        except Exception as exc:  # spend so far still counted
            logger.exception("seed research %s nudge failed", lang)
            result.error = f"seed nudge failed: {type(exc).__name__}: {exc}"
            return result
        _add_usage(result, response)
        blocks.extend(response.content)
        text, urls = (
            _anthropic_text_and_urls(response.content)[0],
            _anthropic_text_and_urls(blocks)[1],
        )
        items = _parse_seed_array(text)
    result.candidates = len(items)
    if not items and not result.budget_stopped:
        result.error = f"seed reply had no JSON array: {text[:200]!r}"
        return result
    if not items and result.budget_stopped:
        result.error = (
            f"seed budget ${max_cents / 100:.2f} reached before the call replied"
        )
        return result
    seeds, dropped = cite_filter(items, urls)
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
