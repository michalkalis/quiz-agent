"""Game state of a same-room multiplayer session (#212.2).

Lives inside the quiz session (``QuizSession.room_game``), so the session's
lease and optimistic version cover every answer and every close. Internal
state: the room routes project it, never the solo session responses.
"""

from datetime import datetime
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, Field


class RoomAnswer(BaseModel):
    answer: str = Field(..., description="Option key or the typed text")
    at: datetime = Field(
        ...,
        description="When the server received it, on the round's clock: a host "
        "pause (#249.4) moves it on by the pause, so no speed counts a pause",
    )
    result: Optional[str] = Field(None, description="Set when the question closes")
    points: float = 0.0
    # #249.5: how the answer came in (analytics `route`): typed/tapped or a
    # recording the server transcribed.
    route: Literal["text", "voice"] = "text"


class RoomRound(BaseModel):
    """One question of the game, from serve to reveal."""

    question_id: str
    number: int = Field(..., description="1-based question number")
    question: Dict[str, Any] = Field(
        ..., description="The public payload every phone shows (no answer)"
    )
    is_open: bool = Field(..., description="Typed answer (no options)")
    served_at: datetime
    # The answer clock starts when the host's phone finished reading the
    # question aloud (POST /rooms/{id}/open), not when it was served.
    opened_at: Optional[datetime] = None
    answers: Dict[str, RoomAnswer] = Field(
        default_factory=dict, description="participant_id → answer"
    )
    closed: bool = False
    correct_answer: Optional[str] = None
    explanation: Optional[str] = None
    # #212.4: participants whose app went to the background while it was open.
    away: List[str] = Field(default_factory=list)
    # #213.8: the answer time fixed when served, so a change during the game
    # applies from the next question. None: served before it was stored.
    thinking_seconds: Optional[int] = None
    # #224.4: the host stays on this reveal; guests are told. Lives on the
    # round, so the next question starts unpaused without any reset code.
    paused: bool = False
    # #249.4: the host paused the open question (reading or answering). The
    # round's clock stands still at this instant: answers still come in, the
    # question never closes, and the resume moves the round's times on by
    # the pause (rounds.resume), so the time left is the same as before.
    paused_at: Optional[datetime] = None
    # The judge stayed down until the host moved on: the question counts for
    # nobody (founder 2026-11-18, #239).
    cancelled: bool = False
    # #249.5: recordings received in time and still being transcribed
    # (participant_id → when received, wall clock). The question does not
    # close on time while one is in, so transcription never makes it late.
    voice_pending: Dict[str, datetime] = Field(default_factory=dict)


class RoomGame(BaseModel):
    reveal_mode: Literal["question", "round"] = "question"
    thinking_seconds: int = 10
    # #213.8: the host's phone reads the questions aloud (shown to guests).
    reads_aloud: bool = True
    finished_reason: Optional[str] = None
    rounds: List[RoomRound] = Field(default_factory=list)
    # #240.9: a room moves to a new session (another game with the same
    # people, or other content in the lobby). Added to the session's version
    # so the version a phone polls with keeps growing across the move.
    version_base: int = 0
    # #240.9: this game is "play again" after a finished one in the same room.
    rematch: bool = False

    @property
    def current(self) -> Optional[RoomRound]:
        return self.rounds[-1] if self.rounds else None
