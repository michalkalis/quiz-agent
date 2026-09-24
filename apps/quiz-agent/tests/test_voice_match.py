"""#185 E: open answers are judged as voice transcripts from a car.

Founder car test 2026-09-23: the answer "curling" came back from Scribe (pinned
to Slovak) as "Paddling" and "Carling"; the judge only forgave "minor spelling"
and read "Carling" as a beer brand. Founder: rather lenient than needlessly
strict — accept what the player evidently SAID.

Two halves, pinned separately:
- a deterministic sound-alike check before the LLM. It may only ever ACCEPT, so
  the risk it carries is a false accept — two genuinely different answers that
  are close as strings. The negative table is the point of this file: every
  pair there is a real wrong answer that must still reach the judge.
- the judge prompt now says it reads a car voice transcript and must accept
  sound-alikes — but not a different plausible answer.
"""

from __future__ import annotations

import os

os.environ.setdefault("OPENAI_API_KEY", "sk-test")

from unittest.mock import AsyncMock, MagicMock  # noqa: E402

import pytest  # noqa: E402

from app.evaluation.evaluator import AnswerEvaluator  # noqa: E402
from app.evaluation.voice_match import sounds_like  # noqa: E402
from quiz_shared.models.question import Question  # noqa: E402

SOUND_ALIKES = [
    ("Carling", "curling"),  # the car-test transcript
    ("Karling", "curling"),  # the same, Slovak spelling
    ("Hungry", "Hungary"),
    ("Columbia", "Colombia"),
    ("Kuba", "Cuba"),
    ("Otava", "Ottawa"),
    ("Filip", "Philip"),
    ("Kenedy", "Kennedy"),
    ("Linkoln", "Lincoln"),
    ("Danmark", "Denmark"),
    ("George Vashington", "George Washington"),
]

# Close as strings, different answers. Each of these reaching "correct" without
# the judge would award a point for a wrong answer.
DIFFERENT_ANSWERS = [
    ("Manet", "Monet"),  # one vowel apart, different painter
    ("Iraq", "Iran"),
    ("Austria", "Australia"),
    ("Zambia", "Gambia"),
    ("Slovenia", "Slovakia"),
    ("Johnson", "Jackson"),
    ("Lennon", "Lenin"),
    ("Albany", "Albania"),  # the ending carries the meaning
    ("Guyana", "Guinea"),
    ("Bali", "Mali"),
    ("Henry VII", "Henry VIII"),  # numbers never bend
    ("Louis XVI", "Louis XIV"),
    ("1968", "1969"),
    ("Paddling", "curling"),  # the other car-test transcript: judge's call
    ("Carolina", "Caroline"),
    ("Vitamin Q", "Vitamin K"),  # letters carry no sound to be lenient about
]


@pytest.mark.parametrize("heard,expected", SOUND_ALIKES)
def test_sound_alikes_are_accepted(heard, expected):
    assert sounds_like(heard, expected)


@pytest.mark.parametrize("heard,expected", DIFFERENT_ANSWERS)
def test_different_answers_are_never_pre_accepted(heard, expected):
    assert not sounds_like(heard, expected)
    assert not sounds_like(expected, heard)


def _question(correct: str, **overrides) -> Question:
    base = dict(
        id="q_voice",
        question="Which winter sport uses stones and brooms?",
        type="text",
        correct_answer=correct,
        topic="Sport",
        category="sport",
        difficulty="medium",
    )
    base.update(overrides)
    return Question(**base)


def _llm_reply(verdict: str):
    message = MagicMock()
    message.content = verdict
    choice = MagicMock()
    choice.message = message
    response = MagicMock()
    response.choices = [choice]
    return response


class TestEvaluatorVoiceTolerance:
    @pytest.mark.asyncio
    async def test_carling_is_correct_without_asking_the_judge(self):
        """The exact car-test case: full credit, and no LLM call to get it wrong."""
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(
            side_effect=AssertionError("a clear sound-alike must not reach the judge")
        )

        result = await evaluator.evaluate("Carling", _question("curling"))

        assert result == ("correct", 1.0)

    @pytest.mark.asyncio
    async def test_alternative_answers_count_as_sound_alike_targets(self):
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(side_effect=AssertionError("no LLM"))

        q = _question("curling on ice", alternative_answers=["curling"])
        assert await evaluator.evaluate("Karling", q) == ("correct", 1.0)

    @pytest.mark.asyncio
    async def test_a_different_answer_still_goes_to_the_judge(self):
        """The pre-check never rejects: "Manet" for "Monet" is the judge's call,
        and the judge's verdict stands."""
        evaluator = AnswerEvaluator()
        evaluator._llm_evaluate = AsyncMock(return_value="incorrect")

        result = await evaluator.evaluate(
            "Manet", _question("Monet", question="Who painted Water Lilies?")
        )

        assert result == ("incorrect", 0.0)
        evaluator._llm_evaluate.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_judge_prompt_knows_it_reads_a_car_voice_transcript(self):
        """What reaches the judge must carry the voice context and both halves
        of the rule: accept sound-alikes, but not a different plausible answer
        or a different number."""
        evaluator = AnswerEvaluator()
        evaluator.client = MagicMock()
        evaluator.client.chat.completions.create = AsyncMock(
            return_value=_llm_reply("correct")
        )

        await evaluator.evaluate("Paddling", _question("curling"))

        prompt = evaluator.client.chat.completions.create.await_args.kwargs["messages"][
            1
        ]["content"]
        assert "speech-to-text transcript" in prompt
        assert "moving car" in prompt
        assert "SOUND like the correct answer" in prompt
        assert '"Carling" for "curling"' in prompt
        assert "Never accept a sound-alike that names a different answer" in prompt
        assert "must be the same number" in prompt
        assert "User's Answer (voice transcript): Paddling" in prompt
