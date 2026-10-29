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
    at: datetime = Field(..., description="When the server received it")
    result: Optional[str] = Field(None, description="Set when the question closes")
    points: float = 0.0


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


class RoomGame(BaseModel):
    reveal_mode: Literal["question", "round"] = "question"
    thinking_seconds: int = 10
    # #213.8: the host's phone reads the questions aloud (shown to guests).
    reads_aloud: bool = True
    finished_reason: Optional[str] = None
    rounds: List[RoomRound] = Field(default_factory=list)

    @property
    def current(self) -> Optional[RoomRound]:
        return self.rounds[-1] if self.rounds else None
