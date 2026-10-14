"""Seed research for the weekly fresh run (#202 task 202.2).

Why: seeds are the only input that changes week to week, and nobody curates
them by hand any more. A fact web search never returned, a tabloid source or an
obscure subject goes straight into a brief and from there into the App Store
corpus, so each filter must actually cut. The cost must include the search
fees, or the $15 cap would under-count. And the seed call must stay cheap
(founder 2026-10-14, after $6.17 en / $15.89 sk on seeds in one dry run): no
web_fetch, searches capped from env, and no resume past the seed max.
"""

from __future__ import annotations

import json
from datetime import date
from types import SimpleNamespace

import pytest
from app.corpus import seed_research
from app.corpus.seed_filters import domestic_share, filter_seeds

TODAY = date(2026, 10, 14)


def _item(subject, url, *, wiki=None, scope="world"):
    return {
        "subject": subject,
        "wiki_title": wiki or subject,
        "scope": scope,
        "event_date": "2026-09-01",
        "fact": f"{subject} did something surprising.",
        "angle": "the twist",
        "source_url": url,
    }


def test_uncited_and_tabloid_seeds_are_dropped_and_the_shipped_url_is_the_tools():
    items = [
        _item("Cited", "https://en.wikipedia.org/wiki/Cited"),
        _item("Invented", "https://en.wikipedia.org/wiki/Never_opened"),
        _item("Tabloid", "https://www.novycas.sk/clanok/1"),
        _item("Reddit", "https://www.reddit.com/r/movies/1"),
    ]
    trusted = [
        "https://en.wikipedia.org/wiki/Cited?utm=x",
        "https://www.novycas.sk/clanok/1",
        "https://www.reddit.com/r/movies/1",
    ]
    seeds, dropped, _ = filter_seeds(items, trusted, lambda _t: None)
    assert [s.subject for s in seeds] == ["Cited"]
    assert seeds[0].source_url == "https://en.wikipedia.org/wiki/Cited?utm=x"
    assert dropped == {"uncited": 1, "low_credibility": 2}


def test_bottom_third_by_fame_is_dropped():
    items = [_item(f"S{i}", f"https://en.wikipedia.org/wiki/S{i}") for i in range(6)]
    trusted = [i["source_url"] for i in items]
    views = {f"S{i}": (i + 1) * 1000 for i in range(6)}
    seeds, dropped, fame_checked = filter_seeds(items, trusted, views.get)
    assert fame_checked
    assert dropped == {"low_fame": 2}
    assert {s.subject for s in seeds} == {"S2", "S3", "S4", "S5"}
    assert seeds[0].subject == "S5"  # most famous first


def test_fame_cut_is_skipped_when_wikimedia_is_unavailable():
    items = [_item(f"S{i}", f"https://en.wikipedia.org/wiki/S{i}") for i in range(6)]
    seeds, dropped, fame_checked = filter_seeds(
        items, [i["source_url"] for i in items], lambda _t: None
    )
    assert not fame_checked and len(seeds) == 6 and "low_fame" not in dropped


def test_domestic_share_only_for_sk_cs():
    items = [
        _item("A", "https://sk.wikipedia.org/wiki/A", scope="domestic"),
        _item("B", "https://sk.wikipedia.org/wiki/B", scope="domestic"),
        _item("C", "https://sk.wikipedia.org/wiki/C"),
    ]
    seeds, _, _ = filter_seeds(items, [i["source_url"] for i in items], lambda _t: None)
    assert domestic_share("sk", seeds) == 0.67
    assert domestic_share("en", seeds) is None


def _response(stop, content, searches=0):
    usage = SimpleNamespace(
        input_tokens=100_000,
        output_tokens=10_000,
        server_tool_use=SimpleNamespace(web_search_requests=searches),
    )
    return SimpleNamespace(stop_reason=stop, content=content, usage=usage)


def _hits(*urls):
    return SimpleNamespace(
        type="web_search_tool_result", content=[SimpleNamespace(url=u) for u in urls]
    )


async def _unreadable(url):
    return None


def test_seed_call_searches_only_with_max_uses_from_env(monkeypatch):
    """web_fetch made every later iteration re-read whole pages; it must stay off."""
    monkeypatch.delenv("FRESH_TOPUP_SEED_SEARCHES", raising=False)
    assert seed_research.seed_tools() == [
        {"type": "web_search_20260209", "name": "web_search", "max_uses": 8}
    ]
    monkeypatch.setenv("FRESH_TOPUP_SEED_SEARCHES", "5")
    (tool,) = seed_research.seed_tools()
    assert tool["name"] == "web_search" and tool["max_uses"] == 5


@pytest.mark.asyncio
async def test_research_resumes_pause_checks_pages_and_counts_cost(monkeypatch):
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "5")
    items = [
        _item("Kept", "https://cs.wikipedia.org/wiki/Kept"),
        _item("Wrong page", "https://www.irozhlas.cz/kultura/1"),
        _item("Fetch only", "https://cs.wikipedia.org/wiki/Fetch_only"),
    ]
    final = [
        _hits(
            "https://cs.wikipedia.org/wiki/Kept", "https://www.irozhlas.cz/kultura/1"
        ),
        SimpleNamespace(type="text", text=json.dumps(items), citations=None),
    ]
    calls: list[list[dict]] = []
    replies = [
        _response("pause_turn", ["partial"], searches=3),
        _response("end_turn", final, searches=2),
    ]

    async def fake_call(messages):
        calls.append(messages)
        return replies[len(calls) - 1]

    pages = {
        "https://cs.wikipedia.org/wiki/Kept": "Kept " * 100,
        "https://www.irozhlas.cz/kultura/1": "Something else entirely. " * 30,
    }

    async def fetch(url):
        return pages.get(url)

    result = await seed_research.research_seeds(
        "cs",
        TODAY,
        call=fake_call,
        ideas=["- Idea (1 views)"],
        fame_of=lambda _t: None,
        fetch_page=fetch,
    )
    assert [s.subject for s in result.seeds] == ["Kept"]
    # A URL web search never returned stays uncited (web_fetch is gone).
    assert result.dropped == {"uncited": 1, "page_mismatch": 1}
    assert result.page_check == {"page_ok": 1, "page_mismatch": 1, "page_unchecked": 0}
    assert len(calls) == 2 and calls[1][1] == {
        "role": "assistant",
        "content": ["partial"],
    }
    assert result.searches == 5 and not result.budget_stopped
    # 2 calls x (100k in @ $4/M + 10k out @ $20/M) = $1.20, + 5 searches x 1 cent.
    assert result.cost_cents == pytest.approx(120 + 5)


@pytest.mark.asyncio
async def test_resume_stops_once_seed_spend_passes_its_max(monkeypatch):
    """Each resume re-reads the whole context; past the seed max the job must
    stop paying for more and use the seeds already written."""
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "1")  # one segment = $0.61
    url = "https://sk.wikipedia.org/wiki/Early"
    partial = [
        _hits(url),
        SimpleNamespace(
            type="text", text=json.dumps([_item("Early", url)]), citations=None
        ),
    ]
    calls = []

    async def fake_call(messages):
        calls.append(messages)
        return _response("pause_turn", partial if len(calls) == 2 else [], searches=1)

    result = await seed_research.research_seeds(
        "sk",
        TODAY,
        call=fake_call,
        ideas=[],
        fame_of=lambda _t: None,
        fetch_page=_unreadable,
    )
    assert len(calls) == 2  # $0.61 < $1 resumes once; $1.22 stops
    assert result.budget_stopped and result.error is None
    assert [s.subject for s in result.seeds] == ["Early"]
    assert result.page_check["page_unchecked"] == 1


@pytest.mark.asyncio
async def test_budget_stop_without_any_seed_text_is_an_error(monkeypatch):
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "0.5")

    async def fake_call(messages):
        return _response("pause_turn", [], searches=1)

    result = await seed_research.research_seeds(
        "sk", TODAY, call=fake_call, ideas=[], fame_of=lambda _t: None
    )
    assert result.seeds == [] and "seed budget" in result.error
    assert result.cost_cents == pytest.approx(61)


@pytest.mark.asyncio
async def test_url_found_before_a_pause_still_cites_its_seed(monkeypatch):
    """A resumed response carries only its new blocks: a source searched in the
    first segment must still count as cited, or a correctly sourced seed is
    dropped as uncited. Every resume resends all earlier blocks."""
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "5")
    url = "https://sk.wikipedia.org/wiki/Early"
    early = SimpleNamespace(
        type="web_search_tool_result", content=[SimpleNamespace(url=url)]
    )
    items = [_item("Early", url)]
    final = [SimpleNamespace(type="text", text=json.dumps(items), citations=None)]
    calls: list[list[dict]] = []
    replies = [
        _response("pause_turn", [early], searches=1),
        _response("pause_turn", ["more"], searches=1),
        _response("end_turn", final),
    ]

    async def fake_call(messages):
        calls.append(messages)
        return replies[len(calls) - 1]

    result = await seed_research.research_seeds(
        "sk",
        TODAY,
        call=fake_call,
        ideas=["- Idea (1 views)"],
        fame_of=lambda _t: None,
        fetch_page=_unreadable,
    )
    assert [s.subject for s in result.seeds] == ["Early"]
    assert calls[2][1]["content"] == [early, "more"]


@pytest.mark.asyncio
async def test_refusal_gives_no_seeds_but_keeps_the_cost():
    async def fake_call(messages):
        return _response("refusal", [], searches=1)

    result = await seed_research.research_seeds(
        "sk", TODAY, call=fake_call, ideas=[], fame_of=lambda _t: None
    )
    assert result.seeds == [] and "refusal" in result.error
    assert result.cost_cents > 1


def test_prompt_carries_the_recipe_rules():
    en = seed_research.build_seed_prompt("en", TODAY, ["- Taylor Swift (9 views)"])
    cs = seed_research.build_seed_prompt("cs", TODAY, [])
    assert "Taylor Swift" in en and "not only in the US" in en
    assert (
        "Czech scene" in cs
        and "Skip the Slovak scene" in cs
        and "Slovak celebrities" not in cs
    )
    for prompt in (en, cs):
        assert "web fetch" not in prompt  # the call has no fetch tool
        assert "Reddit" in prompt and "award categories" in prompt
        assert (
            "current politics" in prompt and "between August and October 2026" in prompt
        )
