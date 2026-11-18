"""#236 — family rounds („S deťmi“): the server switches, the checks at session
creation and the whole round picked at ``/start``.

Plan: docs/issues/issue-236-family-mode-build.md, increment S1. A family
round is an ordinary session with ``age_band`` set and one ``family-*`` topic
in ``preferred_categories``, so voice, grading, quota and restore after a
restart all run the normal path. The round is picked in full when it starts
and played through ``fixed_question_ids`` (like the daily challenge), so its
length is known and the "you played these before" note is known before the
first question.
"""

from __future__ import annotations

import random
import time
from typing import Optional

from fastapi import HTTPException

from .. import app_switches
from ..config import Settings
from .topics import ROUND_SIZE, is_band_topic

TOPIC_COUNTS_SECONDS = 300.0

_topic_counts: dict[tuple[str, Optional[str]], tuple[float, dict]] = {}


def reset_cache() -> None:
    _topic_counts.clear()


def build_channel(headers) -> Optional[str]:
    """Same whitelist as session creation: only the exact literal widens the
    pool to pending_review questions."""
    return "testflight" if headers.get("X-Build-Channel") == "testflight" else None


async def family_mode_on(
    settings: Settings, sessionmaker, channel: Optional[str]
) -> bool:
    """``family_mode_enabled`` turns the mode on for TestFlight builds; an App
    Store build also needs ``family_mode_enabled_app_store`` (the pattern of
    the game together, #217). Both are off unless switched on in the DB."""
    switches = app_switches.effective(
        settings, await app_switches.cached_overrides(sessionmaker)
    )
    if not switches["family_mode_enabled"]:
        return False
    return channel == "testflight" or bool(switches["family_mode_enabled_app_store"])


def _error(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status_code=status, detail={"code": code, "message": message})


async def check_family_request(
    body, channel: Optional[str], settings: Settings, sessionmaker
) -> str:
    """The topic key of a valid family session request, or the HTTP error.

    Switched off → 403 first, so a closed mode tells nothing about topics.
    A family round is solo play of the shared library: no pack, no room.
    """
    if not await family_mode_on(settings, sessionmaker, channel):
        raise _error(403, "family_disabled", "Family mode is not available")
    if body.pack_id or body.mode == "multiplayer":
        raise _error(
            400, "family_mode_conflict", "A family round is not a pack or a room"
        )
    categories = body.categories or []
    if len(categories) != 1 or not is_band_topic(body.age_band, categories[0]):
        raise _error(
            400, "family_topic_invalid", "Send exactly one topic of this age band"
        )
    return categories[0]


def pick_round(
    pool_ids: list[str], history: list[str], size: int
) -> tuple[list[str], bool]:
    """``size`` questions of the pool: never played ones first, in random
    order; then played ones in the order of ``history`` (the app's list,
    oldest first, a question played again moved to its end), so a fully
    played topic repeats what the family heard longest ago. Returns the
    round and whether it repeats anything."""
    position = {qid: i for i, qid in enumerate(history)}
    unplayed = [qid for qid in pool_ids if qid not in position]
    random.shuffle(unplayed)
    picked = unplayed[:size]
    if len(picked) == size:
        return picked, False
    played = sorted((qid for qid in pool_ids if qid in position), key=position.get)
    refill = played[: size - len(picked)]
    return picked + refill, bool(refill)


async def start_family_round(retriever, session, history: list[str]) -> bool:
    """Pick the whole round onto ``session`` (``fixed_question_ids``, and
    ``max_questions`` when the pool is thinner than a round); return whether
    it repeats played questions. An empty pool is the one 409."""
    pool = await retriever.band_pool_ids(session)
    ids, repeats = pick_round(pool, history, ROUND_SIZE[session.age_band])
    if not ids:
        raise _error(
            409, "family_topic_empty", "This topic has no questions in this language"
        )
    session.fixed_question_ids = ids
    session.max_questions = len(ids)
    return repeats


async def topic_counts(
    retriever, language: str, channel: Optional[str]
) -> dict[tuple[str, str], int]:
    """Playable band questions per (band, category) for one language and
    build channel, cached ~5 min. Independent of the player's history on
    purpose: a played topic stays playable by repeating, so the list only
    says "a whole round exists" and can be shared by everyone."""
    key = (language, channel)
    hit = _topic_counts.get(key)
    if hit is not None and hit[0] > time.monotonic():
        return hit[1]
    counts = await retriever.band_topic_counts(language, channel)
    _topic_counts[key] = (time.monotonic() + TOPIC_COUNTS_SECONDS, counts)
    return counts
