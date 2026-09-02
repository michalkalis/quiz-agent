"""Tests for the #168 arm-test script (T3, DD8).

Why these matter:
- The founder's model-per-language verdict is only worth something if all four
  arms were judged on the *same*, *representative* sample. A draw that lets one
  category dominate measures the corpus, not the translator — so the spread and
  the determinism of `sample_questions` are load-bearing, not cosmetic.
- The arm files feed `build_page.blind_question` unchanged. A renamed key there
  silently blanks a field on the rating page, and the founder rates a question
  with no options as if the translator had dropped them.
- Parsing is the only place a model's chatter becomes data; accepting a payload
  that lost `correct_answer` would put an ungradeable row in front of a rater.
"""

from __future__ import annotations

import os

import pytest
from scripts.rating_page.build_page import blind_question
from scripts.translate_arms import DIFFICULTIES, sample_questions, to_arm_item
from scripts.translate_arms_backends import build_prompt, parse_translation

CATS = ("science-nature", "history", "geography-world", "movies-music", "sports", "food-everyday")


def _corpus(per_cell: int = 5) -> list[dict]:
    return [
        {
            "id": f"{cat}-{diff}-{i}",
            "category": cat,
            "difficulty": diff,
            "question": "q",
            "topic": "t",
            "source_url": "http://example.test/x",
        }
        for cat in CATS
        for diff in DIFFICULTIES
        for i in range(per_cell)
    ]


def test_importing_the_script_does_not_repoint_the_llm_gateway():
    """conftest pins LLM_GATEWAY=direct so every provider mock in this suite
    intercepts the canonical endpoints. This script needs `openrouter`, but if
    it claimed it at import time the pin would be silently overwritten for the
    rest of the session and the fail-safe tests would start reaching the real
    network. The gateway is therefore set inside `main()`, not on import."""
    assert os.environ["LLM_GATEWAY"] == "direct"


class TestSampling:
    def test_spreads_across_every_cell_rather_than_clustering(self):
        """35 rows drawn round-robin from 18 cells must touch all 18 — a plain
        shuffle can hand the founder a sample that is mostly one category."""
        picked = sample_questions(_corpus(), count=35, seed=168)
        cells = {(q["category"], q["difficulty"]) for q in picked}
        assert len(picked) == 35
        assert len(cells) == 18
        # No cell may run away with the draw.
        counts = [sum(1 for q in picked if (q["category"], q["difficulty"]) == c) for c in cells]
        assert max(counts) - min(counts) <= 1

    def test_same_seed_same_sample(self):
        """Session B re-publishes and Session F re-uses this sample; a drifting
        draw would silently compare arms against different questions."""
        a = sample_questions(_corpus(), count=20, seed=7)
        b = sample_questions(_corpus(), count=20, seed=7)
        assert [q["id"] for q in a] == [q["id"] for q in b]

    def test_different_seed_different_sample(self):
        a = sample_questions(_corpus(), count=20, seed=7)
        b = sample_questions(_corpus(), count=20, seed=8)
        assert [q["id"] for q in a] != [q["id"] for q in b]

    def test_thin_corpus_returns_what_exists_without_duplicating(self):
        """The runner turns a short draw into a loud failure; the sampler must
        not pad it by handing the same question back twice."""
        picked = sample_questions(_corpus(per_cell=1), count=100, seed=1)
        assert len(picked) == 18
        assert len({q["id"] for q in picked}) == 18

    def test_free_form_categories_still_count_as_eligible(self):
        """Legacy rows outside the 6-category taxonomy are approved corpus too;
        dropping them would shrink an already-thin sample."""
        corpus = _corpus(per_cell=1) + [
            {"id": "legacy-1", "category": "trivia", "difficulty": "easy", "question": "q"}
        ]
        picked = sample_questions(corpus, count=19, seed=3)
        assert "legacy-1" in {q["id"] for q in picked}


class TestArmItemShape:
    def test_survives_build_page_blinding_with_every_field_intact(self):
        """`blind_question` is what the rating page renders; the arm file has to
        speak its key names or fields silently vanish from the founder's view."""
        source = {
            "id": "abc",
            "topic": "Astronomy",
            "difficulty": "medium",
            "source_url": "http://example.test/x",
        }
        translated = {
            "question": "Ktorá planéta je najväčšia?",
            "possible_answers": {"A": "Zem", "B": "Jupiter"},
            "correct_answer": "Jupiter",
            "alternative_answers": ["jupiter"],
            "explanation": "Jupiter je najväčšia planéta.",
        }

        blinded = blind_question(to_arm_item(source, translated), "b1")

        assert blinded["question"] == translated["question"]
        assert blinded["options"] == translated["possible_answers"]
        assert blinded["correct_answer"] == "Jupiter"
        assert blinded["alternative_answers"] == ["jupiter"]
        assert blinded["explanation"] == translated["explanation"]
        # Metadata is deliberately NOT translated, so all arms show the same one.
        assert blinded["topic"] == "Astronomy"
        assert blinded["difficulty"] == "medium"

    def test_no_arm_field_leaks_into_the_rater_payload(self):
        """Blinding is structural (DD8): an `arm` key here would 422 on the
        ratings API at best, and unblind the founder at worst."""
        item = to_arm_item({"id": "abc"}, {"question": "q", "correct_answer": "a"})
        assert "arm" not in item
        assert "model" not in item


class TestPromptAndParsing:
    def test_prompt_carries_the_language_and_the_source_payload(self):
        prompt = build_prompt({"question": "Who wrote Hamlet?", "correct_answer": "Shakespeare"}, "sk")
        assert "Slovak" in prompt
        assert "Who wrote Hamlet?" in prompt

    def test_prompt_does_not_leak_untranslatable_metadata(self):
        """Only the player-facing payload is translated; feeding the model the
        source_url invites it to 'translate' a URL."""
        prompt = build_prompt(
            {"question": "q", "source_url": "http://example.test/leak", "topic": "T"}, "cs"
        )
        assert "example.test/leak" not in prompt

    def test_parses_a_fenced_json_reply(self):
        data = parse_translation(
            '```json\n{"question": "Kto?", "possible_answers": null, '
            '"correct_answer": "X", "alternative_answers": [], "explanation": "E"}\n```'
        )
        assert data["question"] == "Kto?"
        assert data["correct_answer"] == "X"

    def test_payload_missing_a_required_field_fails_loud(self):
        """A row without correct_answer cannot be graded or rated — better no
        row than a broken one in the batch."""
        with pytest.raises(ValueError, match="missing"):
            parse_translation('{"question": "Kto?"}')

    def test_non_json_reply_fails_loud(self):
        with pytest.raises(ValueError, match="no JSON object"):
            parse_translation("Sure! Here is the translation.")
