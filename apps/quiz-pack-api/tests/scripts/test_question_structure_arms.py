"""Question-structure rule (founder 2026-09-21) — the blind-test arms.

The corpus prompt must carry the rule for every target language, the rewrite
arm must change nothing but the question, and the sampler must actually pick
the rows the rule targets (English question word buried mid-sentence) plus a
few controls it should leave alone.
"""

from __future__ import annotations

import pytest
from scripts.question_structure_arms import (
    arm_item,
    buries_question_word,
    select_sample,
)
from scripts.translation_runner import rewrite
from scripts.translation_runner import translate as tr

_ROW = {
    "id": "q1",
    "question": "Beachgoers in 1975 grew wary of the water thanks to which thriller?",
    "possible_answers": None,
    "correct_answer": "Jaws",
    "alternative_answers": [],
    "explanation": "e",
    "headline_answer": None,
    "category": "film",
    "difficulty": "medium",
    "source_url": "https://example.org",
}


class TestCorpusPromptCarriesTheRule:
    @pytest.mark.parametrize("language,name", [("sk", "Slovak"), ("cs", "Czech")])
    def test_rule_names_the_target_language_grammar(self, language, name):
        prompt = tr.build_prompt(_ROW, language)
        assert f"Question structure ({name} grammar" in prompt
        assert "never end on a bare fragment" in prompt

    def test_prompt_version_bumped_so_provenance_tells_old_rows_apart(self):
        assert tr.PROMPT_VERSION == "corpus-v2"

    def test_rewrite_prompt_shares_the_same_rule_text(self):
        prompt = rewrite.build_prompt("Q?", {"question": "Ot?"}, "sk")
        assert tr.QUESTION_STRUCTURE_RULE.format(language="Slovak") in prompt
        assert "return it unchanged" in prompt


class TestRewriteParser:
    def test_accepts_fenced_json(self):
        assert rewrite.parse_question('```json\n{"question": "Ktorý?"}\n```') == "Ktorý?"

    def test_empty_question_is_a_failure_not_a_blank_arm(self):
        with pytest.raises(ValueError):
            rewrite.parse_question('{"question": ""}')


class TestBuriedQuestionWord:
    @pytest.mark.parametrize(
        "question",
        [
            "Beachgoers in 1975 grew wary of the water thanks to which thriller?",
            "The word 'robot' comes from a word meaning forced labour in which language?",
        ],
    )
    def test_mid_sentence_interrogative_is_buried(self, question):
        assert buries_question_word(question)

    @pytest.mark.parametrize(
        "question",
        [
            "Which drink formed the main part of their rations?",
            "The shark had a nickname on set. What was the shark called?",
            "Pyramid builders were paid workers. In which city were they housed?",
        ],
    )
    def test_leading_interrogative_is_clean(self, question):
        assert not buries_question_word(question)


class TestSampler:
    @staticmethod
    def _rows():
        buried = [
            {"src_question": f"Fact {i} thanks to which thing?", "src_category": f"c{i % 3}"}
            for i in range(9)
        ]
        clean = [{"src_question": f"What is {i}?", "src_category": "c9"} for i in range(4)]
        return buried + clean

    def test_mostly_buried_rows_plus_the_requested_controls(self):
        sample = select_sample(self._rows(), n=8, seed=1, controls=3)
        buckets = [b for b, _ in sample]
        assert buckets.count("buried") == 5 and buckets.count("control") == 3

    def test_buried_rows_spread_across_categories(self):
        sample = select_sample(self._rows(), n=6, seed=1, controls=0)
        assert {r["src_category"] for _, r in sample} == {"c0", "c1", "c2"}

    def test_same_seed_same_sample(self):
        a = select_sample(self._rows(), n=6, seed=7, controls=2)
        b = select_sample(self._rows(), n=6, seed=7, controls=2)
        assert [r["src_question"] for _, r in a] == [r["src_question"] for _, r in b]


def test_arm_item_never_names_the_arm_and_keeps_the_rater_context():
    item = arm_item(_ROW, {**_ROW, "question": "Ktorý thriller?"})
    assert item["question"] == "Ktorý thriller?"
    assert item["topic"] == "film" and item["source_url"] == _ROW["source_url"]
    assert "arm" not in item and "bucket" not in item
