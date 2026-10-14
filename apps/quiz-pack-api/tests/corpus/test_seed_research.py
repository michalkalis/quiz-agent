"""Seed research for the weekly fresh run (#202 task 202.2).

Why: seeds are the only input that changes week to week, and nobody curates
them by hand any more. A fact the tools never opened, a tabloid source or an
obscure subject goes straight into a brief and from there into the App Store
corpus, so each filter must actually cut — and a fact verified only via
web_fetch must survive (otherwise sk/cs, where fetch is how pages get read,
would lose most of its seeds). The cost must include the search fees, or the
$15 cap would under-count.
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


def _response(stop, content, searches=0, fetches=0):
    usage = SimpleNamespace(
        input_tokens=100_000,
        output_tokens=10_000,
        server_tool_use=SimpleNamespace(
            web_search_requests=searches, web_fetch_requests=fetches
        ),
    )
    return SimpleNamespace(stop_reason=stop, content=content, usage=usage)


@pytest.mark.asyncio
async def test_research_keeps_fetch_only_seed_resumes_pause_and_counts_cost():
    items = [
        _item("Fetched", "https://cs.wikipedia.org/wiki/Fetched"),
        _item("Searched", "https://www.irozhlas.cz/kultura/1"),
    ]
    final = [
        SimpleNamespace(
            type="web_search_tool_result",
            content=[SimpleNamespace(url="https://www.irozhlas.cz/kultura/1")],
        ),
        SimpleNamespace(
            type="web_fetch_tool_result",
            content=SimpleNamespace(
                type="web_fetch_result", url="https://cs.wikipedia.org/wiki/Fetched"
            ),
        ),
        SimpleNamespace(type="text", text=json.dumps(items), citations=None),
    ]
    calls: list[list[dict]] = []
    replies = [
        _response("pause_turn", ["partial"], searches=3),
        _response("end_turn", final, searches=2, fetches=4),
    ]

    async def fake_call(messages):
        calls.append(messages)
        return replies[len(calls) - 1]

    result = await seed_research.research_seeds(
        "cs", TODAY, call=fake_call, ideas=["- Idea (1 views)"], fame_of=lambda _t: None
    )
    assert {s.subject for s in result.seeds} == {"Fetched", "Searched"}
    assert len(calls) == 2 and calls[1][1] == {
        "role": "assistant",
        "content": ["partial"],
    }
    assert (result.searches, result.fetches) == (5, 4)
    # 2 calls x (100k in @ $4/M + 10k out @ $20/M) = $1.20, + 5 searches x 1 cent.
    assert result.cost_cents == pytest.approx(120 + 5)


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
        assert "Reddit" in prompt and "award categories" in prompt
        assert (
            "current politics" in prompt and "between August and October 2026" in prompt
        )
