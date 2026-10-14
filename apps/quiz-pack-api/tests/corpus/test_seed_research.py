"""Seed research for the weekly fresh run (#202 task 202.2).

Why: seeds are the only input that changes week to week, and nobody curates
them by hand any more. A fact web search never returned, a tabloid source or an
obscure subject goes straight into a brief and from there into the App Store
corpus, so each filter must actually cut. Since 2026-10-14 the seeds come in
two steps (founder: "čítanie celých stránok môže robiť Haiku"): Haiku gathers a
digest (``test_seed_gather``), Opus picks from it without tools. The pick must
only cite digest URLs, and the seed cost must hold both steps, or the $15 cap
under-counts.
"""

import json
from datetime import date
from types import SimpleNamespace

import pytest
from app.corpus import seed_research
from app.corpus.seed_filters import Seed, domestic_share, filter_seeds, subject_cap

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


def _response(stop, content, tokens_in=10_000, tokens_out=1_000):
    usage = SimpleNamespace(
        input_tokens=tokens_in,
        output_tokens=tokens_out,
        server_tool_use=SimpleNamespace(web_search_requests=0),
    )
    return SimpleNamespace(stop_reason=stop, content=content, usage=usage)


def _text(text):
    return SimpleNamespace(type="text", text=text, citations=None)


def _gather(*urls, lines=None, searches=1):
    """A gather call whose search returned ``urls`` (and wrote ``lines``)."""
    hits = SimpleNamespace(
        type="web_search_tool_result",
        content=[SimpleNamespace(url=u, title=f"T {u}", page_age=None) for u in urls],
    )
    content = [hits] + ([_text("\n".join(lines))] if lines else [])
    search = SimpleNamespace(type="server_tool_use", name="web_search")

    async def call(messages):
        return _response("end_turn", content + [search] * searches, 100_000, 10_000)

    return call


def _picker(*replies):
    calls: list[list[dict]] = []

    async def call(messages):
        calls.append(messages)
        return replies[len(calls) - 1]

    return call, calls


async def _unreadable(url):
    return None


async def _run(lang, gather_call, pick_call, **kw):
    return await seed_research.research_seeds(
        lang,
        TODAY,
        gather_call=gather_call,
        pick_call=pick_call,
        ideas=kw.pop("ideas", ["- Idea (1 views)"]),
        fame_of=lambda _t: None,
        fetch_page=kw.pop("fetch_page", _unreadable),
    )


@pytest.mark.asyncio
async def test_pick_sees_the_digest_and_drops_seeds_citing_urls_outside_it():
    """Opus reads only the digest; a source it did not get from there is not a
    page web search returned, so the seed is uncited however plausible it is."""
    kept_url = "https://cs.wikipedia.org/wiki/Kept"
    wrong_url = "https://www.irozhlas.cz/kultura/1"
    items = [
        _item("Kept", kept_url),
        _item("Wrong page", wrong_url),
        _item("Invented", "https://cs.wikipedia.org/wiki/Not_in_digest"),
    ]
    gather = _gather(
        kept_url, wrong_url, lines=[f"Kept news | unknown | {kept_url} | F."]
    )
    pick, calls = _picker(_response("end_turn", [_text(json.dumps(items))]))
    pages = {kept_url: "Kept " * 100, wrong_url: "Something else entirely. " * 30}

    async def fetch(url):
        return pages.get(url)

    result = await _run("cs", gather, pick, fetch_page=fetch)
    prompt = calls[0][0]["content"]
    assert f"Kept news | unknown | {kept_url} | F." in prompt
    assert wrong_url in prompt  # harvested hit
    assert [s.subject for s in result.seeds] == ["Kept"]
    assert result.dropped == {"uncited": 1, "page_mismatch": 1}
    assert (result.candidates, result.digest_lines, result.harvested) == (3, 1, 1)


@pytest.mark.asyncio
async def test_seed_cost_sums_the_haiku_gather_and_the_opus_pick():
    """Both steps are paid; leaving either out under-counts the $15 cap. The
    gather counts its search blocks (Haiku reports 0) and the long-prompt
    price (here 100k is not over the 100k line)."""
    url = "https://en.wikipedia.org/wiki/A"
    pick, _ = _picker(_response("end_turn", [_text(json.dumps([_item("A", url)]))]))
    result = await _run("en", _gather(url, searches=2), pick)
    # Gather: 100k in @ $0.10/M + 10k out @ $0.50/M = 1.5 cents, + 2 searches.
    assert result.gather_cents == pytest.approx(1.5 + 2)
    # Pick: 10k in @ $4/M + 1k out @ $20/M = 6 cents.
    assert result.pick_cents == pytest.approx(6)
    assert result.cost_cents == pytest.approx(9.5)
    assert result.searches == 2


@pytest.mark.asyncio
async def test_the_pick_request_goes_to_opus_without_tools(monkeypatch):
    """Opus with web_search cost $0.8–3.2 per language (2026-10-14); the pick
    must never carry a tool, and runs at medium effort."""
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
        seed_research.llm_factory, "anthropic_client", lambda **_k: _Client()
    )
    await seed_research._pick_call([{"role": "user", "content": "x"}])
    assert sent["model"] == "claude-opus-5-5"
    assert "tools" not in sent
    assert sent["output_config"] == {"effort": "medium"}


@pytest.mark.asyncio
async def test_gather_failure_skips_the_pick_but_keeps_the_cost():
    async def gather(messages):
        return _response("refusal", [], 100_000, 10_000)

    pick, calls = _picker()
    result = await _run("sk", gather, pick)
    assert calls == [] and result.seeds == [] and "refusal" in result.error
    assert result.cost_cents == pytest.approx(1.5)


@pytest.mark.asyncio
async def test_pick_refusal_gives_no_seeds_but_keeps_both_costs():
    url = "https://sk.wikipedia.org/wiki/A"
    pick, _ = _picker(_response("refusal", []))
    result = await _run("sk", _gather(url), pick)
    assert result.seeds == [] and "seed pick ended 'refusal'" in result.error
    assert result.cost_cents == pytest.approx(1.5 + 1 + 6)


def test_pick_prompt_carries_the_recipe_rules():
    en = seed_research.build_pick_prompt(
        "en", TODAY, ["- Taylor Swift (9 views)"], ["Line | unknown | https://x.org/a"]
    )
    cs = seed_research.build_pick_prompt("cs", TODAY, [], [])
    assert "Taylor Swift" in en and "not only in the US" in en
    assert "Line | unknown | https://x.org/a" in en
    assert (
        "Czech scene" in cs
        and "Skip the Slovak scene" in cs
        and "Slovak celebrities" not in cs
    )
    for prompt in (en, cs):
        assert "Reddit" in prompt and "award categories" in prompt
        assert "At most 2 seeds about the same subject" in prompt
        assert "MUST be copied exactly from one digest line" in prompt
        assert (
            "current politics" in prompt and "between August and October 2026" in prompt
        )


def test_seed_array_found_after_prose_with_brackets():
    """Prose before the array may contain '[' (the sk dry run of 2026-10-14
    parsed nothing): the first array of objects anywhere must still be read."""
    items = [_item("Zrádci", "https://cs.wikipedia.org/wiki/Zr%C3%A1dci")]
    text = "Searched [3 sources] first.\n" + json.dumps(items, ensure_ascii=False)
    assert seed_research._parse_seed_array(text) == items
    assert seed_research._parse_seed_array("no array here [1, 2]") == []


@pytest.mark.asyncio
async def test_pick_without_array_gets_one_nudge_then_a_clear_error():
    """A reply with prose only gets one follow-up asking for the array; if
    that also fails the language reports what came back instead of a bare
    'no usable seeds'."""
    url = "https://sk.wikipedia.org/wiki/Early"
    prose = _text("Here is what I found.")
    array = _text(json.dumps([_item("Early", url)]))
    pick, calls = _picker(
        _response("end_turn", [prose]), _response("end_turn", [array])
    )
    result = await _run("sk", _gather(url), pick)
    assert [s.subject for s in result.seeds] == ["Early"]
    assert calls[1][-1] == {"role": "user", "content": seed_research.JSON_NUDGE}
    assert calls[1][1] == {"role": "assistant", "content": [prose]}

    pick, calls = _picker(
        _response("end_turn", [prose]), _response("end_turn", [prose])
    )
    result = await _run("sk", _gather(url), pick)
    assert len(calls) == 2 and not result.seeds
    assert "no JSON array" in result.error and "Here is what I found" in result.error


def test_seed_steps_run_on_haiku_then_opus():
    """Founder 2026-10-14: the cheap model reads, the strong one decides."""
    assert seed_research.seed_gather.GATHER_MODEL == "claude-haiku-5-5"
    assert seed_research.PICK_MODEL == "claude-opus-5-5"


def _seed(subject, wiki=None):
    return Seed(
        subject=subject,
        fact="f",
        angle="a",
        source_url="https://en.wikipedia.org/wiki/X",
        wiki_title=wiki,
    )


def test_subject_cap_keeps_two_and_drops_the_third_across_diacritics():
    """Founder: "Max. 2 na tému" - the sk dry run had 3 of 5 questions about one
    singer. "Šimon Pleško", "Simon Plesko" and an article titled "Šimon Pleško
    (spevák)" are one person, so the third spelling must be cut."""
    dropped: dict[str, int] = {}
    seeds = [
        _seed("Šimon Pleško"),
        _seed("Other act"),
        _seed("simon plesko"),
        _seed("Singer", wiki="Šimon Pleško (spevák)"),
        _seed("Yet another"),
    ]
    kept = subject_cap(seeds, dropped)
    assert [s.subject for s in kept] == [
        "Šimon Pleško",
        "Other act",
        "simon plesko",
        "Yet another",
    ]
    assert dropped == {"same_subject": 1}


@pytest.mark.asyncio
async def test_research_applies_the_subject_cap_before_the_fame_cut():
    """Run through research_seeds: capped seeds are counted as same_subject and
    never reach the fame cut (skipped here: no fame data) or the brief."""
    urls = [f"https://en.wikipedia.org/wiki/P{i}" for i in range(4)]
    items = [_item("Taylor Swift", u) for u in urls[:3]] + [_item("Other", urls[3])]
    pick, _ = _picker(_response("end_turn", [_text(json.dumps(items))]))
    result = await _run("en", _gather(*urls), pick, ideas=[])
    assert result.dropped["same_subject"] == 1
    assert sorted(s.subject for s in result.seeds) == [
        "Other",
        "Taylor Swift",
        "Taylor Swift",
    ]
