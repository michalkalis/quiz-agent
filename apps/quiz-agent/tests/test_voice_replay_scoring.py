"""scripts/voice_replay.py — the scoring math and the replayed decision (#197).

WHY: the replay report is what decides whether an STT/parser/grader model
change ships (#196 steps 3–5). If the math silently counts the wrong thing —
an app-side network error as a grader miss, an unlabeled sample as accuracy
against nothing, a right answer marked wrong not surfaced — the report would
green-light a regression. No network: STT is the sidecar transcript and the
LLM parser is a mock that must not even be called on the MCQ fast path.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from unittest.mock import AsyncMock

import pytest

ROOT = Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location(
    "voice_replay", ROOT / "scripts" / "voice_replay.py"
)
voice_replay = importlib.util.module_from_spec(_spec)
sys.modules["voice_replay"] = voice_replay
_spec.loader.exec_module(voice_replay)

Sample, Replay, summarize = (
    voice_replay.Sample,
    voice_replay.Replay,
    voice_replay.summarize,
)


def _replay(decision, *, app=None, label=None, prod="", heard="", error=None):
    sidecar = {"appDecision": app, "transcript": prod}
    sample = Sample(id="s", wav_path=Path("s.wav"), sidecar=sidecar, label=label)
    return Replay(sample, heard, decision, error=error)


def test_label_overrides_app_decision_and_counts_correct_marked_wrong():
    """The founder labels the cases the app got wrong; from then on the label,
    not the app's original call, is the truth the replay is graded against."""
    s = summarize(
        [
            _replay("incorrect", app="incorrect", label={"decision": "correct"}),
            _replay("correct", app="correct"),
            _replay("correct", app="incorrect"),
        ]
    )
    assert (s.scored, s.matches) == (3, 1)
    assert s.accuracy == pytest.approx(1 / 3)
    assert s.correct_marked_wrong == 1, "labeled-correct answer replayed as incorrect"
    assert s.wrong_marked_correct == 1


def test_samples_without_a_verdict_never_count_toward_accuracy():
    """An answer that hit a network error, or a recording with no decision at
    all, says nothing about the grader — counting it would skew accuracy."""
    s = summarize(
        [
            _replay("correct", app="error"),
            _replay("correct", app=None),
            _replay("", app="correct", error="error: timeout"),
            _replay("skipped", app="skipped"),
        ]
    )
    assert (s.total, s.scored, s.matches) == (4, 1, 1)
    assert s.correct_marked_wrong == 0, "a replay error is not a grader miss"


def test_wer_is_split_between_label_and_prod_transcripts():
    s = summarize(
        [
            _replay(
                "correct",
                app="correct",
                label={"transcript": "mount everest"},
                prod="mount everest",
                heard="mount everest",
            ),
            _replay("correct", app="correct", prod="paris", heard="london"),
        ]
    )
    assert s.wer_vs_label == [0.0]
    assert s.wer_vs_prod == [0.0, 1.0]


@pytest.mark.asyncio
async def test_spoken_option_label_is_graded_without_the_llm():
    """'C' on an MCQ resolves through match_option, exactly like /voice/submit —
    the replay must not spend an LLM call (or diverge) on it."""
    question = voice_replay.question_from_sidecar(
        {
            "questionId": "q1",
            "questionText": "Ktorá planéta je najväčšia?",
            "options": {"a": "Mars", "b": "Venuša", "c": "Jupiter", "d": "Zem"},
            "correctAnswer": "Jupiter",
        }
    )
    parser = AsyncMock()
    from app.evaluation.evaluator import AnswerEvaluator

    evaluator = AnswerEvaluator.__new__(
        AnswerEvaluator
    )  # no client: MCQ never reaches the LLM
    assert await voice_replay.decide("C", question, parser, evaluator) == "correct"
    assert await voice_replay.decide("A", question, parser, evaluator) == "incorrect"
    parser.parse.assert_not_called()


@pytest.mark.asyncio
async def test_unusable_transcript_maps_to_the_apps_no_speech_decision():
    question = voice_replay.question_from_sidecar(
        {"questionText": "Q?", "correctAnswer": "Paris"}
    )
    assert (
        await voice_replay.decide("", question, AsyncMock(), None)
        == "not_captured:no_speech"
    )
    assert (
        await voice_replay.decide("uh", question, AsyncMock(), None, valid=False)
        == "not_captured:no_speech"
    )


def test_sidecar_without_question_context_is_not_replayable():
    assert voice_replay.question_from_sidecar({"language": "sk"}) is None
