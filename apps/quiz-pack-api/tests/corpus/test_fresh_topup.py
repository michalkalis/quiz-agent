"""The weekly fresh-entertainment orchestrator (#202 task 202.3).

Why: this job spends real money and publishes to the App Store with nobody
watching. It must never run on the subscription, never start a paid call on a
moved role map, stop starting languages when the $15 cap cannot cover the next
one, skip generation when the seeds left too little for it, count every cent
once, rotate which language risks the cap, write nothing on a dry run, raise
its Sentry summary to "warning" when a human should look, and print a compact
block the workflow can cut out of the log (the JSON alone was lost on
2026-10-14). All seeds / generation / DB are faked here.
"""

from __future__ import annotations

import uuid
from datetime import date

import pytest
from app.corpus import fresh_report, fresh_topup
from app.corpus.fresh_generate import (
    GenerationResult,
    build_fresh_stages,
    pipeline_spend_cents,
    post_filter,
)
from app.corpus.importer import ImportResult
from app.corpus.seed_filters import Seed
from app.corpus.seed_research import SeedResult
from app.orchestrator.stages import (
    AnswerabilityStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    TopUpStage,
)
from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

TODAY = date(2026, 10, 14)  # ISO week 42


def _q(lang="en", source="https://en.wikipedia.org/wiki/X") -> Question:
    return Question(
        id=str(uuid.uuid4()),
        question="In which 2026 film did a talking dog sing?",
        correct_answer="Dogtown",
        topic="Film",
        category="entertainment",
        difficulty="medium",
        language=lang,
        source_url=source,
    )


class FakeDeps:
    def __init__(self, seed_cents=100.0, gen_cents=400.0, pending=0):
        self.calls: list[str] = []
        self.import_kwargs: list[dict] = []
        self.seed_cents, self.gen_cents, self.pending = seed_cents, gen_cents, pending

    async def research_seeds(self, lang, today):
        self.calls.append(f"seeds:{lang}")
        seed = Seed("S", "fact", "angle", "https://en.wikipedia.org/wiki/S", "domestic")
        return SeedResult(
            seeds=[seed],
            candidates=1,
            domestic_share=1.0,
            cost_cents=self.seed_cents,
            page_check={"page_ok": 1, "page_mismatch": 0, "page_unchecked": 0},
        )

    async def load_covered(self, today):
        self.calls.append("covered")
        return ["- old -> fact"]

    async def generate(self, lang, brief, count):
        self.calls.append(f"generate:{lang}")
        assert "- old -> fact" in brief and "https://en.wikipedia.org/wiki/S" in brief
        good = _q(lang, "https://en.wikipedia.org/wiki/Good")
        return GenerationResult(
            questions=[good, _q(lang, source=None), _q("en" if lang != "en" else "sk")],
            tokens_cents=self.gen_cents,
        )

    async def import_questions(self, questions, *, review_status, execute):
        self.import_kwargs.append({"review_status": review_status, "execute": execute})
        approved = len(questions) - self.pending
        return ImportResult(
            unique=len(questions),
            to_insert=len(questions),
            approved=approved,
            pending=self.pending,
            statuses={q.id: "approved" for q in questions},
        )

    def deps(self) -> fresh_topup.Deps:
        return fresh_topup.Deps(
            self.research_seeds, self.load_covered, self.generate, self.import_questions
        )


def _args(*argv):
    return fresh_topup.parse_args(list(argv))


@pytest.fixture
def roles_ok(monkeypatch):
    monkeypatch.setattr(fresh_topup, "check_roles", lambda langs: {})


@pytest.mark.asyncio
async def test_session_gateway_is_refused_before_any_call(monkeypatch):
    monkeypatch.setenv("LLM_GATEWAY", "session")
    fake = FakeDeps()
    with pytest.raises(fresh_topup.SessionGatewayRefused):
        await fresh_topup.run(_args(), fake.deps(), TODAY)
    assert fake.calls == []


@pytest.mark.asyncio
async def test_role_map_mismatch_fails_before_any_call(monkeypatch):
    from app.corpus.fresh_roles import RoleMapError

    monkeypatch.setattr(llm_factory, "FACTCHECK", "gpt-5-mini")  # prod default
    fake = FakeDeps()
    with pytest.raises(RoleMapError):
        await fresh_topup.run(_args(), fake.deps(), TODAY)
    assert fake.calls == []


@pytest.mark.asyncio
async def test_language_is_skipped_when_remaining_budget_is_below_worst_case(
    monkeypatch, roles_ok
):
    monkeypatch.setenv("FRESH_TOPUP_LANG_WORST_USD", "6")
    fake = FakeDeps(seed_cents=100, gen_cents=400)  # $5 per language
    summary = await fresh_topup.run(
        _args("--languages", "en,sk", "--max-usd", "10"), fake.deps(), TODAY
    )
    first, second = summary["order"]
    assert summary["languages"][first]["status"] == "done"
    assert summary["languages"][second]["status"] == "skipped"
    assert "budget" in summary["languages"][second]["reason"]
    assert summary["cap_hit"] and summary["spent_usd"] == 5.0
    assert f"seeds:{second}" not in fake.calls
    assert fresh_report.summary_level(summary) == "warning"


@pytest.mark.asyncio
async def test_generation_is_skipped_when_seeds_left_less_than_its_worst_case(
    monkeypatch, roles_ok
):
    """The start gate alone let one language's seeds blow the cap; after the
    seeds the budget is checked again, so generation never starts uncovered."""
    monkeypatch.setenv("FRESH_TOPUP_LANG_WORST_USD", "5")
    monkeypatch.setenv("FRESH_TOPUP_GEN_WORST_USD", "3")
    fake = FakeDeps(seed_cents=250)  # $5 budget - $2.50 seeds = $2.50 < $3
    summary = await fresh_topup.run(
        _args("--languages", "sk", "--max-usd", "5"), fake.deps(), TODAY
    )
    entry = summary["languages"]["sk"]
    assert entry["status"] == "skipped" and "generation worst case" in entry["reason"]
    assert "generate:sk" not in fake.calls
    assert summary["cap_hit"] and summary["spent_usd"] == 2.5
    assert entry["cost"]["total_usd"] == 2.5


def test_lang_worst_case_default_covers_seed_max_plus_generation():
    from app.corpus import seed_research

    assert fresh_topup.DEFAULT_LANG_WORST_USD >= (
        seed_research.DEFAULT_SEED_MAX_USD + fresh_topup.DEFAULT_GEN_WORST_USD
    )


def test_factcheck_search_fees_are_counted_once():
    usage = {
        "total_cost_cents_known": 500.0,  # includes the fact-check's 100 token cents
        "stages": {"verifying": {"claude-sonnet-5-5": {"cost_cents": 100.0}}},
    }
    tokens, search = pipeline_spend_cents(usage, 300, "claude-sonnet-5-5")
    assert (tokens, search) == (500.0, 200.0)  # ctx 300 = 100 tokens + 200 searches
    assert tokens + search == 700.0


def test_order_rotates_each_iso_week():
    week42 = fresh_topup.rotate(["en", "sk", "cs"], TODAY)
    week43 = fresh_topup.rotate(["en", "sk", "cs"], date(2026, 10, 21))
    assert week42 == ["en", "sk", "cs"]  # 42 % 3 == 0
    assert week43 == ["sk", "cs", "en"]
    assert sorted(week43) == sorted(week42)


@pytest.mark.asyncio
async def test_dry_run_writes_nothing_and_reports_the_questions(roles_ok):
    fake = FakeDeps()
    summary = await fresh_topup.run(
        _args("--languages", "cs", "--dry-run"), fake.deps(), TODAY
    )
    assert fake.import_kwargs == [{"review_status": "auto", "execute": False}]
    entry = summary["languages"]["cs"]
    assert entry["generated"] == 3 and entry["approved"] == 1
    assert entry["dropped"] == {"no_source_url": 1, "wrong_language": 1}
    assert [q["source_url"] for q in entry["questions"]] == [
        "https://en.wikipedia.org/wiki/Good"
    ]
    # Generation spend is reported under a key Sentry does not scrub ("token").
    assert entry["cost"] == {
        "seeds_usd": 1.0,
        "model_usd": 4.0,
        "factcheck_search_usd": 0.0,
        "total_usd": 5.0,
    }
    assert not any("token" in key for key in entry["cost"])
    assert entry["page_check"]["page_ok"] == 1


@pytest.mark.asyncio
async def test_live_run_imports_with_execute(roles_ok):
    fake = FakeDeps()
    summary = await fresh_topup.run(_args("--languages", "en"), fake.deps(), TODAY)
    assert fake.import_kwargs[0]["execute"] is True
    # Live rows are listed too: the founder spot-checks what went live.
    assert [q["review_status"] for q in summary["languages"]["en"]["questions"]] == [
        "approved"
    ]
    assert fresh_report.summary_level(summary) == "info"


@pytest.mark.asyncio
async def test_compact_summary_block_lists_languages_then_questions(roles_ok):
    summary = await fresh_topup.run(
        _args("--languages", "en,cs", "--max-usd", "15", "--dry-run"),
        FakeDeps().deps(),
        TODAY,
    )
    summary["languages"]["cs"]["questions"][0]["question"] = "A | B\nC?"
    lines = fresh_report.compact_summary(summary).splitlines()
    assert lines[0] == fresh_report.SUMMARY_START
    assert lines[-1] == fresh_report.SUMMARY_END
    assert lines[1].startswith("fresh-topup 2026-W42 (dry run): 2 approved")
    assert lines[2] == (
        "en | done | seeds 1/1 (page ok 1, mismatch 0, unchecked 0) | "
        "generated 3: approved 1, pending 0, dropped 2 | $5.00"
    )
    assert lines[4] == "lang | status | question | answer | boost_until"
    # One line per question; a "|" or newline inside a text never breaks a row.
    assert lines[5].startswith("en | approved | In which 2026 film")
    assert lines[6] == "cs | approved | A / B C? | Dogtown | -"
    assert len(lines) == 8


@pytest.mark.asyncio
async def test_pending_rows_raise_the_summary_to_warning(roles_ok):
    summary = await fresh_topup.run(
        _args("--languages", "en"), FakeDeps(pending=1).deps(), TODAY
    )
    assert fresh_report.summary_level(summary) == "warning"
    assert any("pending" in w for w in fresh_report.warnings_for(summary))


def test_low_domestic_share_is_a_warning():
    summary = {
        "languages": {"sk": {"status": "done", "pending": 0, "domestic_share": 0.4}}
    }
    assert fresh_report.summary_level(summary) == "warning"


def _open(answer, *, type="text", options=None, lang="en") -> Question:
    q = _q(lang)
    q.type, q.correct_answer, q.possible_answers = type, answer, options
    return q


@pytest.mark.parametrize(
    "answer",
    [
        "Two",  # the en question the third dry run let through
        "2",
        "2.5 billion dollars",
        "1,200",
        "about 40 %",
        "twenty one",
        "dva filmy",
        "dvadsať",
        "päť",
        "miliarda",
        "dvě",
        "čtyřicet",
        "sto",
        "tisíc",
    ],
)
def test_open_numeric_answers_are_dropped_in_en_sk_cs(answer):
    """A voice player cannot reach "Two" by reasoning and speech-to-text mangles
    numbers, so the brief allows numbers only as multiple choice; this is the
    deterministic backstop for when the generator and gates miss it."""
    kept, dropped = post_filter([_open(answer)], "en")
    assert kept == [] and dropped == {"numeric_open": 1}


def test_numeric_options_in_multiple_choice_are_kept():
    q = _open("b", type="text_multichoice", options={"a": "One", "b": "Two", "c": "3"})
    kept, dropped = post_filter([q], "en")
    assert kept == [q] and dropped == {}


@pytest.mark.parametrize(
    "answer",
    [
        "Albuquerque",
        "Star Wars: The Force Awakens",
        "Penelope",
        "21 Jump Street",
        "Two and a Half Men",
        "Apollo 13",
        "2026 Emmys",
        "Woodstock 1969",
    ],
)
def test_names_and_titles_that_contain_numbers_are_kept(answer):
    """The filter targets quantities, not any answer with a digit or number word:
    wrongly cutting a title would silently thin the weekly top-up."""
    kept, dropped = post_filter([_open(answer)], "en")
    assert len(kept) == 1 and dropped == {}


def test_post_filter_drops_rows_without_source_or_in_another_language():
    kept, dropped = post_filter([_q("sk"), _q("sk", source=""), _q("en")], "sk")
    assert len(kept) == 1 and dropped == {"no_source_url": 1, "wrong_language": 1}


class _NoDuplicates:
    async def find_duplicates(self, question_text, threshold=0.85):
        return []


@pytest.mark.parametrize(
    ("lang", "answerer"), [("en", "claude-haiku-5-5"), ("cs", "claude-sonnet-5-5")]
)
def test_stage_wiring_is_pinned_and_never_persists(monkeypatch, lang, answerer):
    monkeypatch.setenv("TAVILY_API_KEY", "tvly-test")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.delenv("ANSWERABILITY_CHECK", raising=False)
    monkeypatch.setenv("GENERATION_MODEL", "some-prod-model")
    monkeypatch.setattr(llm_factory, "GEN_ALT_SHARE", 1.0)
    stages = build_fresh_stages(lang, _NoDuplicates())
    assert not any(isinstance(s, PersistStage) for s in stages)
    gen = next(s for s in stages if isinstance(s, GenerationStage))
    assert gen._generator.generation_model == "claude-opus-5-5"
    assert gen._shape_classifier._model == answerer
    assert (
        next(s for s in stages if isinstance(s, AnswerabilityStage))._checker._model
        == answerer
    )
    assert (
        next(s for s in stages if isinstance(s, ScoringStage))._scorer is None
    )  # judges off
    assert next(s for s in stages if isinstance(s, TopUpStage))._floor_fraction == 0


def test_cron_checkin_only_when_asked(monkeypatch):
    sent = []
    monkeypatch.setattr(
        fresh_report, "capture_checkin", lambda **kw: sent.append(kw) or "id-1"
    )
    assert fresh_report.checkin_start(False) is None
    fresh_report.checkin_finish(None, ok=False)
    assert sent == []
    check_in = fresh_report.checkin_start(True)
    fresh_report.checkin_finish(check_in, ok=False)
    assert [kw["status"] for kw in sent] == ["in_progress", "error"]
    assert sent[0]["monitor_slug"] == "fresh-topup"


def test_main_prints_json_and_fails_when_a_language_failed(
    monkeypatch, roles_ok, capsys
):
    """A failed language must fail the process (the workflow keys on the exit
    code) and still send the summary and close the cron check-in as error."""
    import json

    events = []
    monkeypatch.setattr(
        fresh_report, "checkin_start", lambda enabled: "id" if enabled else None
    )
    monkeypatch.setattr(
        fresh_report, "checkin_finish", lambda cid, ok: events.append((cid, ok))
    )
    monkeypatch.setattr(
        fresh_report, "send_summary", lambda s: events.append("summary")
    )
    fake = FakeDeps()

    async def no_seeds(lang, today):
        return SeedResult(error="seed call ended 'refusal'", cost_cents=50)

    fake.research_seeds = no_seeds
    code = fresh_topup.main(["--languages", "sk", "--cron-checkin"], deps=fake.deps())
    stdout = capsys.readouterr().out
    # The compact block comes first (survives a truncated log), then the JSON.
    _, rest = stdout.split(fresh_report.SUMMARY_START)
    block, json_part = rest.split(fresh_report.SUMMARY_END)
    summary = json.loads(json_part.strip())
    assert "sk | failed | seed call ended 'refusal'" in block
    assert code == 1
    assert summary["languages"]["sk"]["status"] == "failed"
    assert summary["spent_usd"] == 0.5  # a refused call still costs
    assert events == ["summary", ("id", False)]
