"""Per-source parsers for the #156 ratings backfill.

What is actually at stake:

- *Silent loss*: these are hand-written markdown and hand-recovered JSON files.
  A parser that quietly matches 9 of 10 rows produces a calibration set that
  looks complete and is not, so every "shape I did not expect" case here
  asserts a raised `ParseError` rather than a smaller result.
- *Wrong attribution*: the pilot and Phase A rounds are blind tests. A rating
  stored against the wrong question or the wrong arm does not just lose a data
  point — it inverts the per-arm conclusion drawn from the round.
- *Model self-ratings*: the gold library mixes founder scores with `auto`
  ones. Importing the auto rows would pollute exactly the human/model
  correlation the store exists to measure.

Fixtures are inline snippets of each format, never the real data files: the
real files are the *input to a one-off run*, and pinning tests to them would
mean the suite breaks when a historical round is archived.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import backfill_ratings_parsers as P


# --------------------------------------------------------------------------
# Gold library
# --------------------------------------------------------------------------

GOLD_ENTRIES = [
    {
        "question": "Which spice was traded for Manhattan?",
        "answer": "Nutmeg",
        "why_excellent": "Surprising link.",
        "human_rating": 9,
        "rated_by": "michal",
        "topic": "history",
        "generator": "claude",
    },
    {
        "question": "What colour is a polar bear's skin?",
        "answer": "Black",
        "human_rating": 7,
        "rated_by": "auto",
        "topic": "nature",
    },
    {
        "question": "Which planet has the shortest day?",
        "answer": "Jupiter",
        "human_rating": 6,
        "rated_by": "anna",
        "topic": "space",
    },
]


def _gold(tmp_path: Path, entries: list[dict]) -> Path:
    p = tmp_path / "gold_standard.json"
    p.write_text(json.dumps(entries))
    return p


class TestGoldLibrary:
    def test_auto_rows_are_not_ratings(self, tmp_path):
        result = P.parse_gold_library(_gold(tmp_path, GOLD_ENTRIES))
        assert result.seen == 3
        assert result.skipped == 1
        assert [r.rater for r in result.rows] == ["michal", "anna"]
        assert any("auto" in a for a in result.anomalies)

    def test_rows_keep_their_own_rater_and_scale(self, tmp_path):
        rows = P.parse_gold_library(_gold(tmp_path, GOLD_ENTRIES)).rows
        assert (rows[0].score, rows[0].scale_min, rows[0].scale_max) == (9.0, 1, 10)
        assert rows[0].reason == "Surprising link."
        assert rows[0].extra["generator"] == "claude"

    def test_dedupe_key_is_stable_across_runs(self, tmp_path):
        first = P.parse_gold_library(_gold(tmp_path, GOLD_ENTRIES)).rows[0]
        second = P.parse_gold_library(_gold(tmp_path, GOLD_ENTRIES)).rows[0]
        assert first.dedupe_key == second.dedupe_key
        assert first.dedupe_key.startswith("backfill:gold-library:")
        assert first.dedupe_key.endswith(":michal")

    def test_human_row_without_a_score_is_an_error(self, tmp_path):
        broken = [{"question": "Q?", "rated_by": "michal"}]
        with pytest.raises(P.ParseError):
            P.parse_gold_library(_gold(tmp_path, broken))

    def test_duplicate_question_text_would_collide_so_it_raises(self, tmp_path):
        dupe = [GOLD_ENTRIES[0], dict(GOLD_ENTRIES[0])]
        with pytest.raises(P.ParseError):
            P.parse_gold_library(_gold(tmp_path, dupe))


# --------------------------------------------------------------------------
# Pilot 2026-07-11
# --------------------------------------------------------------------------

PILOT_RATINGS = """# Founder ratings — pilot

Model key: A = moonshotai/kimi-k2.6 · B = z-ai/glm-5.2 · C = google/gemini-3.1-pro-preview

## Round 2 (2026-07-12) — 1 more

| # | Orig ID | Model | Rating | Notes |
|---|---|---|---|---|
| R2-Q1 | B10 | B | 4.5 | Surprising, interesting |

## Round 2 summary

- B: avg 4.5

| # | Orig ID | Model | Rating | Notes |
|---|---|---|---|---|
| Q1 | A12 | A | 5 | Very interesting |
| Q2 | C3 | C | 3 | Too guessable |
"""

PILOT_REVIEW = """# Model pilot — blind review

## Model A

**A12. [text_multichoice]** Name the pop superstar whose surname came from fans?
   - Answer: **Bruno Mars**

## Model B

**B10. [text]** What outdoor hobby was flagged as unsettling?
   - Answer: **Bird watching**

## Model C

**C3. [text_multichoice]** Which is closer to Point Nemo, land or the ISS?
   - Answer: **b) ISS**
"""


def _pilot(tmp_path: Path, ratings: str = PILOT_RATINGS, review: str = PILOT_REVIEW):
    a, b = tmp_path / "founder_ratings.md", tmp_path / "pilot_review.md"
    a.write_text(ratings)
    b.write_text(review)
    return a, b


class TestPilot:
    def test_both_round_tables_are_read(self, tmp_path):
        result = P.parse_pilot(*_pilot(tmp_path))
        assert [r.natural_key for r in result.rows] == ["B10", "A12", "C3"]
        assert result.seen == 3

    def test_round_two_rows_carry_the_round_two_date(self, tmp_path):
        rows = {r.natural_key: r for r in P.parse_pilot(*_pilot(tmp_path)).rows}
        assert rows["B10"].rated_at.date().isoformat() == "2026-07-12"
        assert rows["A12"].rated_at.date().isoformat() == "2026-07-11"

    def test_blind_letter_is_resolved_to_the_model_it_stood_for(self, tmp_path):
        rows = {r.natural_key: r for r in P.parse_pilot(*_pilot(tmp_path)).rows}
        assert rows["B10"].extra["model"] == "z-ai/glm-5.2"
        assert rows["C3"].extra["model"] == "google/gemini-3.1-pro-preview"

    def test_question_text_comes_from_the_review_file(self, tmp_path):
        rows = {r.natural_key: r for r in P.parse_pilot(*_pilot(tmp_path)).rows}
        assert rows["A12"].question_text.startswith("Name the pop superstar")
        assert rows["B10"].score == 4.5
        assert rows["B10"].scale_max == 5

    def test_unknown_orig_id_means_the_files_drifted_apart(self, tmp_path):
        review = PILOT_REVIEW.replace("**A12.", "**A13.")
        with pytest.raises(P.ParseError):
            P.parse_pilot(*_pilot(tmp_path, review=review))

    def test_model_letter_contradicting_the_id_is_an_error(self, tmp_path):
        ratings = PILOT_RATINGS.replace("| A12 | A |", "| A12 | C |")
        with pytest.raises(P.ParseError):
            P.parse_pilot(*_pilot(tmp_path, ratings=ratings))

    def test_the_same_question_rated_twice_is_an_error(self, tmp_path):
        ratings = PILOT_RATINGS.replace("| C3 | C |", "| A12 | A |")
        with pytest.raises(P.ParseError):
            P.parse_pilot(*_pilot(tmp_path, ratings=ratings))


# --------------------------------------------------------------------------
# G3 corpus blind sample
# --------------------------------------------------------------------------


def _g3_doc(entries: list[tuple[str, str]]) -> str:
    """Build a sample doc: `entries` is [(score_text, note)] in question order."""
    blocks = [
        f"**{i}. [text] General** — Question number {i}?\n"
        f"   - Answer: **A{i}**\n"
        f"   - **Founder skóre: {score}** — {note}\n"
        for i, (score, note) in enumerate(entries, start=1)
    ]
    key = ["| # | Model | Zdroj (id / súbor) |", "|---|-------|------|"] + [
        f"| {i} | model-{i % 2} | `abc{i}…` — part0{i}.json#1 |"
        for i in range(1, len(entries) + 1)
    ]
    return "# Sample\n\n## Otázky\n\n" + "\n".join(blocks) + "\n## Answer key\n\n" + "\n".join(key) + "\n"


TEN_PLAIN = [("4/5", "fine")] * 10


def _g3(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "corpus-blind-sample.md"
    p.write_text(text)
    return p


class TestG3Sample:
    def test_inline_scores_and_the_answer_key_are_joined(self, tmp_path):
        result = P.parse_g3_sample(_g3(tmp_path, _g3_doc(TEN_PLAIN)))
        assert len(result.rows) == 10
        first = result.rows[0]
        assert first.natural_key == "q01"
        assert (first.score, first.scale_max) == (4.0, 5)
        assert first.extra["model"] == "model-1"
        assert first.reason == "fine"

    def test_comma_decimal_is_a_half_point(self, tmp_path):
        entries = list(TEN_PLAIN)
        entries[8] = ("3,5/5", "well phrased?")
        rows = P.parse_g3_sample(_g3(tmp_path, _g3_doc(entries))).rows
        assert rows[8].score == 3.5

    def test_approximate_score_is_imported_and_flagged(self, tmp_path):
        entries = list(TEN_PLAIN)
        entries[4] = ("~4/5 (fun)", "roughly")
        result = P.parse_g3_sample(_g3(tmp_path, _g3_doc(entries)))
        assert result.rows[4].score == 4.0
        assert result.rows[4].extra["approximate"] is True
        assert any("approximate" in a for a in result.anomalies)

    def test_split_score_becomes_the_mean_with_both_halves_kept(self, tmp_path):
        # The founder rated idea and format separately once. Picking one half
        # would invent a verdict; dropping the row would lose a rated question.
        entries = list(TEN_PLAIN)
        entries[5] = ("kreativita 5/5, formát 3/5", "idea good, hint gives it away")
        result = P.parse_g3_sample(_g3(tmp_path, _g3_doc(entries)))
        assert result.rows[5].score == 4.0
        assert result.rows[5].extra["score_components"] == [5.0, 3.0]
        assert any("split score" in a for a in result.anomalies)

    def test_a_missing_question_means_the_sample_is_not_the_one_rated(self, tmp_path):
        with pytest.raises(P.ParseError):
            P.parse_g3_sample(_g3(tmp_path, _g3_doc(TEN_PLAIN[:9])))

    def test_a_question_without_a_score_line_raises(self, tmp_path):
        doc = _g3_doc(TEN_PLAIN).replace("   - **Founder skóre: 4/5** — fine\n", "", 1)
        with pytest.raises(P.ParseError):
            P.parse_g3_sample(_g3(tmp_path, doc))


# --------------------------------------------------------------------------
# #153 baseline — order join, text-verified
# --------------------------------------------------------------------------

BASELINE_QUESTIONS = [
    {"id": "11111111-1111-1111-1111-111111111111",
     "question": "About how much data can the human brain store — roughly what?"},
    {"id": "22222222-2222-2222-2222-222222222222",
     "question": "How did pioneering bandleader James Reese Europe die in the war?"},
    {"id": "33333333-3333-3333-3333-333333333333",
     "question": "Which jazz saxophonist had a church named in his honor?"},
]

BASELINE_RATINGS = {
    "batch": "Bedrock 2026-08-07",
    "ratings": [
        {"n": 1, "q": "How much data can the human brain store", "score": 9,
         "note": "zaujimave", "reason": "velmi zaujimave", "topic": "brain"},
        {"n": 2, "q": "Reese Europe bandleader died in the war", "score": 3,
         "note": "", "reason": "nepoznam"},
        {"n": 3, "q": "Coltrane (DUPLIKAT)", "score": 5, "reason": "duplikat"},
    ],
}


def _baseline(tmp_path: Path, ratings: dict, questions: list[dict]):
    a, b = tmp_path / "founder-ratings.json", tmp_path / "questions.json"
    a.write_text(json.dumps(ratings))
    b.write_text(json.dumps(questions))
    return a, b


class TestBaseline:
    def test_order_join_attaches_the_question_uuid(self, tmp_path):
        result = P.parse_baseline(*_baseline(tmp_path, BASELINE_RATINGS, BASELINE_QUESTIONS))
        first = result.rows[0]
        assert first.question_id == BASELINE_QUESTIONS[0]["id"]
        assert first.question_text == BASELINE_QUESTIONS[0]["question"]
        assert first.natural_key == "n01"

    def test_a_shorthand_that_does_not_match_is_reported_not_attached(self, tmp_path):
        # n=3's shorthand shares no content word with the question at that
        # position. Attaching a UUID on position alone would silently bind the
        # founder's score to a question they may not have been looking at.
        result = P.parse_baseline(*_baseline(tmp_path, BASELINE_RATINGS, BASELINE_QUESTIONS))
        third = result.rows[2]
        assert result.unjoinable == 1
        assert third.question_id is None
        assert third.question_text == "Coltrane (DUPLIKAT)"
        assert third.extra["joined"] is False
        assert any("unjoinable" in a for a in result.anomalies)

    def test_unrated_rows_are_skipped_not_stored_as_zero(self, tmp_path):
        payload = {"batch": "b", "ratings": [
            {"n": 1, "q": "brain data store", "score": None, "note": "neohodnotena"}]}
        result = P.parse_baseline(*_baseline(tmp_path, payload, BASELINE_QUESTIONS))
        assert (result.rows, result.skipped) == ([], 1)

    def test_an_index_past_the_question_list_means_the_join_is_broken(self, tmp_path):
        payload = {"ratings": [{"n": 9, "q": "brain data store", "score": 5}]}
        with pytest.raises(P.ParseError):
            P.parse_baseline(*_baseline(tmp_path, payload, BASELINE_QUESTIONS))


# --------------------------------------------------------------------------
# #153 Phase A — blinded qid → arm + UUID
# --------------------------------------------------------------------------

PHASE_A_MAPPING = {
    "q01": {"arm": "craft", "original_id": "141ac8e6-1f20-4d5d-9cd6-4388b4e10463",
            "topic": "Chess", "question": "Chess games or atoms: which is more?"},
    "q02": {"arm": "old", "original_id": "2ac4e0ee-511a-4ad2-8840-9490f0f610c7",
            "topic": "Board games", "question": "Royal Game of Ur or the Roman Empire?"},
}

PHASE_A_RATINGS = {
    "batch_id": "153-phase-a",
    "ratings": [
        {"id": "q01", "arm": "craft", "score": 6, "reason": "predvidatelne"},
        {"id": "q02", "arm": "old", "score": None, "reason": "uz som hodnotil"},
    ],
}


def _phase_a(tmp_path: Path, ratings: dict, mapping: dict):
    a, b = tmp_path / "founder-ratings-full.json", tmp_path / "mapping.json"
    a.write_text(json.dumps(ratings))
    b.write_text(json.dumps(mapping))
    return a, b


class TestPhaseA:
    def test_blinded_qid_is_deblinded_to_arm_and_uuid(self, tmp_path):
        result = P.parse_phase_a(*_phase_a(tmp_path, PHASE_A_RATINGS, PHASE_A_MAPPING))
        row = result.rows[0]
        assert row.question_id == PHASE_A_MAPPING["q01"]["original_id"]
        assert row.blinded_qid == "q01"
        assert row.extra["arm"] == "craft"
        assert row.question_text == PHASE_A_MAPPING["q01"]["question"]
        assert result.skipped == 1

    def test_an_arm_that_contradicts_the_mapping_voids_the_round(self, tmp_path):
        # Both files claim to know the arm. If they disagree, every per-arm
        # number from this round is suspect — refuse rather than pick one.
        ratings = json.loads(json.dumps(PHASE_A_RATINGS))
        ratings["ratings"][0]["arm"] = "free"
        with pytest.raises(P.ParseError):
            P.parse_phase_a(*_phase_a(tmp_path, ratings, PHASE_A_MAPPING))

    def test_a_rating_with_no_mapping_entry_raises(self, tmp_path):
        ratings = {"ratings": [{"id": "q99", "score": 5}]}
        with pytest.raises(P.ParseError):
            P.parse_phase_a(*_phase_a(tmp_path, ratings, PHASE_A_MAPPING))


class TestSimilarity:
    def test_paraphrase_still_counts_as_the_same_question(self, tmp_path):
        assert P.similarity(
            "Nokia originally made what (paper)",
            "The telecommunications company Nokia originally made what product?",
        ) >= P.BASELINE_MIN_SIMILARITY

    def test_an_unrelated_question_falls_below_the_threshold(self, tmp_path):
        assert P.similarity(
            "Coltrane (DUPLIKAT)", "Which planet has the shortest day?"
        ) < P.BASELINE_MIN_SIMILARITY
