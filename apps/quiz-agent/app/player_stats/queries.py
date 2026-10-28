"""SQL aggregation for player stats (#213): GROUP BY over the JSONB properties.

Every query starts from the same ``ans`` CTE: the player's graded answers with
only the LATEST ``answer_evaluated`` row kept per (session, question), because
an edited transcript is re-graded and emits a newer row with ``is_regrade``
(``quiz/resubmission.py``). The rows are never loaded into Python; only the
small grouped results are.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import bindparam, text
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.types import DateTime, Text

_P = "properties"


def _ans_cte(start: datetime | None, end: datetime | None) -> str:
    window = ""
    if start is not None:
        window += " AND occurred_at >= :start"
    if end is not None:
        window += " AND occurred_at < :end"
    return f"""
WITH ans AS (
  SELECT DISTINCT ON (session_id, {_P}->>'question_id')
         session_id,
         {_P}->>'question_id' AS qid,
         occurred_at,
         {_P}->>'result' AS result,
         {_P}->>'category' AS category,
         {_P}->>'difficulty' AS difficulty,
         {_P}->>'question_type' AS qtype
  FROM analytics_events
  WHERE name = 'answer_evaluated' AND subject_id = ANY(:ids)
    AND session_id IS NOT NULL AND {_P}->>'question_id' IS NOT NULL{window}
  ORDER BY session_id, {_P}->>'question_id', occurred_at DESC, received_at DESC
)
"""


@dataclass(frozen=True)
class GameRow:
    session_id: str
    answers: int
    first_at: datetime
    last_at: datetime
    started_at: datetime | None
    has_context: bool
    timezone: str | None
    audio_route: str | None


@dataclass(frozen=True)
class DimRow:
    category: str | None
    difficulty: str | None
    qtype: str | None
    answers: int
    correct: int


@dataclass(frozen=True)
class SpeedRow:
    category: str
    measured: int
    median_ms: float


async def _run(session: AsyncSession, sql: str, ids, start, end, **extra):
    params = {"ids": list(ids), **extra}
    stmt = text(sql).bindparams(bindparam("ids", type_=ARRAY(Text)))
    if start is not None:
        params["start"] = start
        stmt = stmt.bindparams(bindparam("start", type_=DateTime(timezone=True)))
    if end is not None:
        params["end"] = end
        stmt = stmt.bindparams(bindparam("end", type_=DateTime(timezone=True)))
    return (await session.execute(stmt, params)).all()


async def fetch_games(session, ids, start, end) -> list[GameRow]:
    sql = (
        _ans_cte(start, end)
        + f"""
, g AS (
  SELECT session_id, count(*) AS n, min(occurred_at) AS first_at,
         max(occurred_at) AS last_at
  FROM ans GROUP BY session_id
), started AS (
  SELECT session_id, min(occurred_at) AS at FROM analytics_events
  WHERE name = 'quiz_started' AND subject_id = ANY(:ids) AND session_id IS NOT NULL
  GROUP BY session_id
), ctx AS (
  SELECT DISTINCT ON (session_id) session_id,
         {_P}->>'timezone' AS tz, {_P}->>'audio_route' AS route
  FROM analytics_events
  WHERE name = 'quiz_context' AND subject_id = ANY(:ids) AND session_id IS NOT NULL
  ORDER BY session_id, occurred_at
)
SELECT g.session_id, g.n, g.first_at, g.last_at, started.at,
       ctx.session_id IS NOT NULL, ctx.tz, ctx.route
FROM g LEFT JOIN started USING (session_id) LEFT JOIN ctx USING (session_id)
ORDER BY g.first_at
"""
    )
    return [GameRow(*r) for r in await _run(session, sql, ids, start, end)]


async def fetch_dims(session, ids, start, end) -> list[DimRow]:
    sql = (
        _ans_cte(start, end)
        + """
SELECT category, difficulty, qtype, count(*),
       count(*) FILTER (WHERE result = 'correct')
FROM ans GROUP BY category, difficulty, qtype
"""
    )
    return [DimRow(*r) for r in await _run(session, sql, ids, start, end)]


async def fetch_best_streak(session, ids, start, end) -> int:
    """Longest run of correct answers inside one game (gaps-and-islands)."""
    sql = (
        _ans_cte(start, end)
        + """
SELECT coalesce(max(run), 0) FROM (
  SELECT count(*) AS run FROM (
    SELECT session_id, (result = 'correct') AS ok,
           row_number() OVER (PARTITION BY session_id ORDER BY occurred_at)
         - row_number() OVER (PARTITION BY session_id, (result = 'correct')
                              ORDER BY occurred_at) AS island
    FROM ans
  ) t WHERE ok GROUP BY session_id, island
) runs
"""
    )
    return int((await _run(session, sql, ids, start, end))[0][0])


async def fetch_thirds(session, ids, start, end) -> list[tuple]:
    """(tile 1|3, difficulty, answers, correct): first vs last third by time."""
    sql = (
        _ans_cte(start, end)
        + """
SELECT tile, difficulty, count(*), count(*) FILTER (WHERE result = 'correct')
FROM (SELECT *, ntile(3) OVER (ORDER BY occurred_at) AS tile FROM ans) t
WHERE tile IN (1, 3) GROUP BY tile, difficulty
"""
    )
    return [tuple(r) for r in await _run(session, sql, ids, start, end)]


async def fetch_speed(session, ids, start, end) -> list[SpeedRow]:
    """Median time-to-answer per category, from the app's ``answer_submitted``
    (first attempt only: retries would multiply rows)."""
    sql = (
        _ans_cte(start, end)
        + f"""
, lat AS (
  SELECT DISTINCT ON (session_id, {_P}->>'question_id')
         session_id, {_P}->>'question_id' AS qid,
         ({_P}->>'latency_ms')::float AS ms
  FROM analytics_events
  WHERE name = 'answer_submitted' AND subject_id = ANY(:ids)
    AND session_id IS NOT NULL AND {_P}->>'question_id' IS NOT NULL
    AND jsonb_typeof({_P}->'latency_ms') = 'number'
    AND coalesce(({_P}->>'is_retry')::boolean, false) = false
  ORDER BY session_id, {_P}->>'question_id', occurred_at
)
SELECT ans.category, count(*), percentile_cont(0.5) WITHIN GROUP (ORDER BY lat.ms)
FROM ans JOIN lat ON lat.session_id = ans.session_id AND lat.qid = ans.qid
WHERE ans.category IS NOT NULL GROUP BY ans.category
"""
    )
    return [SpeedRow(*r) for r in await _run(session, sql, ids, start, end)]
