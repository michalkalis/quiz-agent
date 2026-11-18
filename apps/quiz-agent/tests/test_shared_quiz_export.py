"""#232: shared quizzes in the GDPR data export.

Why: a share carries the sender's name and score, and a result carries a
player's name and score, both shown to other people — personal data the
export must list, including what was done before sign-in. A friend's result on
the person's share is the friend's data and must not leak into it.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest

from app.db.models import SharedQuiz, SharedQuizResult

from tests.test_auth_me_endpoints import (
    _asgi,
    _auth,
    _make_account,
    _make_app,
    _seed_anon_upgraded,
)

pytestmark = pytest.mark.asyncio


def _share(sender, token, name):
    return SharedQuiz(
        id=uuid.uuid4(),
        token=token,
        kind="round",
        language="sk",
        question_ids=["q1", "q2", "q3"],
        sender_subject_id=sender,
        sender_name=name,
        sender_score=2.0,
        sender_total=3,
        created_at=datetime.now(timezone.utc),
    )


def _result(share, subject, name, score):
    now = datetime.now(timezone.utc)
    return SharedQuizResult(
        id=uuid.uuid4(),
        shared_quiz_id=share.id,
        subject_id=subject,
        display_name=name,
        score=score,
        total=3,
        started_at=now,
        finished_at=now,
    )


async def test_export_lists_own_shares_and_own_results_only(db_sessionmaker):
    app = _make_app(db_sessionmaker)
    user_id, bearer = await _make_account(db_sessionmaker, apple_sub="a.shareexp")
    anon = await _seed_anon_upgraded(db_sessionmaker, user_id)
    mine = _share(user_id, "tok-mine-1", "Mia")
    friends = _share("friend", "tok-friend-1", "Ben")
    async with db_sessionmaker() as s:
        s.add_all([mine, friends])
        await s.flush()
        s.add_all(
            [
                # Played before sign-in, under the linked anon id.
                _result(friends, anon, "Mia", 1.0),
                # A friend's result on my share: theirs, not mine.
                _result(mine, "friend", "Ben", 3.0),
            ]
        )
        await s.commit()

    async with _asgi(app) as c:
        resp = await c.get("/api/v1/auth/me/export", headers=_auth(bearer))

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert [
        (q["token"], q["display_name"], q["score"], q["question_count"])
        for q in body["shared_quizzes"]
    ] == [("tok-mine-1", "Mia", 2.0, 3)]
    assert [(r["display_name"], r["score"]) for r in body["shared_quiz_results"]] == [
        ("Mia", 1.0)
    ]
