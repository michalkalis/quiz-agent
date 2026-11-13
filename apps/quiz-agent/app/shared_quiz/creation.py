"""Creating a share (#232): the question list is built by the server from
the sender's own finished session (or owned finished pack), never from ids
the app sends; see ``snapshot`` for which rows may travel."""

from __future__ import annotations

from datetime import date
from typing import Optional

from quiz_shared.models.phase import SessionPhase
from quiz_shared.models.session import QuizSession

from ..db.models import SharedQuiz
from . import snapshot


class ShareError(Exception):
    """``status`` is the HTTP status the route answers with; ``code`` a stable
    machine-readable reason the app can branch on."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def player_score(session: QuizSession, subject_id: str) -> float:
    player = next(
        (p for p in session.participants if p.user_id == subject_id), None
    ) or (session.participants[0] if session.participants else None)
    return float(player.score) if player else 0.0


class ShareCreation:
    """``SharedQuizService``'s create half (needs its store, sessions,
    retriever, daily and ``_emit``)."""

    async def create(
        self,
        subject_id: str,
        *,
        session_id: Optional[str] = None,
        pack_id: Optional[str] = None,
        name: Optional[str] = None,
    ) -> SharedQuiz:
        if session_id:
            share = await self._from_session(subject_id, session_id, name)
        elif pack_id:
            share = await self._from_pack(subject_id, pack_id, name)
        else:
            raise ShareError(422, "nothing_to_share", "session_id or pack_id needed")
        return share

    async def _from_session(
        self, subject_id: str, session_id: str, name: Optional[str]
    ) -> SharedQuiz:
        session = await self.sessions.get_session(session_id)
        if session is None or session.user_id != subject_id:
            raise ShareError(404, "not_found", "Session not found or expired")
        if session.shared_quiz_id and not session.daily_challenge_date:
            # Forwarding a quiz a friend sent: the same link, never a new one.
            share = await self.store.by_id(session.shared_quiz_id)
            if share is not None:
                return share
        if session.phase != SessionPhase.FINISHED:
            raise ShareError(409, "not_finished", "Only a finished quiz can be shared")
        found = await self.store.existing(
            subject_id, session_id=session_id, pack_id=None
        )
        if found is not None:
            return found
        title, challenge_date = None, None
        if session.pack_id:
            kind = "pack"
            pack = await self._finished_pack(session.pack_id, subject_id)
            title = pack["name"]
            ids = await snapshot.pack_ids(
                self.retriever, session.pack_id, session.asked_question_ids
            )
        elif session.daily_challenge_date and self.daily is not None:
            kind = "daily"
            challenge_date = date.fromisoformat(session.daily_challenge_date)
            day_set = await self.daily.question_ids(session.language, challenge_date)
            ids = await snapshot.corpus_ids(self.retriever, day_set, session.language)
        else:
            kind = "round"
            ids = await snapshot.corpus_ids(
                self.retriever, session.asked_question_ids, session.language
            )
        return await self._insert(
            subject_id,
            kind=kind,
            language=session.language,
            question_ids=ids,
            pack_id=session.pack_id,
            challenge_date=challenge_date,
            title=title,
            topic=",".join(session.preferred_categories) or None,
            source_session_id=session_id,
            sender_name=name,
            sender_score=player_score(session, subject_id),
            sender_total=len(session.asked_question_ids),
        )

    async def _from_pack(
        self, subject_id: str, pack_id: str, name: Optional[str]
    ) -> SharedQuiz:
        pack = await self._finished_pack(pack_id, subject_id)
        found = await self.store.existing(subject_id, session_id=None, pack_id=pack_id)
        if found is not None:
            return found
        return await self._insert(
            subject_id,
            kind="pack",
            language=pack["language"],
            question_ids=await snapshot.pack_ids(self.retriever, pack_id),
            pack_id=pack_id,
            title=pack["name"],
            sender_name=name,
        )

    async def _finished_pack(self, pack_id: str, subject_id: str) -> dict:
        """Only the owner shares a pack (404 otherwise, like the session gate),
        and only once it is complete."""
        pack = await self.store.owned_pack(pack_id, subject_id)
        if pack is None:
            raise ShareError(404, "not_found", "Pack not found")
        if pack["status"] != "complete":
            raise ShareError(409, "pack_not_finished", "The pack is not finished yet")
        return pack

    async def _insert(self, subject_id: str, **fields) -> SharedQuiz:
        if not fields["question_ids"]:
            raise ShareError(409, "nothing_to_share", "No question can be shared")
        share = await self.store.insert(sender_subject_id=subject_id, **fields)
        self._emit(
            "quiz_shared",
            subject_id,
            None,
            kind=share.kind,
            language=share.language,
            question_count=len(share.question_ids),
        )
        return share
