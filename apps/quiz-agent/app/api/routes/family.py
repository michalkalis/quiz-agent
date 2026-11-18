"""#236 — family mode „S deťmi“: the topics a parent can pick per age band.

``GET /api/v1/family/topics?language=sk`` lists, per band, the catalog topics
(``app/family/topics.py``) that have at least one whole round of playable
questions in that language for the caller's build channel (``X-Build-Channel``
as at session creation). Not in ``/app-config``: that body is cached per
User-Agent and differs neither by language nor by channel. With the switch off
for the channel the list is empty, so the app shows no mode.
"""

from __future__ import annotations

from typing import List

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel

from ...config import get_settings
from ...family.rounds import build_channel, family_mode_on, topic_counts
from ...family.topics import catalog_bands
from ...retrieval.question_retriever import QuestionRetriever
from ..deps import get_auth_sessionmaker, get_question_retriever

router = APIRouter()


class FamilyTopic(BaseModel):
    key: str
    name: str
    round_size: int


class FamilyBand(BaseModel):
    # Plain text, not an enum: a fourth band later must not break the
    # compatibility gate (a new response enum value fails it).
    band: str
    topics: List[FamilyTopic]


class FamilyTopicsResponse(BaseModel):
    bands: List[FamilyBand]


@router.get("/family/topics", response_model=FamilyTopicsResponse)
async def family_topics(
    request: Request,
    language: str = "en",
    question_retriever: QuestionRetriever = Depends(get_question_retriever),
    sessionmaker=Depends(get_auth_sessionmaker),
) -> FamilyTopicsResponse:
    channel = build_channel(request.headers)
    if not await family_mode_on(get_settings(), sessionmaker, channel):
        return FamilyTopicsResponse(bands=[])
    language = language.strip().lower()
    counts = await topic_counts(question_retriever, language, channel)
    return FamilyTopicsResponse(bands=catalog_bands(language, counts))
