"""TestFlight review badge + pre-translated serving (#176).

Two things must hold together, and they pull in opposite directions:

  1. A TestFlight session has to see MORE than before — a badge saying how this
     exact text was vouched for, and the machine-*rejected* translations that
     were previously invisible in the game, so the founder meets a broken
     translation while playing instead of only on the rating web.
  2. An App Store session must see EXACTLY what it saw before — no badge keys on
     the wire and never a rejected row — because #176 ships to production while
     the corpus cutover (#168 T23) is still founder-gated.

The badge is a claim about *provenance*, so every test below pins which state a
given corpus/gate combination produces: a wrong badge is worse than none, it
would tell the founder a machine draft was human-approved.
"""

import os
import sys

import pytest

sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "../../../..", "packages/shared")
)

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from app.review_badge import badge_for  # noqa: E402
from app.serializers import (  # noqa: E402
    translated_question_payload,
    translated_question_view,
)
from app.stored_translation import servable_statuses  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

STEM = "What is the capital city of France?"
STEM_SK = "Aké je hlavné mesto Francúzska?"


def question(review_status: str = "approved", qid: str = "q1") -> Question:
    return Question(
        id=qid,
        question=STEM,
        type="text",
        correct_answer="Paris",
        alternative_answers=["paris"],
        topic="Geography",
        category="general",
        difficulty="easy",
        review_status=review_status,
    )


def stored_row(
    qid: str = "q1",
    *,
    status: str = "approved",
    verification: dict | None = None,
) -> dict:
    return {
        "question_id": qid,
        "language": "sk",
        "status": status,
        "question": STEM_SK,
        "possible_answers": None,
        "explanation": None,
        "headline_answer": "Paríž",
        "correct_answer": "Paríž",
        "correct_answer_key": None,
        "alternative_answers": ["parizu"],
        "verification": verification or {},
    }


class FakeStore:
    """Records what the serve path asked the store for, and answers with rows."""

    def __init__(self, rows: dict | None = None):
        self.rows = rows or {}
        self.calls: list[tuple] = []

    async def get_translations(self, question_ids, language, statuses=("approved",)):
        self.calls.append((tuple(question_ids), language, tuple(statuses)))
        return {
            qid: row
            for qid, row in self.rows.items()
            if qid in question_ids and row["status"] in statuses
        }


class ExplodingTranslator:
    """The serve-time LLM path must not run when a stored row exists."""

    async def translate_question_payload(self, *args, **kwargs):  # pragma: no cover
        raise AssertionError("serve-time translation ran despite a stored row")


async def payload(question_obj, *, build_channel, store=None, language="sk"):
    return await translated_question_payload(
        question_obj,
        language,
        ExplodingTranslator() if store else None,
        session_id="s1",
        question_store=store,
        build_channel=build_channel,
    )


# ── Badge states ─────────────────────────────────────────────────────────────


def test_english_approved_question_is_badged_approved():
    """`approved` is the state, not the approver (founder 2026-09-10): a row the
    machine gates cleared reads the same as one the founder rated."""
    assert badge_for(question("approved"), None, "en") == ("approved", None)


def test_english_unreviewed_question_is_badged_pending_review():
    """`pending_review` is the one state an App Store client can never be served,
    so in TestFlight it has to be visible — it marks the questions the founder is
    field-testing rather than shipping."""
    assert badge_for(question("pending_review"), None, "en") == ("pending_review", None)


def test_clean_approved_translation_is_badged_machine_not_approved():
    """A gate-approved translation is NOT the same claim as an approved question:
    no human has read the Slovak text. Collapsing it into `approved` would hide
    exactly the distinction the founder asked for."""
    badge, note = badge_for(
        question("approved"),
        {"language": "sk", "review_badge": "translation_machine", "review_note": None},
        "sk",
    )
    assert (badge, note) == ("translation_machine", None)


def test_translation_with_judge_findings_is_flagged_and_carries_the_note():
    """The judge's finding is the whole reason a flagged badge is worth showing —
    without the note the founder sees a colour and has to go look it up."""
    record = {
        "language": "sk",
        "review_badge": "translation_flagged",
        "review_note": "Number changed from 12 to 21.",
    }
    assert badge_for(question("approved"), record, "sk") == (
        "translation_flagged",
        "Number changed from 12 to 21.",
    )


def test_rejected_translation_outranks_an_unreviewed_question():
    """Priority exists so one question shows one badge. A broken translation is
    the more urgent fact than an unreviewed English source, so `pending_review`
    must not mask a critical."""
    record = {
        "language": "sk",
        "review_badge": "translation_critical",
        "review_note": "answerability: translation_flip",
    }
    badge, note = badge_for(question("pending_review"), record, "sk")
    assert badge == "translation_critical"
    assert note == "answerability: translation_flip"


def test_unreviewed_question_outranks_a_clean_machine_translation():
    """The inverse ordering: a perfectly translated but unvouched question is
    still unvouched, and that is what the founder needs to know first."""
    record = {"language": "sk", "review_badge": "translation_machine"}
    assert badge_for(question("pending_review"), record, "sk")[0] == "pending_review"


def test_live_translation_without_a_stored_row_is_badged_translation_live():
    """The serve-time LLM path produces text no gate has ever seen. Until the
    #168 cutover completes it is still reachable, and it must not be able to
    borrow the credibility of a gated row."""
    record = {"language": "sk"}  # a live record carries no badge key
    assert badge_for(question("approved"), record, "sk")[0] == "translation_live"


def test_no_translation_at_all_is_badged_en_fallback():
    """A Slovak session reading English is a content gap, not a translation
    state — the badge has to say so rather than silently look approved."""
    assert badge_for(question("approved"), None, "sk")[0] == "en_fallback"


# ── Wire fields per build channel ────────────────────────────────────────────


@pytest.mark.asyncio
async def test_testflight_payload_carries_the_badge_fields():
    """The three fields are the entire iOS-visible contract of #176."""
    store = FakeStore({"q1": stored_row()})
    wire, record = await payload(question(), build_channel="testflight", store=store)
    assert wire["review_badge"] == "translation_machine"
    assert wire["translation_language"] == "sk"
    assert wire["question"] == STEM_SK
    assert record["question"] == STEM_SK


@pytest.mark.asyncio
async def test_app_store_payload_has_no_badge_fields_at_all():
    """Absent keys, not null ones: iOS decodes by key presence, and an App Store
    build shipped before #176 must decode this payload unchanged."""
    store = FakeStore({"q1": stored_row()})
    wire, _ = await payload(question(), build_channel=None, store=store)
    assert "review_badge" not in wire
    assert "translation_language" not in wire
    assert "review_note" not in wire


@pytest.mark.asyncio
async def test_review_note_is_omitted_when_there_is_nothing_to_explain():
    """A note on a clean row would be noise on every question in the quiz."""
    store = FakeStore({"q1": stored_row()})
    wire, _ = await payload(question(), build_channel="testflight", store=store)
    assert "review_note" not in wire


# ── Which rows each channel may be served ────────────────────────────────────


def test_app_store_asks_only_for_approved_rows():
    """The status filter is the enforcement point — a rejected translation must
    be impossible to reach for a paying client, not merely unlikely."""
    assert servable_statuses(None) == ("approved",)
    assert servable_statuses("app_store") == ("approved",)


def test_testflight_also_asks_for_rejected_rows():
    assert servable_statuses("testflight") == ("approved", "rejected")


@pytest.mark.asyncio
async def test_testflight_serves_a_rejected_translation_badged_critical():
    """The point of #176 decision 2: the founder has to meet the machine's
    refusals in the game, where a leaked answer or an unanswerable question is
    obvious, instead of only in a review export."""
    row = stored_row(
        status="rejected",
        verification={
            "judge": {
                "verdict": "defects",
                "findings": [{"severity": "critical", "note": "Answer leaked."}],
            }
        },
    )
    store = FakeStore({"q1": row})
    wire, _ = await payload(question(), build_channel="testflight", store=store)
    assert wire["question"] == STEM_SK
    assert wire["review_badge"] == "translation_critical"
    assert wire["review_note"] == "Answer leaked."


@pytest.mark.asyncio
async def test_app_store_never_receives_a_rejected_translation():
    """Same corpus row, other channel: the store is asked for approved only, so
    the session falls back rather than showing refused text."""
    store = FakeStore({"q1": stored_row(status="rejected")})
    wire, record = await payload(question(), build_channel=None, store=store)
    assert store.calls == [(("q1",), "sk", ("approved",))]
    assert record is None
    assert wire["question"] == STEM  # the English source, not the refused Slovak


# ── The stored row is the primary path, live translation the fallback ────────


@pytest.mark.asyncio
async def test_a_stored_row_replaces_the_serve_time_llm_call():
    """Cost and trust in one assertion: a gated row means no LLM call at request
    time (`ExplodingTranslator` raises if one is made) and the text the player
    reads is the text the gate judged."""
    store = FakeStore({"q1": stored_row()})
    wire, record = await payload(question(), build_channel="testflight", store=store)
    assert wire["question"] == STEM_SK
    assert record["alternative_answers"] == ["parizu"]


@pytest.mark.asyncio
async def test_no_stored_row_falls_back_to_the_live_translation_path():
    """The cutover is incomplete, so the old path must still run — losing it
    would leave a Slovak session reading English for most of the corpus."""
    store = FakeStore({})
    wire, record = await payload(
        question(), build_channel="testflight", store=store, language="sk"
    )
    # No translator is wired in this call, so the live path yields no record and
    # the English source is served — badged as the gap it is.
    assert record is None
    assert wire["question"] == STEM
    assert wire["review_badge"] == "en_fallback"


@pytest.mark.asyncio
async def test_english_session_never_queries_the_translation_store():
    """An English session has no translation dimension; a lookup would be a
    wasted query on the hot path for every question served."""
    store = FakeStore({"q1": stored_row()})
    wire, record = await payload(
        question(), build_channel="testflight", store=store, language="en"
    )
    assert store.calls == []
    assert record is None
    assert wire["question"] == STEM
    assert wire["review_badge"] == "approved"


def test_translated_alternates_reach_the_graded_question():
    """#168 C1/DD5: the evaluator matches free text against the alternates, so a
    Slovak answer graded against English alternates would be marked wrong. Only a
    stored row carries them — a live record must leave the English ones alone."""
    stored = {
        "question": STEM_SK,
        "correct_answer": "Paríž",
        "correct_answer_key": None,
        "alternative_answers": ["parizu"],
    }
    assert translated_question_view(question(), stored).alternative_answers == [
        "parizu"
    ]

    live = {"question": STEM_SK, "correct_answer": "Paríž", "correct_answer_key": None}
    assert translated_question_view(question(), live).alternative_answers == ["paris"]
