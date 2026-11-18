"""Share a quiz by link (#232 task 232.1): create, start, finish, rank.

A share is a fixed, ordered question list built by the server from the
sender's own session (or owned finished pack). A friend plays it as a new
session that is re-filtered with the friend's own serving rules, is exempt from
the free monthly quota, and records one result per person for the ranking.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any, Optional, Sequence

from quiz_shared.models.session import QuizSession

from ..config import get_settings
from ..db.models import SharedQuiz
from ..retrieval.question_retriever import QuestionRetriever
from ..session.manager import SessionManager
from .creation import ShareCreation, ShareError, player_score
from .marks import aligned, known_in_session
from .ranking import RankedPlayer, rank
from .store import SharedQuizStore

logger = logging.getLogger(__name__)

__all__ = ["SharedQuizService", "ShareError", "StartOutcome"]


@dataclass
class StartOutcome:
    share: SharedQuiz
    session: Optional[QuizSession]
    already_played: bool = False


def _still_open(challenge_date: Optional[date]) -> bool:
    """A daily challenge date that is still playable somewhere: every time
    zone is within a day of UTC (the daily routes accept the same window)."""
    if challenge_date is None:
        return False
    today = datetime.now(timezone.utc).date()
    return abs(challenge_date - today) <= timedelta(days=1)


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
        name: Optional[str] = None,
        build_channel: Optional[str] = None,
        capabilities: Sequence[str] = (),
        daily_on: Optional[bool] = None,
    ) -> StartOutcome:
        """``daily_on``: whether this player gets the daily challenge (the
        route's beta gate, #239); None falls back to the server-wide switch."""
        share = await self.store.by_token(token)
        if share is None:
            raise ShareError(404, "not_found", "Shared quiz not found")
        is_sender = share.sender_subject_id in await self.store.person_ids(subject_id)
        self._emit(
            "shared_quiz_opened", subject_id, None, kind=share.kind, source="app"
        )
        probe = self._session(share, subject_id, build_channel, capabilities)
        if share.kind == "daily" and _still_open(share.challenge_date):
            outcome = await self._start_daily(
                share, subject_id, probe, is_sender, name, daily_on
            )
            if outcome is not None:
                return outcome
        ids = [
            qid
            for qid in share.question_ids
            if await self.retriever.shared_question(probe, qid) is not None
        ]
        if not ids:
            raise ShareError(409, "nothing_playable", "No question can be played")
        if share.kind == "pack":
            return StartOutcome(
                share, await self._start_pack(share, probe, ids, is_sender, name)
            )
        if not is_sender:
            await self.store.begin_play(share, subject_id, name, once=False)
        return StartOutcome(share, await self._persist(probe, ids))

    async def _start_pack(
        self,
        share: SharedQuiz,
        probe: QuizSession,
        ids: list[str],
        is_sender: bool,
        name: Optional[str],
    ) -> QuizSession:
        """Once per person per pack. The play is reserved only after the session
        exists, so a failed start never uses up the one play; a lost race
        removes the extra session again. A repeated start of this link before
        any answer moves the play to the new session (the app retried or lost
        the first answer)."""
        already = ShareError(
            409, "already_played", "This shared pack was played already"
        )
        if is_sender:
            raise already
        session = await self._persist(probe, ids)
        try:
            reserved = await self.store.begin_play(
                share, probe.user_id, name, once=True, session_id=session.session_id
            ) or await self._restart_unanswered(share, probe.user_id, session)
        except Exception:
            await self.sessions.delete_session(session.session_id)
            raise
        if not reserved:
            await self.sessions.delete_session(session.session_id)
            raise already
        return session

    async def _restart_unanswered(
        self, share: SharedQuiz, subject_id: str, session: QuizSession
    ) -> bool:
        """This person's play of this link, not answered yet, now runs in
        ``session``; the old session goes so one play stays one session."""
        old_id = await self.store.open_play(share, subject_id)
        if old_id is None:
            return False
        old = await self.sessions.get_session(old_id)
        if old is None or old.question_results:
            return False
        if not await self.store.move_play(share.id, old_id, session.session_id):
            return False
        await self.sessions.delete_session(old_id)
        return True

    async def _start_daily(
        self,
        share: SharedQuiz,
        subject_id: str,
        probe: QuizSession,
        is_sender: bool,
        name: Optional[str],
        daily_on: Optional[bool] = None,
    ) -> Optional[StartOutcome]:
        """A daily that can still be played: the friend's own daily challenge
        (same five questions, it counts as their attempt and in the crowd
        numbers). Decided by the server, never by a date the app sends, so
        today's questions are never replayed as a round next to the crowd.
        None → no daily challenge here (no DB or switch off): a shared round."""
        if daily_on is None:
            daily_on = get_settings().daily_challenge_enabled
        if self.daily is None or not daily_on:
            return None
        play, remaining = await self.daily.begin(
            subject_id, share.language, share.challenge_date
        )
        if play.language != share.language:
            # This day's attempt was in another language: their one attempt
            # is used, and the same five as a round would skew the crowd.
            raise ShareError(
                409, "daily_played_other_language", "Today's challenge was played"
            )
        if not remaining:
            if not is_sender:
                await self._record(
                    share,
                    subject_id,
                    float(play.score or 0),
                    len(share.question_ids),
                    None,
                    name,
                    await self._daily_known(share, subject_id),
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
        """The sender sees everyone; a friend who started it sees themselves
        and the sender; anyone else holding the token gets 404, so a forwarded
        link never shows who played."""
        share = await self.by_token(token)
        sender_ids = await self.store.person_ids(share.sender_subject_id)
        viewer_ids = await self.store.person_ids(subject_id)
        if not set(viewer_ids) & set(sender_ids) and not await self.store.took_part(
            share.id, viewer_ids
        ):
            raise ShareError(404, "not_found", "Shared quiz not found")
        players = rank(
            share,
            await self.store.finished_results(share.id),
            sender_ids,
            viewer_ids,
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
            try:
                known = known_in_session(session, subject_id)
                if session.daily_challenge_date:
                    known = await self._daily_known(share, subject_id) or known
                recorded += await self._record(
                    share,
                    subject_id,
                    float(score),
                    total,
                    session.session_id,
                    name,
                    known,
                )
            except Exception as e:  # one player's row never costs the others theirs
                logger.error(
                    "Shared quiz result for %s not recorded: %s", subject_id, e
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

    async def _record(
        self, share, subject_id, score, total, session_id, name, known
    ) -> int:
        return int(
            await self.store.record_result(
                share.id,
                subject_id,
                score=score,
                total=total,
                session_id=session_id,
                name=name,
                marks=aligned(share.question_ids, known),
            )
        )

    async def _daily_known(self, share: SharedQuiz, subject_id: str) -> dict:
        """The person's whole daily play (a challenge resumed in a second
        session has answers the finishing session never saw)."""
        if self.daily is None or share.challenge_date is None:
            return {}
        return await self.daily.knew_by_question(subject_id, share.challenge_date)

    def _emit(self, name: str, subject_id, session_id, **properties) -> None:
        if self.analytics is not None:
            self.analytics.emit(
                name,
                subject_id=subject_id,
                session_id=session_id,
                properties=properties,
            )
