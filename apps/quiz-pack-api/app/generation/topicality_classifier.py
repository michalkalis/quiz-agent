"""Issue #195 — post-generation topicality classification (fresh-question boost).

Founder 2026-10-08: "fresh" questions (e.g. recent entertainment news) should be
picked ~2× as often as ordinary ones, but only while they are topical. How long
that lasts depends on the question — "who had a birthday last week" ~ a week,
"who won the 2026 Oscar for X" ~ a year, a Best Picture winner forever — so an
LLM decides per question. It assigns a ``tier`` plus the ``event_date`` the
question hinges on; a deterministic ``tier → TTL`` map (``TIER_TTL``) then gives
``boost_until = event_date + TTL`` (see ``boost_until_for``).

This is NOT the #76 expiry (``expiry_classifier.py`` / ``expires_at``): expiry
hides a stale question, the boost only re-weights the live pick and ends
silently — afterwards the question behaves like an ordinary one.

Design mirrors ``ExpiryClassifier``:
- ONE batched LLM call per ``classify`` through ``quiz_shared.llm.factory`` on
  the CRITIQUE role (never an SDK client / API key here).
- Reads question text + correct answer only — question-type agnostic.
- Fail-safe, fail-loud: any LLM error, malformed response or count mismatch
  logs a warning and leaves the affected questions unboosted. NEVER raises
  into the generation pipeline.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from typing import Optional, Sequence

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

# The one config spot: tier → boost window, counted from the event date.
# ``none`` (not topical news — most of the general corpus) is never boosted;
# ``permanent`` is boosted forever (``PERMANENT_BOOST_UNTIL``).
TIER_TTL: dict[str, timedelta] = {
    "week": timedelta(days=7),
    "month": timedelta(days=30),
    "quarter": timedelta(days=90),
    "year": timedelta(days=365),
}
TIERS = ("none", *TIER_TTL, "permanent")

# Python ``datetime`` cannot hold Postgres ``infinity``; a far-future date does
# the same job. Year 9999 Jan 1 (not Dec 31) so a timezone shift can never
# overflow ``datetime.max``.
PERMANENT_BOOST_UNTIL = datetime(9999, 1, 1, tzinfo=timezone.utc)

# Same judgment role as the expiry classifier (2026-07-30 frontier refresh: no
# mini-class models in the generation pipeline).
_CLASSIFIER_MODEL = llm_factory.CRITIQUE

_PROMPT_HEADER = """You decide how long a trivia question stays TOPICAL — how \
long it feels like fresh news a player would enjoy seeing more often. You read \
only the question and its correct answer. Today is {today}.

Assign exactly one tier to each:
- "none": not topical news at all — history, science, geography, general
  culture, anything that is no fresher today than a year ago. MOST questions.
- "week": hinges on a tiny news item that is stale within days — e.g. "which
  celebrity had a birthday last week".
- "month": a news story people talk about for a few weeks.
- "quarter": a notable event that stays in conversation for a season — e.g. a
  big album or film release, a summer transfer saga.
- "year": a headline result people remember for about a year — e.g. "who won
  the 2026 Oscar for Best Actress", this year's Eurovision winner.
- "permanent": a truly major cultural event that stays fresh forever — e.g.
  the Best Picture winner, a once-in-a-generation moment.

Also give event_date: the date (YYYY-MM-DD) of the news/event the question
hinges on; estimate it if unsure (a month or year alone → its first day).
Use null only for "none". Plus a one-line rationale (why that tier).

Respond with JSON only, no prose:
{{"classifications": [{{"index": <1-based int>, "tier": "none|week|month|quarter|year|permanent", "event_date": "YYYY-MM-DD" | null, "rationale": "<one line>"}}]}}

Questions:
"""


@dataclass
class Topicality:
    """A question's topicality tier, the event it hinges on, and why."""

    tier: str  # always one of TIERS
    event_date: Optional[date]  # always set for a TIER_TTL tier
    rationale: str


def boost_until_for(t: Topicality, now: datetime) -> Optional[datetime]:
    """Deterministic end of the boost window, or ``None`` for no boost.

    ``event_date + TTL`` (midnight UTC) for a windowed tier; a window that has
    already closed by ``now`` gives no boost at all — an old event classified
    late must not come back as "fresh".
    """
    if t.tier == "permanent":
        return PERMANENT_BOOST_UNTIL
    ttl = TIER_TTL.get(t.tier)
    if ttl is None or t.event_date is None:
        return None
    until = datetime.combine(t.event_date, time.min, tzinfo=timezone.utc) + ttl
    return until if until > now else None


def apply_topicality(q: Question, t: Topicality, now: datetime) -> None:
    """Stamp ``boost_until`` and record the verdict in provenance for review.

    The tier/event_date/rationale land in ``generation_metadata.extra
    ["topicality"]`` (the ``provenance`` JSONB column) so a founder can audit
    "why boosted for a year?" per question without a new column.
    """
    q.boost_until = boost_until_for(t, now)
    provenance = q.generation_metadata or GenerationProvenance()
    q.generation_metadata = provenance.model_copy(
        update={
            "extra": {
                **provenance.extra,
                "topicality": {
                    "tier": t.tier,
                    "event_date": t.event_date.isoformat() if t.event_date else None,
                    "rationale": t.rationale,
                },
            }
        }
    )


def _answer_text(answer: object) -> str:
    """Flatten a correct_answer (str or list) to a single line for the prompt."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)


def _parse_date(value: object) -> Optional[date]:
    try:
        return date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError):
        return None


class TopicalityClassifier:
    """Batched LLM judge assigning a topicality ``tier`` per question.

    Same lazy-client shape as ``ExpiryClassifier``; ``classify`` never raises.
    """

    def __init__(self, api_key: Optional[str] = None) -> None:
        self.api_key = api_key or os.getenv("OPENAI_API_KEY")
        self._client = None

    def _available(self) -> bool:
        """Whether the LLM is reachable under the active gateway."""
        if llm_factory.is_bedrock_model(_CLASSIFIER_MODEL):
            return True
        active = llm_factory.gateway()
        if active == llm_factory.SESSION:
            return True  # #169: Claude Code subscription, no API key involved
        if active == llm_factory.OPENROUTER:
            return bool(os.getenv("OPENROUTER_API_KEY"))
        return bool(self.api_key)

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(_CLASSIFIER_MODEL)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception:
            return None

    def _build_prompt(self, questions: Sequence[Question], today: date) -> str:
        lines = [_PROMPT_HEADER.format(today=today.isoformat())]
        for i, q in enumerate(questions, start=1):
            lines.append(f"{i}. Q: {q.question}\n   A: {_answer_text(q.correct_answer)}")
        return "\n".join(lines)

    def _parse(
        self, text: str, questions: Sequence[Question]
    ) -> list[Optional[Topicality]]:
        """Parse the batched JSON into a list aligned to ``questions``.

        ``None`` for every question the model didn't classify, classified with
        an unknown tier / out-of-range index, or gave a windowed tier without a
        usable ``event_date`` (no date → no window → fail safe to unboosted).
        """
        n = len(questions)
        result: list[Optional[Topicality]] = [None] * n

        cleaned = text.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        start = cleaned.find("{")
        end = cleaned.rfind("}") + 1
        if start == -1 or end <= start:
            logger.warning(
                "TopicalityClassifier: no JSON object in response; %d questions "
                "left unboosted",
                n,
            )
            return result
        data = json.loads(cleaned[start:end])

        items = data.get("classifications") if isinstance(data, dict) else None
        if not isinstance(items, list):
            logger.warning(
                "TopicalityClassifier: response missing 'classifications' list; "
                "%d questions left unboosted",
                n,
            )
            return result

        matched = 0
        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                idx = int(item.get("index"))
            except (TypeError, ValueError):
                continue
            tier = item.get("tier")
            if not (1 <= idx <= n) or tier not in TIERS:
                continue
            event_date = _parse_date(item.get("event_date"))
            if tier in TIER_TTL and event_date is None:
                continue
            result[idx - 1] = Topicality(
                tier=tier,
                event_date=event_date,
                rationale=str(item.get("rationale") or "").strip(),
            )
            matched += 1

        if matched != n:
            logger.warning(
                "TopicalityClassifier: classified %d/%d questions (count "
                "mismatch); the rest stay unboosted",
                matched,
                n,
            )
        return result

    async def classify(
        self, questions: Sequence[Question], today: Optional[date] = None
    ) -> list[Optional[Topicality]]:
        """Classify every question in one batched call.

        Returns a list aligned to ``questions``; ``None`` for any question that
        couldn't be classified. NEVER raises — every failure mode fails safe to
        all-``None`` with a logged warning.
        """
        n = len(questions)
        if n == 0:
            return []
        today = today or datetime.now(timezone.utc).date()
        try:
            if not self._available():
                logger.warning(
                    "TopicalityClassifier unavailable (no API key for active "
                    "gateway); leaving %d questions unboosted",
                    n,
                )
                return [None] * n
            text = await self._complete(self._build_prompt(questions, today))
            if text is None:
                logger.warning(
                    "TopicalityClassifier: LLM returned no content; leaving %d "
                    "questions unboosted",
                    n,
                )
                return [None] * n
            result = self._parse(text, questions)
        except Exception as exc:  # bulletproof: never propagate into the pipeline
            logger.warning(
                "TopicalityClassifier failed (%r); leaving %d questions unboosted",
                exc,
                n,
            )
            return [None] * n

        for q, t in zip(questions, result):
            if t is not None and t.tier != "none":
                logger.info(
                    "TopicalityClassifier tier=%s event_date=%s rationale=%s | %.80s",
                    t.tier,
                    t.event_date,
                    t.rationale,
                    q.question,
                )
        return result
