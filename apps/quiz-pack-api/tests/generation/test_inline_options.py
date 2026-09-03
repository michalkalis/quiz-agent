"""Inline-option normaliser tests (founder blind rating 2026-09-03).

Why these scenarios:

- The positive stems are the VERBATIM defects the founder found in the
  2026-09-02 corpus batch (docs/testing/runs/corpus-session-2026-09-02):
  free-text questions that spoke their own option list, which is what made
  them ungradable by voice and invisible to the iOS option picker. If a
  refactor stops recognising one of these shapes the defect ships again.
- The negatives are the batch's genuine free-text questions. A detector that
  fires on a plain "or" mid-sentence would shred good questions into
  two-option MCQs whose "distractor" is a fragment of the stem — the failure
  mode that matters far more than a missed conversion.
- The unmatched case pins "never guess": an answer that fits no single option
  leaves the question exactly as generated. Converting on a guess ships a
  question whose marked-correct option is wrong.
- Thousands separators get their own test because a naive comma split turns
  "1,400 years" into two phantom options and then matches the answer against
  one of them.
"""

from __future__ import annotations

import pytest

from app.generation.inline_options import (
    Counts,
    apply_to_questions,
    find_option_clause,
    match_option,
    normalise,
)
from quiz_shared.models.question import Question


def _question(**overrides) -> Question:
    base = dict(
        id="q1",
        question="stub?",
        correct_answer="answer",
        topic="General",
        category="general",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


class TestClauseDetector:
    @pytest.mark.parametrize(
        ("stem", "expected_options", "expected_stem"),
        [
            (
                "The Great Pyramid of Giza was the tallest man-made structure "
                "on Earth for how long: closer to 400 years, 1,400 years, or "
                "3,800 years?",
                ["400 years", "1,400 years", "3,800 years"],
                "The Great Pyramid of Giza was the tallest man-made structure "
                "on Earth for how long?",
            ),
            (
                "How many bones are inside an elephant's trunk: closer to "
                "zero, 40, or 400?",
                ["Zero", "40", "400"],
                "How many bones are inside an elephant's trunk?",
            ),
            (
                "Papua New Guinea has more living languages than any other "
                "country on Earth. Is the number closer to 80, 800, or 8,000?",
                ["80", "800", "8,000"],
                "Papua New Guinea has more living languages than any other "
                "country on Earth. How many?",
            ),
            (
                "American Sign Language is closely related to one of these "
                "two, and almost unrelated to the other. Is it British Sign "
                "Language or French Sign Language?",
                ["British Sign Language", "French Sign Language"],
                "American Sign Language is closely related to one of these "
                "two, and almost unrelated to the other. Which is it?",
            ),
            (
                "One of these two has been on Earth far longer than the "
                "other: sharks or trees. Which came first?",
                ["Sharks", "Trees"],
                "One of these two has been on Earth far longer than the "
                "other. Which came first?",
            ),
        ],
    )
    def test_detects_and_rewrites_live_defect_stems(
        self, stem: str, expected_options: list[str], expected_stem: str
    ) -> None:
        clause = find_option_clause(stem)
        assert clause is not None
        assert clause.options == expected_options
        assert clause.stem == expected_stem

    @pytest.mark.parametrize(
        "stem",
        [
            # "or" mid-sentence in a genuine free-text question.
            "Passenger jets are pressurised, and their cabin windows are "
            "always oval or have rounded corners, never square like a house "
            "window. Why?",
            "In 1816, after the eruption of Mount Tambora ruined harvests "
            "across Europe, oats became so expensive that many horses were "
            "sold or slaughtered. What did a German inventor unveil the very "
            "next year as a horseless way to get around?",
            "The closest living relative of English is not German or Dutch. "
            "Name the language, spoken along the North Sea coast, that holds "
            "that title.",
            # A colon introducing a statement, not an option list.
            "True or false: millions of years ago, the Amazon River flowed "
            "westward, in the opposite direction to today.",
            # An enumeration with no alternation is a list of subjects, not
            # a set of answers to choose between.
            "Name the three primary colours: red, green, blue?",
        ],
    )
    def test_ignores_stems_without_an_option_enumeration(self, stem: str) -> None:
        assert find_option_clause(stem) is None

    def test_extracts_options_without_rewriting_an_unsafe_stem(self) -> None:
        # No deletion of this trailing clause leaves a grammatical question,
        # so the options are extracted and the stem is left alone.
        clause = find_option_clause(
            "The Arctic tern flies from the Arctic to the Antarctic and back "
            "every year. Over its roughly 30-year life, is its total distance "
            "closer to once around the Earth, once to the Moon, or three "
            "times to the Moon and back?"
        )
        assert clause is not None
        assert clause.stem is None
        assert clause.options == [
            "Once around the Earth",
            "Once to the Moon",
            "Three times to the Moon and back",
        ]


class TestAnswerMatching:
    def test_matches_answer_through_an_approximation_prefix(self) -> None:
        # The generator writes the bucket as "About 3,800 years" while the
        # stem lists "3,800 years" — the same option, spoken twice.
        options = ["400 years", "1,400 years", "3,800 years"]
        assert match_option("About 3,800 years", options) == 2

    def test_thousands_separator_is_not_a_list_separator(self) -> None:
        clause = find_option_clause("Is the number closer to 80, 800, or 8,000?")
        assert clause is not None
        assert clause.options == ["80", "800", "8,000"]
        # "80" must not match inside "800"/"8,000" — word boundaries only.
        assert match_option("About 800", clause.options) == 1

    def test_ambiguous_answer_matches_nothing(self) -> None:
        assert match_option("years", ["400 years", "1,400 years"]) is None

    def test_falls_back_to_alternative_answers(self) -> None:
        assert (
            match_option("Sharks came first", ["Sharks", "Trees"], ["Sharks"]) == 0
        )


class TestNormalise:
    def test_converts_free_text_with_inline_options(self) -> None:
        result = normalise(
            "How much does a single fluffy cumulus cloud weigh: closer to "
            "5 kilograms, 500 tonnes, or 5 million tonnes?",
            "text",
            "About 500 tonnes",
            None,
        )
        assert result is not None
        assert result.kind == "to_mcq"
        assert result.question == "How much does a single fluffy cumulus cloud weigh?"
        assert result.possible_answers == {
            "a": "5 kilograms",
            "b": "500 tonnes",
            "c": "5 million tonnes",
        }
        assert result.correct_answer == "500 tonnes"

    def test_unmatched_answer_leaves_the_question_untouched(self) -> None:
        result = normalise(
            "How heavy was the phone: closer to a chocolate bar, a bag of "
            "sugar, or a bowling ball?",
            "text",
            "Roughly one kilogram",
            None,
        )
        assert result is not None
        assert result.kind == "unmatched"
        assert result.question is None

    def test_strips_an_mcq_stem_that_recites_its_own_options(self) -> None:
        result = normalise(
            "One of these animals is not a rodent at all. Is it the beaver, "
            "the porcupine, the capybara, or the rabbit?",
            "text_multichoice",
            "Rabbit",
            {"a": "Beaver", "b": "Porcupine", "c": "Capybara", "d": "Rabbit"},
        )
        assert result is not None
        assert result.kind == "stem_stripped"
        assert result.question == (
            "One of these animals is not a rodent at all. Which is it?"
        )
        # The options themselves are never touched by a stem strip.
        assert result.possible_answers is None

    def test_leaves_a_two_option_mcq_stem_alone(self) -> None:
        # Stripping "Which is hotter: the surface of the Sun or a bolt of
        # lightning?" leaves a stem with nothing to compare.
        assert (
            normalise(
                "Which is hotter: the surface of the Sun or a bolt of lightning?",
                "text_multichoice",
                "A bolt of lightning",
                {"a": "The surface of the Sun", "b": "A bolt of lightning"},
            )
            is None
        )

    def test_leaves_an_mcq_whose_stem_lists_someone_elses_options(self) -> None:
        # The stem enumerates buckets that are not this question's options —
        # rewriting it would delete information the options do not carry.
        assert (
            normalise(
                "Was it closer to a day, a week, or a month?",
                "text_multichoice",
                "Six months",
                {"a": "Six months", "b": "A year", "c": "A decade"},
            )
            is None
        )


class TestApplyToQuestions:
    def test_counts_each_repair_kind(self) -> None:
        questions = [
            _question(
                id="conv",
                question="How fast does a large raindrop hit the ground: "
                "closer to walking speed, sprinting speed, or highway "
                "driving speed?",
                correct_answer="Sprinting speed",
            ),
            _question(
                id="strip",
                question="Which of these mammals is the only one that cannot "
                "inject venom: platypus, slow loris, shrew, or hedgehog?",
                type="text_multichoice",
                correct_answer="Hedgehog",
                possible_answers={
                    "a": "Platypus",
                    "b": "Slow loris",
                    "c": "Shrew",
                    "d": "Hedgehog",
                },
            ),
            _question(
                id="unmatched",
                question="One of these rodents is the largest. Is it a beaver "
                "or a porcupine?",
                correct_answer="A capybara",
            ),
            _question(id="clean", question="What is the capital of France?"),
        ]

        counts = apply_to_questions(questions)

        assert counts == Counts(
            inline_options_to_mcq=1,
            stem_options_stripped=2,
            inline_options_unmatched=1,
        )
        assert questions[0].type == "text_multichoice"
        assert questions[0].question == "How fast does a large raindrop hit the ground?"
        assert questions[0].correct_answer == "Sprinting speed"
        assert questions[1].question == (
            "Which of these mammals is the only one that cannot inject venom?"
        )
        assert questions[2].question == (
            "One of these rodents is the largest. Is it a beaver or a porcupine?"
        )
        assert questions[2].type == "text"
        assert questions[3].question == "What is the capital of France?"
