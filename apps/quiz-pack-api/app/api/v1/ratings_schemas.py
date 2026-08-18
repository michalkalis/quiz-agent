"""Wire models for `/v1/ratings` (issue #154).

Split out of `ratings.py` to keep both files under the repo's ~300-line cap.
The interesting one is `BatchQuestion`: it is used as BOTH the request and the
response shape, which is what makes blinding structural — a field that is not
declared here cannot reach the rating page, whatever the batch row contains.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

# The rating scale the web page and the iOS panel (#155) use. Historical rounds
# on other scales enter through #156 backfill, which writes `scale_min`/
# `scale_max` directly instead of going through these routes.
SCORE_MIN = 1
SCORE_MAX = 10

# D21b editorial checklist (issue-164 follow-up): every web rater ticks these
# alongside the 1–10 score. Stored under `Rating.extra["flags"]` — no schema
# migration, the score column stays required.
RATING_FLAGS = ("fact_error", "logic_flaw", "stale", "duplicate")


class BatchQuestion(BaseModel):
    """The rater-visible shape of one question.

    `extra="forbid"` is the blinding guard: a batch built with an `arm` key
    accidentally left on a question is a 422 at registration time, not a leak
    discovered after the round has been rated.
    """

    model_config = ConfigDict(extra="forbid")

    qid: str
    question: str
    answer: Optional[Any] = None
    meta: Optional[dict[str, Any]] = None


class CreateBatchRequest(BaseModel):
    title: str
    questions: list[BatchQuestion] = Field(min_length=1)
    # Server-only: {qid: {arm, original_id, ...}}. Free-form on purpose — the
    # analysis side decides what provenance it needs.
    mapping: dict[str, Any] = Field(default_factory=dict)

    @field_validator("questions")
    @classmethod
    def _unique_qids(cls, v: list[BatchQuestion]) -> list[BatchQuestion]:
        qids = [q.qid.strip() for q in v]
        if any(not q for q in qids):
            raise ValueError("every question needs a non-blank qid")
        if len(set(qids)) != len(qids):
            raise ValueError("qids must be unique within a batch")
        return v


class CreateBatchResponse(BaseModel):
    batch_id: uuid.UUID
    rate_url_template: str


class SavedRating(BaseModel):
    score: float
    reason: Optional[str]
    rated_at: datetime
    flags: Optional[dict[str, bool]] = None


class BatchViewResponse(BaseModel):
    """Everything the rating page may see. Note the absence of `mapping`."""

    batch_id: uuid.UUID
    title: str
    count: int
    rater: Optional[str]
    questions: list[BatchQuestion]
    ratings: dict[str, SavedRating]


class WebRatingRequest(BaseModel):
    rater: str
    qid: str
    score: float = Field(ge=SCORE_MIN, le=SCORE_MAX)
    reason: Optional[str] = None
    # Omitted = leave stored flags untouched; {} = explicitly clear them.
    flags: Optional[dict[str, bool]] = None

    @field_validator("rater")
    @classmethod
    def _rater_not_blank(cls, v: str) -> str:
        rater = v.strip()
        if not rater:
            raise ValueError("rater must not be blank")
        return rater

    @field_validator("flags")
    @classmethod
    def _known_flags_only(
        cls, v: Optional[dict[str, bool]]
    ) -> Optional[dict[str, bool]]:
        if v is None:
            return v
        unknown = sorted(set(v) - set(RATING_FLAGS))
        if unknown:
            raise ValueError(f"unknown flags: {unknown}")
        return v


class InAppRatingRequest(BaseModel):
    question_id: str
    score: float = Field(ge=SCORE_MIN, le=SCORE_MAX)
    reason: Optional[str] = None
    # Cosmetic only: `rater` stays the JWT subject so a renamed rater keeps one
    # row instead of forking into two.
    display_name: Optional[str] = None


class RatingSavedResponse(BaseModel):
    rating_id: uuid.UUID
    rater: str
    score: float
    rated_at: datetime
