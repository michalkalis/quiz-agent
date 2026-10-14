"""Seed gather step of the weekly fresh run (#202, founder 2026-10-14).

Why: Haiku alone returned 3–17 candidates (en 0/5 fresh questions), so it now
only gathers a digest and Opus picks. The digest is the only material Opus
sees, so it must never come back near-empty (search hits are harvested), it
must carry only URLs web search really returned (or the integrity rule
"source = a page the tool saw" breaks), and its cost must count every search
and the long-prompt price, or the $15 cap under-counts.
"""

from __future__ import annotations

from datetime import date
from types import SimpleNamespace

import pytest
from app.corpus import seed_gather

TODAY = date(2026, 10, 14)


def _response(stop, content, searches=0, tokens_in=100_000):
    usage = SimpleNamespace(
        input_tokens=tokens_in,
        output_tokens=10_000,
        server_tool_use=SimpleNamespace(web_search_requests=searches),
    )
    return SimpleNamespace(stop_reason=stop, content=content, usage=usage)


def _hit(url, title="Title", age="2026-10-01"):
    return SimpleNamespace(url=url, title=title, page_age=age)


def _hits(*hits):
    return SimpleNamespace(type="web_search_tool_result", content=list(hits))


def _text(text):
    return SimpleNamespace(type="text", text=text, citations=None)


def test_gather_searches_only_with_max_uses_from_env(monkeypatch):
    """web_fetch made every later iteration re-read whole pages; it must stay off."""
    monkeypatch.delenv("FRESH_TOPUP_SEED_SEARCHES", raising=False)
    assert seed_gather.seed_tools() == [
        {"type": "web_search_20260209", "name": "web_search", "max_uses": 8}
    ]
    monkeypatch.setenv("FRESH_TOPUP_SEED_SEARCHES", "5")
    (tool,) = seed_gather.seed_tools()
    assert tool["name"] == "web_search" and tool["max_uses"] == 5


def test_seed_max_defaults_to_one_dollar(monkeypatch):
    monkeypatch.delenv("FRESH_TOPUP_SEED_MAX_USD", raising=False)
    assert seed_gather.seed_max_cents() == 100


@pytest.mark.asyncio
async def test_the_gather_request_goes_to_haiku_with_web_search_and_no_fetch(
    monkeypatch,
):
    """The real request must name Haiku and carry only the capped web_search,
    or the pinned role check and the cost model prove nothing."""
    sent: dict = {}

    class _Stream:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_exc):
            return False

        async def get_final_message(self):
            return _response("end_turn", [])

    class _Client:
        class messages:
            @staticmethod
            def stream(**kwargs):
                sent.update(kwargs)
                return _Stream()

    monkeypatch.setattr(
        seed_gather.llm_factory, "anthropic_client", lambda **_k: _Client()
    )
    await seed_gather._default_call([{"role": "user", "content": "x"}])
    assert sent["model"] == "claude-haiku-5-5"
    assert [t["name"] for t in sent["tools"]] == ["web_search"]


@pytest.mark.asyncio
async def test_harvested_hits_fill_a_thin_digest():
    """Haiku wrote one line for five hits (the en dry run had 3 candidates in
    all): the other four hits still reach the picker, with title and date, and
    the hit already in a model line is not repeated."""
    urls = [f"https://en.wikipedia.org/wiki/H{i}" for i in range(5)]
    reply = [
        _hits(*(_hit(u, title=f"Hit {i}") for i, u in enumerate(urls))),
        _text(f"Here you go:\n- Big news | 2026-10-02 | {urls[0]} | A thing happened."),
    ]

    async def call(messages):
        return _response("end_turn", reply, searches=1)

    g = await seed_gather.gather_digest("en", TODAY, [], call=call)
    assert g.error is None and (g.digest_lines, g.harvested) == (1, 4)
    assert g.digest[0] == f"Big news | 2026-10-02 | {urls[0]} | A thing happened."
    assert g.digest[1] == f"Hit 1 | 2026-10-01 | {urls[1]}"
    assert g.urls == urls


@pytest.mark.asyncio
async def test_a_digest_line_with_a_url_search_never_returned_is_dropped():
    """A URL Haiku wrote down but no search returned would let an invented
    source through the cite filter; a tidied URL maps back to the tool's."""
    tool_url = "https://sk.wikipedia.org/wiki/Real?utm=x"
    reply = [
        _hits(_hit(tool_url)),
        _text(
            "Real | unknown | https://sk.wikipedia.org/wiki/Real | Fact.\n"
            "Made up | 2026-10-01 | https://sk.wikipedia.org/wiki/Invented | Fact."
        ),
    ]

    async def call(messages):
        return _response("end_turn", reply)

    g = await seed_gather.gather_digest("sk", TODAY, [], call=call)
    assert g.digest == [f"Real | unknown | {tool_url} | Fact."]
    assert g.unsourced == 1 and g.harvested == 0


@pytest.mark.asyncio
async def test_hits_before_a_pause_stay_in_the_digest(monkeypatch):
    """A resumed response carries only its new blocks: hits of the first
    segment must still be harvested, and every resume resends all blocks."""
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "5")
    early = _hits(_hit("https://cs.wikipedia.org/wiki/Early"))
    calls: list[list[dict]] = []
    replies = [
        _response("pause_turn", [early], searches=1),
        _response("pause_turn", [_text("more")], searches=1),
        _response("end_turn", [_text("done")]),
    ]

    async def call(messages):
        calls.append(messages)
        return replies[len(calls) - 1]

    g = await seed_gather.gather_digest("cs", TODAY, [], call=call)
    assert g.urls == ["https://cs.wikipedia.org/wiki/Early"]
    assert calls[2][1]["content"][0] is early and len(calls[2][1]["content"]) == 2
    assert g.searches == 2


@pytest.mark.asyncio
async def test_resume_stops_once_gather_spend_passes_the_seed_max(monkeypatch):
    """Each resume re-reads the whole context; past the seed max the job stops
    paying and uses what it has gathered."""
    monkeypatch.setenv("FRESH_TOPUP_SEED_MAX_USD", "0.04")  # one segment = $0.025
    calls = []

    async def call(messages):
        calls.append(messages)
        hit = _hits(_hit(f"https://sk.wikipedia.org/wiki/P{len(calls)}"))
        return _response("pause_turn", [hit], searches=1)

    g = await seed_gather.gather_digest("sk", TODAY, [], call=call)
    assert len(calls) == 2  # $0.025 < $0.04 resumes once; $0.05 stops
    assert g.budget_stopped and g.error is None and g.harvested == 2


@pytest.mark.asyncio
async def test_an_empty_digest_is_an_error_that_keeps_the_cost():
    async def call(messages):
        return _response("refusal", [], searches=1)

    g = await seed_gather.gather_digest("sk", TODAY, [], call=call)
    assert g.digest == [] and "refusal" in g.error
    assert g.cost_cents == pytest.approx(2.5)  # 1.5 tokens + 1 search


def test_digest_is_capped_with_model_lines_first():
    """The pick input must stay bounded (no loop, fixed worst case), and the
    model's fact lines are worth more than bare hits."""
    lines = [("Model | unknown | https://a.org/m | fact", "https://a.org/m")]
    hits = [(f"T{i}", f"https://a.org/{i}", None) for i in range(300)]
    digest, urls, model, harvested = seed_gather.merge_digest(lines, hits)
    assert len(digest) == seed_gather.DIGEST_MAX_LINES
    assert digest[0].startswith("Model") and (model, harvested) == (1, 119)
    assert len(urls) == seed_gather.DIGEST_MAX_LINES


def test_gather_cost_counts_search_blocks_and_long_prompt_price():
    """Haiku 5.5 reported 0 searches for a reply with two search blocks
    (2026-10-14), and prompts over 100k tokens bill at 5x the table price."""
    search = SimpleNamespace(type="server_tool_use", name="web_search")
    usage = SimpleNamespace(
        input_tokens=200_000,
        output_tokens=0,
        server_tool_use=SimpleNamespace(web_search_requests=0),
    )
    g = seed_gather.Gathered()
    seed_gather.add_usage(g, SimpleNamespace(content=[search, search], usage=usage))
    assert g.searches == 2
    base = seed_gather.llm_usage.cost_cents_for("claude-haiku-5-5", 200_000, 0)
    assert g.cost_cents == pytest.approx(base * 5 + 2 * seed_gather.SEARCH_FEE_CENTS)


def test_gather_prompt_asks_for_a_broad_digest_by_the_recipe():
    en = seed_gather.build_gather_prompt("en", TODAY, ["- Taylor Swift (9 views)"])
    cs = seed_gather.build_gather_prompt("cs", TODAY, [])
    assert "Taylor Swift" in en and "not only in the US" in en
    assert "Czech scene" in cs and "Skip the Slovak scene" in cs
    for prompt in (en, cs):
        assert "40 to 60 lines" in prompt and "Do not filter by taste" in prompt
        assert "headline | YYYY-MM-DD or unknown | URL" in prompt
        assert "current politics" in prompt and "crime" in prompt
        assert "between August and October 2026" in prompt


def test_gather_runs_at_low_effort():
    """At high effort Haiku spent its whole token budget thinking and wrote no
    digest (2026-10-14), leaving Opus only bare headlines to pick from."""
    assert seed_gather.EFFORT == "low"
