"""The daily crew (#239): everyone a player swapped a daily challenge link
with, and their rarity points this week (a correct answer few knew is worth
more, see ``rules.rarity_points``).

Nobody sets a crew up. A person who opened my daily link, or whose daily link
I opened, is in my crew. Only that direct link counts, so friends of my
friends never see each other (the same rule as the #232 comparison). Either
side can remove the other; both then stop seeing each other for good.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from sqlalchemy import func, or_, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ..db.base import utcnow
from ..db.models import (
    DailyChallengeAnswer,
    DailyChallengePlay,
    DailyCrewRemoval,
    SharedQuiz,
    SharedQuizResult,
)
from ..shared_quiz.store import person_ids
from .rules import rarity_points
from .schemas import DailyCrew, DailyCrewMember

MAX_MEMBERS = 20
_PLAYER_WORD = {"sk": "Hráč", "cs": "Hráč", "uk": "Гравець", "en": "Player"}


def week_start(day: date) -> date:
    """Monday of the week ``day`` is in."""
    return day - timedelta(days=day.weekday())


@dataclass
class _Link:
    """One shared daily link between me and one other id."""

    member_id: uuid.UUID  # the result row that links us: opaque to the app
    other: str
    name: str | None
    at: datetime


@dataclass
class _Person:
    ids: list[str]
    member_id: uuid.UUID
    linked_at: datetime
    name: str | None = None
    named_at: datetime | None = None
    points: int = 0
    days: int = 0
    today: int = 0


class CrewNotFound(Exception):
    """The member id does not link this player with anyone."""


class DailyCrewService:
    def __init__(self, sessionmaker: async_sessionmaker[AsyncSession]) -> None:
        self._sm = sessionmaker

    async def crew(self, subject_id: str, day: date, language: str) -> DailyCrew:
        start = week_start(day)
        async with self._sm() as db:
            me = await person_ids(db, subject_id)
            people = await self._people(db, me)
            people = [p for p in people if not await self._removed(db, me, p.ids)]
            everyone = [
                *people,
                _Person(ids=me, member_id=uuid.UUID(int=0), linked_at=utcnow()),
            ]
            crowd = await self._crowd(db, start, day)
            for person in everyone:
                person.points, person.days, person.today = await self._week(
                    db, person.ids, start, day, crowd
                )
        # This week's crew: who played this week or swapped a link this week.
        active = [p for p in people if p.days or p.linked_at.date() >= start]
        if not active:
            return DailyCrew(week_start=start.isoformat(), members=[])
        active.sort(key=lambda p: p.linked_at, reverse=True)
        active = active[:MAX_MEMBERS]
        you = everyone[-1]
        return DailyCrew(
            week_start=start.isoformat(),
            members=_ranked(active, you, language),
        )

    async def remove(self, subject_id: str, member_id: str) -> None:
        """Take the person behind ``member_id`` out of this player's crew."""
        try:
            row_id = uuid.UUID(str(member_id))
        except (ValueError, TypeError):
            raise CrewNotFound(member_id)
        async with self._sm() as db:
            me = await person_ids(db, subject_id)
            row = (
                await db.execute(
                    select(SharedQuizResult.subject_id, SharedQuiz.sender_subject_id)
                    .join(SharedQuiz, SharedQuizResult.shared_quiz_id == SharedQuiz.id)
                    .where(SharedQuizResult.id == row_id, SharedQuiz.kind == "daily")
                )
            ).first()
            if row is None:
                raise CrewNotFound(member_id)
            friend, sender = row
            if sender in me and friend not in me:
                other = friend
            elif friend in me and sender not in me:
                other = sender
            else:
                raise CrewNotFound(member_id)
            await db.execute(
                pg_insert(DailyCrewRemoval)
                .values(
                    id=uuid.uuid4(), subject_id=subject_id, removed_subject_id=other
                )
                .on_conflict_do_nothing()
            )
            await db.commit()

    # ── helpers ────────────────────────────────────────────────────────────
    @staticmethod
    async def _links(db: AsyncSession, me: list[str]) -> list[_Link]:
        """Every daily link between me and someone else, both directions."""
        mine = await db.execute(
            select(
                SharedQuizResult.id,
                SharedQuizResult.subject_id,
                SharedQuizResult.display_name,
                SharedQuizResult.started_at,
            )
            .join(SharedQuiz, SharedQuizResult.shared_quiz_id == SharedQuiz.id)
            .where(
                SharedQuiz.kind == "daily",
                SharedQuiz.sender_subject_id.in_(me),
                SharedQuizResult.subject_id.not_in(me),
            )
        )
        theirs = await db.execute(
            select(
                SharedQuizResult.id,
                SharedQuiz.sender_subject_id,
                SharedQuiz.sender_name,
                SharedQuizResult.started_at,
            )
            .join(SharedQuiz, SharedQuizResult.shared_quiz_id == SharedQuiz.id)
            .where(
                SharedQuiz.kind == "daily",
                SharedQuizResult.subject_id.in_(me),
                SharedQuiz.sender_subject_id.not_in(me),
            )
        )
        return [_Link(*row) for row in (*mine.all(), *theirs.all())]

    async def _people(self, db: AsyncSession, me: list[str]) -> list[_Person]:
        """The links folded into people: every id one person plays under."""
        by_key: dict[tuple[str, ...], _Person] = {}
        folded: dict[str, tuple[str, ...]] = {}
        for link in await self._links(db, me):
            key = folded.get(link.other)
            if key is None:
                key = tuple(await person_ids(db, link.other))
                for other_id in key:
                    folded[other_id] = key
            person = by_key.setdefault(
                key,
                _Person(ids=list(key), member_id=link.member_id, linked_at=link.at),
            )
            if link.at > person.linked_at:
                person.linked_at = link.at
                person.member_id = link.member_id
            if link.name and (person.named_at is None or link.at > person.named_at):
                person.name, person.named_at = link.name, link.at
        return list(by_key.values())

    @staticmethod
    async def _removed(db: AsyncSession, me: list[str], them: list[str]) -> bool:
        return (
            await db.execute(
                select(DailyCrewRemoval.id)
                .where(
                    or_(
                        DailyCrewRemoval.subject_id.in_(me)
                        & DailyCrewRemoval.removed_subject_id.in_(them),
                        DailyCrewRemoval.subject_id.in_(them)
                        & DailyCrewRemoval.removed_subject_id.in_(me),
                    )
                )
                .limit(1)
            )
        ).first() is not None

    @staticmethod
    async def _crowd(
        db: AsyncSession, start: date, day: date
    ) -> dict[tuple[str, date, str], tuple[int, int]]:
        """Per (language, date, question) of the week: (answered, knew), over
        every player — what the rarity points are computed from."""
        rows = await db.execute(
            select(
                DailyChallengePlay.language,
                DailyChallengePlay.challenge_date,
                DailyChallengeAnswer.question_id,
                func.count(),
                func.count().filter(DailyChallengeAnswer.knew.is_(True)),
            )
            .join(
                DailyChallengePlay,
                DailyChallengeAnswer.play_id == DailyChallengePlay.id,
            )
            .where(
                DailyChallengePlay.challenge_date >= start,
                DailyChallengePlay.challenge_date <= day,
            )
            .group_by(
                DailyChallengePlay.language,
                DailyChallengePlay.challenge_date,
                DailyChallengeAnswer.question_id,
            )
        )
        return {(lang, d, qid): (n, k) for lang, d, qid, n, k in rows.all()}

    @staticmethod
    async def _week(
        db: AsyncSession,
        ids: list[str],
        start: date,
        day: date,
        crowd: dict[tuple[str, date, str], tuple[int, int]],
    ) -> tuple[int, int, int]:
        """Rarity points this week, days played and today's points, from
        finished plays from Monday to ``day``."""
        rows = await db.execute(
            select(
                DailyChallengePlay.id,
                DailyChallengePlay.language,
                DailyChallengePlay.challenge_date,
                DailyChallengeAnswer.question_id,
            )
            .outerjoin(
                DailyChallengeAnswer,
                (DailyChallengeAnswer.play_id == DailyChallengePlay.id)
                & DailyChallengeAnswer.knew.is_(True),
            )
            .where(
                DailyChallengePlay.subject_id.in_(ids),
                DailyChallengePlay.challenge_date >= start,
                DailyChallengePlay.challenge_date <= day,
                DailyChallengePlay.finished_at.is_not(None),
            )
        )
        per_play: dict[uuid.UUID, int] = {}
        play_day: dict[uuid.UUID, date] = {}
        for play_id, language, played_on, question_id in rows.all():
            play_day[play_id] = played_on
            per_play.setdefault(play_id, 0)
            if question_id is not None:
                answered, knew_count = crowd.get(
                    (language, played_on, question_id), (0, 0)
                )
                per_play[play_id] += rarity_points(answered, knew_count)
        # One play per person per day; a merged account could hold two.
        best: dict[date, int] = {}
        for play_id, points in per_play.items():
            played_on = play_day[play_id]
            best[played_on] = max(best.get(played_on, 0), points)
        return sum(best.values()), len(best), best.get(day, 0)


def _ranked(
    people: list[_Person], you: _Person, language: str
) -> list[DailyCrewMember]:
    word = _PLAYER_WORD.get(language, _PLAYER_WORD["en"])
    rows: list[DailyCrewMember] = []
    number = 0
    for person in people:
        name = person.name
        if not name:
            number += 1
            name = f"{word} {number}"
        rows.append(
            DailyCrewMember(
                member_id=str(person.member_id),
                name=name,
                points=person.points,
                days=person.days,
                today=person.today,
            )
        )
    rows.append(
        DailyCrewMember(
            member_id=None,
            name=None,
            points=you.points,
            days=you.days,
            today=you.today,
            is_you=True,
        )
    )
    # Stable sort: equal points keep you last among them, then by recent link.
    rows.sort(key=lambda m: -m.points)
    place = 0
    for index, member in enumerate(rows):
        if index == 0 or member.points != rows[index - 1].points:
            place = index + 1
        member.place = place
    return rows
