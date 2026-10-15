"""Daily challenge persistence and crowd numbers (#205 205.1–205.3).

Everything is computed on request from ``daily_challenge_answers`` (volume is a
handful of rows a day). The player's own answers never count as "others".
"""

from __future__ import annotations

import logging
import uuid
from datetime import date
from typing import Dict, List, Optional, Tuple

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from quiz_shared.models.question import Question
from quiz_shared.models.session import QuizSession

from ..db.base import utcnow
from ..db.models import (
    AnonymousIdentity,
    DailyChallengeAnswer,
    DailyChallengePlay,
    DailyChallengeSet,
)
from ..retrieval.question_retriever import QuestionRetriever
from ..serializers import correct_option_key
from . import copy
from .rules import (
    MAX_SPOKEN_LINES,
    RARE_SHARE,
    Crowd,
    Standing,
    classify,
    is_spoken,
    knew,
)
from .schemas import CrowdStrip, DailyBestHit, DailyChallengeState, DailySummary
from .selection import SET_SIZE, pick_daily_set

logger = logging.getLogger(__name__)


class DailySetUnavailable(Exception):
    """Too few servable questions to build the day's set."""


class DailyChallengeService:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        retriever: QuestionRetriever,
    ):
        self._sm = sessionmaker
        self._retriever = retriever

    # ── 205.1 the day's set ────────────────────────────────────────────────
    async def question_ids(self, language: str, day: date) -> List[str]:
        """The persisted set for (language, day), chosen on first request."""
        async with self._sm() as db:
            row = await db.get(DailyChallengeSet, (language, day))
            if row is not None:
                return list(row.question_ids)
            used = (
                await db.execute(
                    select(DailyChallengeSet.question_ids).where(
                        DailyChallengeSet.language == language
                    )
                )
            ).scalars()
            used_ids = [qid for ids in used for qid in ids]

        candidates = await self._retriever.daily_candidates(language)
        ids = pick_daily_set(
            candidates, language=language, seed=f"{language}:{day}", used_ids=used_ids
        )
        if len(ids) < SET_SIZE:
            raise DailySetUnavailable(f"{language} {day}: {len(ids)} questions")

        async with self._sm() as db:
            # Two first players at once: the first insert wins, both read it back.
            await db.execute(
                pg_insert(DailyChallengeSet)
                .values(language=language, challenge_date=day, question_ids=ids)
                .on_conflict_do_nothing()
            )
            await db.commit()
            row = await db.get(DailyChallengeSet, (language, day))
            return list(row.question_ids)

    # ── 205.2 play + record ────────────────────────────────────────────────
    async def begin(
        self, subject_id: str, language: str, day: date
    ) -> Tuple[DailyChallengePlay, List[str]]:
        """The subject's play for ``day`` (created on first start) and the
        questions still to play. Empty list → the play is finished. A play
        started in another language keeps that language."""
        async with self._sm() as db:
            play = await self._play(db, subject_id, day)
            if play is None:
                await db.execute(
                    pg_insert(DailyChallengePlay)
                    .values(
                        id=uuid.uuid4(),
                        subject_id=subject_id,
                        challenge_date=day,
                        language=language,
                        started_at=utcnow(),
                    )
                    .on_conflict_do_nothing()
                )
                await db.commit()
                play = await self._play(db, subject_id, day)
            if play.finished_at is not None:
                return play, []
        set_ids = await self.question_ids(play.language, day)
        answered = await self._answers(play.id)
        remaining = [q for q in set_ids if q not in answered]
        if not remaining:
            await self._finish(play.id)
            async with self._sm() as db:
                play = await self._play(db, subject_id, day)
        return play, remaining

    async def attach_session(self, play_id: uuid.UUID, session_id: str) -> None:
        async with self._sm() as db:
            await db.execute(
                update(DailyChallengePlay)
                .where(DailyChallengePlay.id == play_id)
                .values(session_id=session_id)
            )
            await db.commit()

    async def record_answer(
        self,
        session: QuizSession,
        question_id: str,
        result: str,
        regrade: bool = False,
    ) -> None:
        """The first graded verdict per question counts. A re-grade (an edited
        transcript of the same answer, #133) replaces it, and re-scores a play
        that already finished (#189 re-answer after the last question)."""
        play = await self._session_play(session)
        if play is None:
            return
        insert = pg_insert(DailyChallengeAnswer).values(
            play_id=play.id,
            question_id=question_id,
            result=result,
            knew=knew(result),
            answered_at=utcnow(),
        )
        insert = (
            insert.on_conflict_do_update(
                index_elements=["play_id", "question_id"],
                set_={"result": result, "knew": knew(result)},
            )
            if regrade
            else insert.on_conflict_do_nothing()
        )
        async with self._sm() as db:
            await db.execute(insert)
            await db.commit()
        if regrade and play.finished_at is not None:
            await self._finish(play.id, rescore=True)

    async def finish(self, session: QuizSession) -> None:
        play = await self._session_play(session)
        if play is not None:
            await self._finish(play.id)

    async def _finish(self, play_id: uuid.UUID, rescore: bool = False) -> None:
        answers = await self._answers(play_id)
        stmt = update(DailyChallengePlay).where(DailyChallengePlay.id == play_id)
        if rescore:
            stmt = stmt.values(score=sum(answers.values()))
        else:
            stmt = stmt.where(DailyChallengePlay.finished_at.is_(None)).values(
                finished_at=utcnow(), score=sum(answers.values())
            )
        async with self._sm() as db:
            await db.execute(stmt)
            await db.commit()

    # ── 205.3 crowd ────────────────────────────────────────────────────────
    async def crowd(
        self, language: str, day: date, question_id: str, exclude: List[str]
    ) -> Crowd:
        """Others' first verdicts on one question; ``exclude`` is every id of
        the player (see ``_identity_ids``)."""
        async with self._sm() as db:
            others, knew_count = (
                await db.execute(
                    select(
                        func.count(),
                        func.count().filter(DailyChallengeAnswer.knew.is_(True)),
                    )
                    .select_from(DailyChallengeAnswer)
                    .join(
                        DailyChallengePlay,
                        DailyChallengeAnswer.play_id == DailyChallengePlay.id,
                    )
                    .where(
                        DailyChallengePlay.language == language,
                        DailyChallengePlay.challenge_date == day,
                        DailyChallengePlay.subject_id.not_in(exclude),
                        DailyChallengeAnswer.question_id == question_id,
                    )
                )
            ).one()
        return Crowd(others=others, knew=knew_count)

    async def answer_strip(
        self,
        session: QuizSession,
        question_id: str,
        result: str,
        regrade: bool = False,
    ) -> Tuple[Optional[CrowdStrip], Optional[str]]:
        """The strip for a just-graded answer and, if this one is worth saying,
        the sentence the host appends to the feedback utterance. A re-grade
        gets the strip but never speaks again."""
        play = await self._session_play(session)
        if play is None:
            return None, None
        async with self._sm() as db:
            exclude = await self._identity_ids(db, play.subject_id)
        crowd = await self.crowd(
            play.language, play.challenge_date, question_id, exclude
        )
        kind = classify(crowd, knew(result))
        spoken = None
        if not regrade and is_spoken(kind, play.spoken_lines):
            spoken_before = await self._claim_spoken_line(play.id)
            if spoken_before is not None:
                spoken = copy.spoken_line(kind, crowd, play.language, spoken_before)
        if kind == "hidden":
            return None, spoken
        return (
            CrowdStrip(
                kind=kind,
                text=copy.strip_text(crowd, session.language),
                others=crowd.others,
                knew=crowd.knew,
            ),
            spoken,
        )

    async def state(
        self, subject_id: str, language: str, day: date
    ) -> DailyChallengeState:
        async with self._sm() as db:
            play = await self._play(db, subject_id, day)
        if play is None:
            return DailyChallengeState(
                date=day.isoformat(),
                language=language,
                status="not_played",
                total=SET_SIZE,
            )
        set_ids = await self.question_ids(play.language, day)
        base = dict(date=day.isoformat(), language=play.language, total=len(set_ids))
        if play.finished_at is None:
            return DailyChallengeState(status="in_progress", **base)
        return DailyChallengeState(
            status="played", summary=await self._summary(play, set_ids), **base
        )

    async def _summary(
        self, play: DailyChallengePlay, set_ids: List[str]
    ) -> DailySummary:
        answers = await self._answers(play.id)
        score = play.score or 0
        async with self._sm() as db:
            exclude = await self._identity_ids(db, play.subject_id)
            others, beaten = (
                await db.execute(
                    select(
                        func.count(),
                        func.count().filter(DailyChallengePlay.score < score),
                    ).where(
                        DailyChallengePlay.language == play.language,
                        DailyChallengePlay.challenge_date == play.challenge_date,
                        DailyChallengePlay.subject_id.not_in(exclude),
                        DailyChallengePlay.finished_at.is_not(None),
                    )
                )
            ).one()
        standing = Standing(
            others=others, beaten=beaten, score=score, total=len(set_ids)
        )
        return DailySummary(
            score=score,
            total=len(set_ids),
            marks=[answers.get(q) for q in set_ids],
            players=others + 1,
            comparison=copy.comparison_text(standing, play.language),
            rank=copy.rank_text(standing, play.language),
            best_hit=await self._best_hit(
                play, [q for q in set_ids if answers.get(q)], exclude
            ),
        )

    async def _best_hit(
        self, play: DailyChallengePlay, known_ids: List[str], exclude: List[str]
    ) -> Optional[DailyBestHit]:
        """The question the player knew that the fewest others knew."""
        best: Optional[Tuple[float, str, Crowd]] = None
        for qid in known_ids:
            crowd = await self.crowd(play.language, play.challenge_date, qid, exclude)
            if crowd.others and (best is None or crowd.share < best[0]):
                best = (crowd.share, qid, crowd)
        if best is None:
            return None
        share, qid, crowd = best
        question = await self._retriever.get(qid)
        if question is None:
            return None
        text, answer = await self._display(question, play.language)
        rare = share <= RARE_SHARE
        return DailyBestHit(
            question_id=qid,
            question=text,
            answer=answer,
            rare=rare,
            text=copy.best_hit_text(crowd, rare, play.language),
        )

    async def _display(self, question: Question, language: str) -> Tuple[str, str]:
        """Question and answer as the player saw them (native row, or its
        stored translation — the set only holds translated rows)."""
        if language != "en" and question.language != language:
            record = (
                await self._retriever.get_translations([question.id], language)
            ).get(question.id)
            if record:
                return record["question"], str(record["correct_answer"])
        key = correct_option_key(question)
        if key is not None:
            return question.question, question.possible_answers[key]
        answer = question.correct_answer
        if isinstance(answer, list):
            answer = answer[0] if answer else ""
        return question.question, str(answer)

    # ── helpers ────────────────────────────────────────────────────────────
    async def _identity_ids(self, db: AsyncSession, subject_id: str) -> List[str]:
        """Every id the same person plays under: the subject, the account its
        anonymous id was signed in to, and that account's other anonymous ids.
        Sign-in moves plays to the account and sign-out returns the device to
        its anon id, so a one-per-day guard on one id alone could be replayed."""
        ids = {subject_id}
        upgraded = (
            await db.execute(
                select(AnonymousIdentity.upgraded_to_user_id).where(
                    AnonymousIdentity.anon_id == subject_id
                )
            )
        ).scalar_one_or_none()
        owner = upgraded or subject_id
        ids.add(owner)
        linked = await db.execute(
            select(AnonymousIdentity.anon_id).where(
                AnonymousIdentity.upgraded_to_user_id == owner
            )
        )
        ids.update(linked.scalars())
        return sorted(ids)

    async def _play(
        self, db: AsyncSession, subject_id: str, day: date
    ) -> Optional[DailyChallengePlay]:
        ids = await self._identity_ids(db, subject_id)
        return (
            (
                await db.execute(
                    select(DailyChallengePlay)
                    .where(
                        DailyChallengePlay.subject_id.in_(ids),
                        DailyChallengePlay.challenge_date == day,
                    )
                    .order_by(DailyChallengePlay.started_at)
                )
            )
            .scalars()
            .first()
        )

    async def _session_play(self, session: QuizSession) -> Optional[DailyChallengePlay]:
        """The play this session was started for. Looked up by session id, not
        by subject: signing in mid-challenge moves the play to the account
        while the live session still carries the anonymous id."""
        async with self._sm() as db:
            return (
                await db.execute(
                    select(DailyChallengePlay).where(
                        DailyChallengePlay.session_id == session.session_id
                    )
                )
            ).scalar_one_or_none()

    async def _claim_spoken_line(self, play_id: uuid.UUID) -> Optional[int]:
        """Reserve one of the play's spoken crowd lines; the number spoken
        before it, or None when all are used. Kept on the play, so a resumed
        challenge (a new session) cannot start the count over."""
        async with self._sm() as db:
            claimed = (
                await db.execute(
                    update(DailyChallengePlay)
                    .where(
                        DailyChallengePlay.id == play_id,
                        DailyChallengePlay.spoken_lines < MAX_SPOKEN_LINES,
                    )
                    .values(spoken_lines=DailyChallengePlay.spoken_lines + 1)
                    .returning(DailyChallengePlay.spoken_lines)
                )
            ).scalar_one_or_none()
            await db.commit()
        return None if claimed is None else claimed - 1

    async def _answers(self, play_id: uuid.UUID) -> Dict[str, bool]:
        async with self._sm() as db:
            rows = await db.execute(
                select(
                    DailyChallengeAnswer.question_id, DailyChallengeAnswer.knew
                ).where(DailyChallengeAnswer.play_id == play_id)
            )
            return {qid: k for qid, k in rows.all()}
