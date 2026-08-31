"""Tests for `scripts/source_facts.py` (#167 task 167.5, decision D4).

Why these tests matter:
- The fact file is a **hand-off artifact**: the pilot sources once, then every
  generation run reads it back through `generate_pack --facts-file`. A format
  drift would only surface during the paid Fable 5 run, so the round-trip is
  asserted against the real consumer (`_FactsFileSourcingStage`), not against
  a hand-written expectation of the shape.
- A thin yield must **fail loud**. Silently writing a 12-fact file would let
  generation produce a short batch that looks successful, and the per-topic
  tally is what tells the retry which topic phrasings to narrow.
- The source mix is a decision, not an accident: OpenTriviaDB serves canned
  pre-cutoff trivia and must stay off (D4).

No network: `FactSourcer` is replaced by a stub in every test.
"""

from __future__ import annotations

import json
import types

import pytest

import scripts.source_facts as source_facts
from app.sourcing.models import Fact, FactBatch

TOPICS = [
    "music producers and their artists",
    "2026 album releases",
    "2026 awards and nominations",
    "2026 tours and festivals",
]


def _facts(per_topic: dict[str, int]) -> list[Fact]:
    return [
        Fact(
            text=f"{topic} fact {i}",
            source_url=f"https://example.com/{topic.replace(' ', '-')}/{i}",
            source_name="example.com",
            excerpt=f"excerpt for {topic} fact {i}",
            topic=topic,
        )
        for topic, count in per_topic.items()
        for i in range(count)
    ]


class _StubSourcer:
    """Records construction kwargs; returns a fixed batch from `gather_facts`."""

    calls: list[dict] = []

    def __init__(self, **kwargs):
        type(self).calls.append(kwargs)
        self.kwargs = kwargs

    async def gather_facts(self, count: int, topics: list[str]) -> FactBatch:
        per_topic = type(self).per_topic
        facts = _facts(per_topic)
        return FactBatch(
            facts=facts,
            sources_used=["wikipedia", "web_search"],
            facts_per_topic=dict(per_topic),
        )


@pytest.fixture
def stub_sourcer(monkeypatch):
    def _install(per_topic: dict[str, int]) -> type[_StubSourcer]:
        stub = type("_Stub", (_StubSourcer,), {"calls": [], "per_topic": per_topic})
        monkeypatch.setattr("app.sourcing.fact_sourcer.FactSourcer", stub, raising=True)
        return stub

    return _install


class TestHealthyYield:
    def test_fact_file_is_consumable_by_the_generator(self, tmp_path, stub_sourcer):
        # 40+ facts clear the gate; the written file must then load through the
        # SAME stage generate_pack uses for --facts-file. This assertion, not a
        # literal key check, is what pins the format across future refactors.
        stub_sourcer({t: 11 for t in TOPICS})  # 44 facts
        out = tmp_path / "facts_167.json"

        assert source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)]) == 0

        stage = _facts_file_stage(str(out))
        ctx = types.SimpleNamespace(facts=None, auto_topics=None)
        result = _run_stage(stage, ctx)

        assert result.info["facts"] == 44
        assert len(ctx.facts) == 44
        # auto_topics is what the generation prompt steers on downstream, so the
        # topic list must survive the round trip in the order it was requested.
        assert ctx.auto_topics == TOPICS
        assert all(isinstance(f, Fact) for f in ctx.facts)
        assert ctx.facts[0].excerpt  # D6's offline excerpt join depends on it

    def test_written_payload_carries_topics_and_facts(self, tmp_path, stub_sourcer):
        stub_sourcer({t: 11 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)])

        payload = json.loads(out.read_text())
        assert payload["topics"] == TOPICS
        assert len(payload["facts"]) == 44


class TestThinYieldGate:
    def test_thin_yield_exits_one_and_names_the_weak_topics(
        self, tmp_path, stub_sourcer, capsys
    ):
        # 39 facts — one short of the D4 minimum. The run must fail rather than
        # hand generation a starved fact file that still looks successful.
        per_topic = {
            TOPICS[0]: 20,
            TOPICS[1]: 17,
            TOPICS[2]: 2,
            TOPICS[3]: 0,
        }
        assert sum(per_topic.values()) == 39
        stub_sourcer(per_topic)
        out = tmp_path / "facts_167.json"

        assert source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)]) == 1

        stdout = capsys.readouterr().out
        assert "THIN YIELD" in stdout
        # The tally must name the starved topics — that is the actionable half:
        # the retry narrows exactly those phrasings (D6 remedy round).
        weak_line = [
            ln for ln in stdout.splitlines() if ln.startswith("weakest topics")
        ]
        assert len(weak_line) == 1
        assert TOPICS[3] in weak_line[0]
        assert TOPICS[2] in weak_line[0]
        # Topics that pulled their weight must NOT be blamed.
        assert TOPICS[0] not in weak_line[0]
        assert TOPICS[1] not in weak_line[0]

    def test_exactly_forty_facts_passes(self, tmp_path, stub_sourcer):
        # The gate is "< 40 fails" — 40 is the accepted boundary, so an
        # off-by-one here would reject a batch the pilot is allowed to use.
        stub_sourcer({t: 10 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        assert source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)]) == 0


class TestSourceMix:
    def test_opentdb_is_disabled_and_wikipedia_is_not(self, tmp_path, stub_sourcer):
        # D4: OpenTriviaDB is canned pre-cutoff trivia (off); Wikipedia stays ON
        # — a deliberate deviation from the D21b news recipe, so an agent
        # "fixing" it to match run_d21b_arms.py breaks this test.
        stub = stub_sourcer({t: 11 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)])

        assert stub.calls == [{"enable_opentdb": False}]

    def test_provider_defaults_to_tavily(self, tmp_path, stub_sourcer):
        # D5: `--provider` defaults to Tavily and the default run constructs
        # FactSourcer exactly as it did before the switch existed — the
        # rollback path must stay identical, not merely equivalent.
        stub = stub_sourcer({t: 11 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)])

        assert "web_search_provider" not in stub.calls[0]

    def test_openai_provider_is_passed_through(self, tmp_path, stub_sourcer):
        # D5 (founder 2026-08-31): the pilot re-run sources through OpenAI
        # Responses web_search because the Tavily limit is exhausted. If the
        # flag stopped reaching FactSourcer the run would silently go back to
        # the exhausted provider and return 0 facts.
        stub = stub_sourcer({t: 11 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        source_facts.main(
            ["--topics", ",".join(TOPICS), "--out", str(out), "--provider", "openai"]
        )

        assert stub.calls == [
            {"enable_opentdb": False, "web_search_provider": "openai"}
        ]

    def test_news_mode_is_never_enabled(self, tmp_path, stub_sourcer, monkeypatch):
        # D4: recency comes from the locked topic list, not the provider's news
        # narrowing. The script must neither set nor depend on the env var.
        monkeypatch.delenv("ENABLE_NEWS_SOURCING", raising=False)
        stub_sourcer({t: 11 for t in TOPICS})
        out = tmp_path / "facts_167.json"

        source_facts.main(["--topics", ",".join(TOPICS), "--out", str(out)])

        import os

        assert "ENABLE_NEWS_SOURCING" not in os.environ


def _facts_file_stage(path: str):
    import scripts.generate_pack as generate_pack

    return generate_pack._FactsFileSourcingStage(path)


def _run_stage(stage, ctx):
    import asyncio

    return asyncio.run(stage.run(ctx, None))
