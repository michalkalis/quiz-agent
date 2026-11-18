"""Wire models of the daily challenge (#205). New fields only ride on new
endpoints or as optional fields, so the live 1.0 app is unaffected."""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, Field


class CrowdStrip(BaseModel):
    """The strip under the correct answer on the result card."""

    kind: Literal["first", "rare", "plain", "hard"] = Field(
        description="first = nobody else answered yet; rare/hard = at most 30 % "
        "of others knew (correct / wrong answer); plain = a common correct answer"
    )
    text: str = Field(description="Ready to show, in the session language")
    others: int = Field(description="Other players who answered this question today")
    knew: int = Field(description="How many of them knew it")


class DailyBestHit(BaseModel):
    question_id: str
    question: str
    answer: str
    rare: bool = Field(description="At most 30 % of others knew it")
    text: str = Field(description="Crowd line for it, e.g. 'Vedeli to len 2 z 9.'")


class DailySummary(BaseModel):
    """A finished challenge, computed live on every request."""

    score: int
    total: int
    marks: List[Optional[bool]] = Field(
        description="Per question in play order: knew it, missed it, or null if "
        "never answered"
    )
    players: int = Field(description="Players who finished today, the player included")
    comparison: Optional[str] = Field(
        default=None,
        description="'Dnes nikto nehral pred tebou.', the rank (top half only) or 'Ťažká výzva.'",
    )
    rank: Optional[str] = Field(
        default=None, description="The rank line, only in the top half (for sharing)"
    )
    best_hit: Optional[DailyBestHit] = Field(
        default=None, description="The rarest question the player knew, shown last"
    )


class DailyChallengeState(BaseModel):
    date: str = Field(description="The player's local date, YYYY-MM-DD")
    language: str
    status: Literal["not_played", "in_progress", "played"]
    total: int = Field(description="Questions in the challenge")
    summary: Optional[DailySummary] = None
