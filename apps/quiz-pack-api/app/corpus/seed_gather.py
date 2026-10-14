"""Step 1 of the fresh seeds (#202): Haiku 5.5 gathers a news digest.

Founder 2026-10-14: "čítanie celých stránok môže robiť Haiku" — the cheap model
reads, the strong one decides. Measured that day (5 questions per language):
Opus 5.5 searching itself picked good seeds but cost $0.8–3.2 per language
(every server-tool iteration re-reads all earlier results); Haiku 5.5 doing
the whole job cost $0.18–0.24 but returned 3–17 candidates, so the generator
filled up with evergreen clichés. So Haiku now only gathers: it runs varied
``web_search`` calls (no ``web_fetch``) and writes a digest, one line per
news item, without judging taste. ``seed_research`` then hands the digest to
Opus, which picks the seeds without tools.

The digest never comes back near-empty: every ``web_search_tool_result`` entry
is harvested deterministically (title, URL, page age) and appended after the
model's lines when its URL is not already there. A model line whose URL no
search returned is dropped (``unsourced``) and every kept URL is rewritten to
the tool's, so "URL is in the digest" still means "web search returned it".

Cost: Haiku list price ($0.10 / $0.50 per MTok; prompts over 100k tokens bill
at 5x, which the price table cannot tell) + $10 per 1,000 searches, counted
from the larger of the reported number and the search blocks. No further
``pause_turn`` resume once the call has cost ``FRESH_TOPUP_SEED_MAX_USD``
(default $1.00), so the gather can overshoot that by at most one segment.
"""

from __future__ import annotations

import logging
import os
import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app import llm_usage
from app.corpus.fresh_brief import AUDIENCE, freshness_window
from app.sourcing.openai_web_search_source import (
    _anthropic_text_and_urls,
    _citation_key,
    _cited_url,
)

logger = logging.getLogger(__name__)

GATHER_MODEL = "claude-haiku-5-5"
DEFAULT_MAX_SEARCHES = 8
DEFAULT_SEED_MAX_USD = 1.0
MAX_TOKENS = 32000
# Low: reading results and writing digest lines is mechanical, and at "high"
# all three languages ran out of tokens thinking before writing a single
# digest line (dry run 2026-10-14: digest 0 in en/cs, ended max_tokens).
EFFORT = "low"
MAX_PAUSE_RESUMES = 4
SEARCH_FEE_CENTS = 1.0  # $10 per 1,000 web searches
HAIKU_LONG_PROMPT_TOKENS = 100_000
DIGEST_MAX_LINES = 120
DIGEST_MAX_CHARS = 60_000  # ~15k tokens at ~4 characters per token

WIKI_LANGUAGE = {"en": "English", "sk": "Slovak", "cs": "Czech"}
_SCENE = {
    "en": (
        "global entertainment (film, TV and streaming, music, video games, viral "
        "pop-culture moments) known worldwide, not only in the US."
    ),
    "sk": (
        "mostly the Slovak scene (Slovak celebrities, reality and TV shows, "
        "domestic hits, films and moments people in Slovakia talked about), plus "
        "world mega-hits well known in Slovakia. Skip the Czech scene unless it is "
        "genuinely shared."
    ),
    "cs": (
        "mostly the Czech scene (Czech celebrities, reality and TV shows, domestic "
        "hits, films and moments people in Czechia talked about), plus world "
        "mega-hits well known in Czechia. Skip the Slovak scene unless it is "
        "genuinely shared."
    ),
}

_PROMPT = """Today is {today}. Gather raw material for a voice trivia quiz played by {audience}. An editor picks the quiz topics later from your notes; your job is only to collect.

Run varied web searches about entertainment people talked about {window}: {scene} Search in {wiki} and in English, and mix film, TV and streaming, reality shows, music and charts, video games, celebrities and viral moments. Use the ideas below as search starting points.

Skip current politics, current wars or armed conflicts, crime and sport. Do not filter by taste otherwise: note every distinct entertainment item you saw. Prefer Wikipedia, domain authorities and reputable media; never tabloids, social media or Reddit.

Ideas: the most-read {wiki} Wikipedia articles of the last week and the last month (many are politics, crime or sport; ignore those):
{ideas}

Reply with the digest only: one line per distinct news item, 40 to 60 lines, each in this format:
headline | YYYY-MM-DD or unknown | URL of the search result it came from | one or two sentences stating the checkable fact"""

_BULLET = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s*")
_URL_IN = re.compile(r"https?://[^\s|<>\"\]\[]+")


def seed_tools() -> list[dict]:
    """Web search only (no web_fetch: pages are checked in ``seed_page_check``)."""
    searches = int(os.getenv("FRESH_TOPUP_SEED_SEARCHES") or DEFAULT_MAX_SEARCHES)
    return [{"type": "web_search_20260209", "name": "web_search", "max_uses": searches}]


def seed_max_cents() -> float:
    return float(os.getenv("FRESH_TOPUP_SEED_MAX_USD") or DEFAULT_SEED_MAX_USD) * 100


@dataclass
class Gathered:
    digest: list[str] = field(default_factory=list)
    urls: list[str] = field(default_factory=list)
    digest_lines: int = 0
    harvested: int = 0
    unsourced: int = 0
    budget_stopped: bool = False
    input_tokens: int = 0
    output_tokens: int = 0
    searches: int = 0
    cost_cents: float = 0.0
    error: str | None = None


ModelCall = Callable[[list[dict]], Awaitable[Any]]


def build_gather_prompt(lang: str, today: date, ideas: list[str]) -> str:
    return _PROMPT.format(
        today=today.isoformat(),
        audience=AUDIENCE[lang],
        scene=_SCENE[lang],
        window=freshness_window(today),
        wiki=WIKI_LANGUAGE[lang],
        ideas="\n".join(ideas) or "- (none available today)",
    )


async def _default_call(messages: list[dict]) -> Any:
    client = llm_factory.anthropic_client(timeout=900.0)
    async with client.messages.stream(
        model=GATHER_MODEL,
        max_tokens=MAX_TOKENS,
        tools=seed_tools(),
        output_config={"effort": EFFORT},
        messages=messages,
    ) as stream:
        return await stream.get_final_message()


def add_usage(g: Gathered, response: Any) -> None:
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
    g.input_tokens += tokens_in
    g.output_tokens += tokens_out
    g.searches += searches
    token_cents = llm_usage.cost_cents_for(GATHER_MODEL, tokens_in, tokens_out)
    if tokens_in > HAIKU_LONG_PROMPT_TOKENS:
        token_cents *= 5  # long prompts bill at $0.50 / $2.50
    g.cost_cents += token_cents + searches * SEARCH_FEE_CENTS


def harvest(blocks: list) -> list[tuple[str, str, str | None]]:
    """(title, url, page_age) of every web search hit, first occurrence wins."""
    seen: set = set()
    out: list[tuple[str, str, str | None]] = []
    for block in blocks:
        if getattr(block, "type", None) != "web_search_tool_result":
            continue
        results = getattr(block, "content", None)
        if not isinstance(results, list):  # a tool error is an object
            continue
        for hit in results:
            url = getattr(hit, "url", None)
            key = _citation_key(url) if url else None
            if key is None or key in seen:
                continue
            seen.add(key)
            title = " ".join(str(getattr(hit, "title", None) or "").split())
            out.append((title, url, getattr(hit, "page_age", None)))
    return out


def _clean_url(url: str) -> str:
    """Drop trailing punctuation, and a ')' only when it closes a markdown
    link, not a Wikipedia title such as ``Foo_(film)``."""
    url = url.rstrip(".,;>")
    while url.endswith(")") and url.count(")") > url.count("("):
        url = url[:-1].rstrip(".,;>")
    return url


def parse_digest(text: str, trusted: list[str]) -> tuple[list[tuple[str, str]], int]:
    """Model digest lines → [(line, tool url)], and how many cited no search hit."""
    lines: list[tuple[str, str]] = []
    seen: set[str] = set()
    unsourced = 0
    for raw in text.splitlines():
        parts = [p.strip() for p in _BULLET.sub("", raw).split("|")]
        parts = [p for p in parts if p and not set(p) <= set("-: ")]
        # The URL may come bare, in <...> or as a markdown link [title](url),
        # and the line may be a markdown table row (live run 2026-10-14: en
        # and sk digests parsed to 0 lines while cs, written plainly, gave 45).
        found = [(i, _URL_IN.search(p)) for i, p in enumerate(parts)]
        at = next((i for i, m in found if m), None)
        if at is None or len(parts) < 3:
            continue
        parts[at] = _clean_url(found[at][1].group(0))
        url = _cited_url(parts[at], trusted)
        if url is None:
            unsourced += 1
            continue
        parts[at] = url
        line = " | ".join(parts)
        if line.casefold() not in seen:
            seen.add(line.casefold())
            lines.append((line, url))
    return lines, unsourced


def merge_digest(
    lines: list[tuple[str, str]], hits: list[tuple[str, str, str | None]]
) -> tuple[list[str], list[str], int, int]:
    """Model lines first, then hits whose URL no line has; capped.

    Returns (digest, its URLs, model lines kept, harvested lines kept).
    """
    rows = [(line, url, False) for line, url in lines]
    present = {_citation_key(url) for _, url in lines}
    for title, url, age in hits:
        if _citation_key(url) not in present:
            present.add(_citation_key(url))
            rows.append(
                (f"{title or '(untitled)'} | {age or 'unknown'} | {url}", url, True)
            )
    digest: list[str] = []
    urls: list[str] = []
    chars, model, harvested = 0, 0, 0
    for line, url, is_hit in rows:
        if len(digest) >= DIGEST_MAX_LINES or chars + len(line) > DIGEST_MAX_CHARS:
            break
        digest.append(line)
        chars += len(line) + 1
        if url not in urls:
            urls.append(url)
        harvested += is_hit
        model += not is_hit
    return digest, urls, model, harvested


async def gather_digest(
    lang: str, today: date, ideas: list[str], call: ModelCall | None = None
) -> Gathered:
    """Haiku search loop (pause_turn resumed under the seed max) → merged digest."""
    call = call or _default_call
    prompt = build_gather_prompt(lang, today, ideas)
    messages: list[dict] = [{"role": "user", "content": prompt}]
    g = Gathered()
    # A resumed response carries only its own new blocks, so every segment's
    # blocks are kept: resent as the assistant prefix, read for lines and hits.
    blocks: list = []
    max_cents = seed_max_cents()
    stop = None
    try:
        for _ in range(1 + MAX_PAUSE_RESUMES):
            response = await call(messages)
            add_usage(g, response)
            blocks.extend(response.content)
            stop = response.stop_reason
            if stop != "pause_turn":
                break
            if g.cost_cents >= max_cents:
                g.budget_stopped = True
                logger.warning(
                    "seed gather %s: $%.2f spent, not resuming",
                    lang,
                    g.cost_cents / 100,
                )
                break
            messages = [
                {"role": "user", "content": prompt},
                {"role": "assistant", "content": list(blocks)},
            ]
    except Exception as exc:  # API error: spend so far still counted
        logger.exception("seed gather %s failed", lang)
        g.error = f"seed gather failed: {type(exc).__name__}: {exc}"
        return g
    if stop not in ("end_turn", "stop_sequence") and not g.budget_stopped:
        logger.warning("seed gather %s ended %r; using what it found", lang, stop)
    # Every segment's text: digest lines are recognisable wherever they are.
    text, trusted = _anthropic_text_and_urls(blocks)
    lines, g.unsourced = parse_digest(text, trusted)
    if not lines:
        logger.warning(
            "seed gather %s: no digest lines parsed from %r", lang, text[:400]
        )
    g.digest, g.urls, g.digest_lines, g.harvested = merge_digest(lines, harvest(blocks))
    if not g.digest:
        g.error = f"seed gather ended {stop!r} with an empty digest"
    return g
