"""Typed payloads of the answer-submit response (#148 — typed submit contract).

``POST /sessions/{id}/input`` and ``POST /voice/submit/{id}`` return the money
path's payload: by the time it is built the question has been served, the
freemium quota charged and a verdict graded. Both halves used to be hand-built
``Dict[str, Any]`` — invisible to OpenAPI, to ``/verify-api`` and to the iOS
Codable diff, while iOS decoded them into a non-optional struct with a strict
enum (arch audit 2026-08-06). Typing them here is what lets the schema, the
contract test and the client diff see the same shape.

Both models mirror ``PublicQuestion``'s serializer convention: fixed keys always
present (null allowed), optional keys **omitted** when unset — iOS distinguishes
by key absence, not null, and the wire bytes must not change just because the
producer moved from a dict to a model.
"""

from typing import Optional

from typing_extensions import NotRequired, TypedDict
from pydantic import BaseModel, Field, model_serializer


class EvaluationWire(TypedDict):
    """Exact JSON wire shape of a graded verdict (iOS ``Evaluation`` mirrors it)."""

    user_answer: str
    result: str
    points: float
    correct_answer: str
    question_id: str
    headline_answer: NotRequired[str]
    explanation: NotRequired[str]


class Evaluation(BaseModel):
    """One graded answer, as the client receives it.

    ``result`` is deliberately a plain ``str``, not an enum: a verdict the
    backend has not seen before must not fail validation *here*, on the response
    of a submission the player was already charged for. Widening the verdict set
    is a client-side decode concern (iOS degrades unknown verdicts since #148)
    — the server's job is to hand back what it graded.
    """

    user_answer: str = Field(
        description="What the player answered; '' when speech carried no answer"
    )
    result: str = Field(
        description=(
            "Verdict: correct | incorrect | partially_correct | "
            "partially_incorrect | skipped"
        )
    )
    points: float = Field(description="Score delta applied for this answer")
    correct_answer: str = Field(
        description="The correct answer in the wording the player was served"
    )
    question_id: str = Field(description="The question this verdict grades")
    headline_answer: Optional[str] = Field(
        default=None,
        description="Short answer gist for open questions; omitted when absent",
    )
    explanation: Optional[str] = Field(
        default=None, description="Why that is the answer; omitted when absent"
    )

    @model_serializer(mode="plain")
    def _serialize_wire(self) -> EvaluationWire:
        wire: EvaluationWire = {
            "user_answer": self.user_answer,
            "result": self.result,
            "points": self.points,
            "correct_answer": self.correct_answer,
            "question_id": self.question_id,
        }
        if self.headline_answer:
            wire["headline_answer"] = self.headline_answer
        if self.explanation:
            wire["explanation"] = self.explanation
        return wire


class AudioInfoWire(TypedDict):
    """Exact JSON wire shape of the audio block (iOS ``AudioInfo`` mirrors it)."""

    format: str
    feedback_url: NotRequired[str]
    feedback_audio_base64: NotRequired[str]
    question_url: NotRequired[str]


class AudioInfo(BaseModel):
    """Audio the client may play for this response (``?audio=true`` only).

    Exactly one feedback carrier is set: freshly synthesized audio travels inline
    as ``feedback_audio_base64``, otherwise the client fetches the cache-backed
    ``feedback_url``. ``question_url`` points at the next question's audio.
    """

    format: str = Field(default="opus", description="Audio codec of every URL here")
    feedback_url: Optional[str] = Field(
        default=None, description="Cache-backed feedback audio endpoint"
    )
    feedback_audio_base64: Optional[str] = Field(
        default=None, description="Inline freshly synthesized feedback audio"
    )
    question_url: Optional[str] = Field(
        default=None, description="Audio endpoint for the question now current"
    )

    @model_serializer(mode="plain")
    def _serialize_wire(self) -> AudioInfoWire:
        wire: AudioInfoWire = {"format": self.format}
        if self.feedback_url:
            wire["feedback_url"] = self.feedback_url
        if self.feedback_audio_base64:
            wire["feedback_audio_base64"] = self.feedback_audio_base64
        if self.question_url:
            wire["question_url"] = self.question_url
        return wire
