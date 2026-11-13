"""Share a quiz by link (#232 task 232.1): create, start, finish, rank.

A share is a fixed, ordered question list built by the server from the
sender's own session (or owned finished pack). A friend plays it as a new
session that is re-filtered with the friend's own serving rules, is exempt from
the free monthly quota, and records one result per person for the ranking.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date
from typing import Any, Optional, Sequence

from quiz_shared.models.session import QuizSession

from ..config import get_settings
from ..db.models import SharedQuiz
from ..retrieval.question_retriever import QuestionRetriever
from ..session.manager import SessionManager
from .creation import ShareCreation, ShareError, player_score
from .ranking import RankedPlayer, rank
from .store import SharedQuizStore

logger = logging.getLogger(__name__)

__all__ = ["SharedQuizService", "ShareError", "StartOutcome"]


@dataclass
class StartOutcome:
    share: SharedQuiz
    session: Optional[QuizSession]
    already_played: bool = False


class SharedQuizService(ShareCreation):
    def __init__(
        self,
        store: SharedQuizStore,
        sessions: SessionManager,
        retriever: QuestionRetriever,
        daily: Any = None,
        analytics: Any = None,
    ) -> None:
        self.store = store
        self.sessions = sessions
        self.retriever = retriever
        # #205 DailyChallengeService: a same-day daily link starts the friend's
        # own daily challenge. None = no database / switch off.
        self.daily = daily
        self.analytics = analytics

    # ── start ─────────────────────────────────────────────────────────────
    async def start(
        self,
        token: str,
        subject_id: str,
        *,
        day: Optional[date] = None,
        name: Optional[str] = None,
        build_channel: Optional[str] = None,
        capabilities: Sequence[str] = (),
    ) -> StartOutcome:
        share = await self.store.by_token(token)
        if share is None:
            raise ShareError(404, "not_found", "Shared quiz not found")
        is_sender = share.sender_subject_id in await self.store.person_ids(subject_id)
        self._emit(
            "shared_quiz_opened", subject_id, None, kind=share.kind, source="app"
        )
        probe = self._session(share, subject_id, build_channel, capabilities)
        if share.kind == "daily" and day is not None and day == share.challenge_date:
            outcome = await self._start_daily(share, subject_id, probe, is_sender, name)
            if outcome is not None:
                return outcome
        ids = [
            qid
            for qid in share.question_ids
            if await self.retriever.shared_question(probe, qid) is not None
        ]
        if not ids:
            raise ShareError(409, "nothing_playable", "No question can be played")
        if share.kind == "pack" and (
            is_sender
            or not await self.store.begin_play(share, subject_id, name, once=True)
        ):
            raise ShareError(
                409, "already_played", "This shared pack was played already"
            )
        if share.kind != "pack" and not is_sender:
            await self.store.begin_play(share, subject_id, name, once=False)
        return StartOutcome(share, await self._persist(probe, ids))

    async def _start_daily(
        self,
        share: SharedQuiz,
        subject_id: str,
        probe: QuizSession,
        is_sender: bool,
        name: Optional[str],
    ) -> Optional[StartOutcome]:
        """Same day: the friend's own daily challenge (same five questions, and
        it counts as their attempt). None → play it as a shared round."""
        if self.daily is None or not get_settings().daily_challenge_enabled:
            return None
        play, remaining = await self.daily.begin(
            subject_id, share.language, share.challenge_date
        )
        if play.language != share.language:
            return None  # today's attempt was in another language
        if not remaining:
            if not is_sender:
                await self._record(
                    share,
                    subject_id,
                    float(play.score or 0),
                    len(share.question_ids),
                    None,
                    name,
                )
            return StartOutcome(share, None, already_played=True)
        if not is_sender:
            await self.store.begin_play(share, subject_id, name, once=False)
        probe.daily_challenge_date = share.challenge_date.isoformat()
        session = await self._persist(probe, remaining)
        await self.daily.attach_session(play.id, session.session_id)
        return StartOutcome(share, session)

    @staticmethod
    def _session(
        share: SharedQuiz,
        subject_id: str,
        build_channel: Optional[str],
        capabilities: Sequence[str],
    ) -> QuizSession:
        return QuizSession(
            session_id="pending",
            user_id=subject_id,
            language=share.language,
            current_difficulty="random",
            build_channel=build_channel,
            client_capabilities=list(capabilities),
            shared_quiz_id=str(share.id),
            pack_id=str(share.pack_id) if share.kind == "pack" else None,
        )

    async def _persist(self, probe: QuizSession, ids: list[str]) -> QuizSession:
        session = await self.sessions.create_session(
            max_questions=len(ids), difficulty="random", user_id=probe.user_id
        )
        for field in (
            "language",
            "build_channel",
            "client_capabilities",
            "shared_quiz_id",
            "pack_id",
            "daily_challenge_date",
        ):
            setattr(session, field, getattr(probe, field))
        session.fixed_question_ids = ids
        await self.sessions.update_session(session)
        return session

    # ── read ──────────────────────────────────────────────────────────────
    async def by_token(self, token: str) -> SharedQuiz:
        share = await self.store.by_token(token)
        if share is None:
            raise ShareError(404, "not_found", "Shared quiz not found")
        return share

    async def preview(self, token: str) -> SharedQuiz:
        """The website's look at a link: what it is, never its questions."""
        share = await self.by_token(token)
        self._emit("shared_quiz_opened", None, None, kind=share.kind, source="web")
        return share

    async def ranking(
        self, token: str, subject_id: str
    ) -> tuple[SharedQuiz, list[RankedPlayer]]:
        share = await self.by_token(token)
        players = rank(
            share,
            await self.store.finished_results(share.id),
            await self.store.person_ids(share.sender_subject_id),
            await self.store.person_ids(subject_id),
        )
        return share, players

    # ── finish ────────────────────────────────────────────────────────────
    async def finish(self, session: QuizSession) -> None:
        """One result per person at the first finish. In a game together every
        player with an id gets theirs; the sender's own result is on the share."""
        if not session.shared_quiz_id:
            return
        share = await self.store.by_id(session.shared_quiz_id)
        if share is None:
            return
        sender = set(await self.store.person_ids(share.sender_subject_id))
        if session.is_multiplayer():
            players = [
                (p.user_id, p.score, p.display_name)
                for p in session.participants
                if p.user_id
            ]
        else:
            players = [(session.user_id, player_score(session, session.user_id), None)]
        total = len(session.asked_question_ids)
        recorded = 0
        for subject_id, score, name in players:
            if subject_id in sender:
                continue
            recorded += await self._record(
                share, subject_id, float(score), total, session.session_id, name
            )
        if recorded:
            self._emit(
                "shared_quiz_finished",
                session.user_id,
                session.session_id,
                kind=share.kind,
                players=recorded,
                questions_asked=total,
            )

    async def _record(self, share, subject_id, score, total, session_id, name) -> int:
        return int(
            await self.store.record_result(
                share.id,
                subject_id,
                score=score,
                total=total,
                session_id=session_id,
                name=name,
            )
        )

    def _emit(self, name: str, subject_id, session_id, **properties) -> None:
        if self.analytics is not None:
            self.analytics.emit(
                name,
                subject_id=subject_id,
                session_id=session_id,
                properties=properties,
            )
