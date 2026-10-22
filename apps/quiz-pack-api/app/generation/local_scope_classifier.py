"""Issue #206 — "local question" label (``local_scope``).

Founder 2026-10-15: a player can switch off questions that only people from one
country understand (Bratislava public transport, the Czech card game prší, a
domestic TV show). This classifier decides, per question, which country (if
any) a question is tied to; the live retriever then serves only universal rows
to a player who opted out.

The label is the country (ISO 3166-1 alpha-2, lowercase), not a yes/no, so a
later "keep my own country's local questions" needs no relabel.

Shape mirrors ``TopicalityClassifier`` (#195) — one batched call through
``quiz_shared.llm.factory`` — and the regional flag of #168
(``translation_verification/regional.py``) for its fail-safe direction: a
missing label means universal and must never block or drop a row. The prompt
differs from #168 on purpose: that one asks "foreign to a Slovak player?", this
one includes the player's *own* country.

Fail-safe, fail-loud: any LLM error, malformed response or count mismatch logs
a warning and returns ``None`` for the affected questions. ``None`` writes
nothing, so the backfill (``scripts/classify_local_scope.py``) picks those rows
up again. NEVER raises.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Optional, Sequence

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

_CLASSIFIER_MODEL = llm_factory.LOCAL_SCOPE

# Lowercase ISO 3166-1 alpha-2. Note Czechia is "cz" (country), not "cs"
# (the language code the corpus uses).
_COUNTRY_RE = re.compile(r"^[a-z]{2}$")

# Questions per LLM call in the backfill / importer. Big enough to amortise the
# instructions, small enough that one bad reply loses little.
DEFAULT_BATCH_SIZE = 25

_PROMPT_HEADER = """You label trivia questions for a quiz app played in many \
countries. For each question decide whether it is LOCAL: answering it depends \
on knowledge that people from one particular country (or one city or region in \
it) have and people from other countries generally do not.

LOCAL examples: a city's public transport lines or stops, domestic TV and radio \
shows and their hosts, local politicians, domestic sports leagues and clubs \
known only at home, national holidays and name days, school-curriculum facts \
taught only in that country, regional customs, dishes, card games and slang, \
state or county capitals, domestic brands and shops.

NOT LOCAL: world history, geography of countries and well-known places, \
science, nature, and culture known internationally, even when it originated in \
one country (Škoda, Franz Kafka, the Beatles, ice hockey world championships, \
the Eiffel Tower). A question written in Slovak or Czech is not local just \
because of its language: judge the knowledge needed, not the wording.

When LOCAL, give the country as a lowercase ISO 3166-1 alpha-2 code ("sk" \
Slovakia, "cz" Czechia, "us" United States, "gb" United Kingdom, ...). When \
not local, use null. Add a short reason naming the knowledge involved.

Respond with JSON only, no prose:
{"labels": [{"index": <1-based int>, "local_scope": "<code>" | null, "reason": "<short reason>"}]}

Questions:
"""


@dataclass
class LocalScope:
    """A question's country tie (``None`` = universal) and why."""

    scope: Optional[str]
    reason: str


def apply_local_scope(q: Question, verdict: LocalScope) -> None:
    """Stamp ``local_scope`` and record the verdict in provenance.

    ``generation_metadata.extra["local_scope"]`` (the ``provenance`` JSONB
    column) is also the "this row was classified" marker the backfill keys on,
    so a universal row is distinguishable from an unlabelled one without a
    second column.
    """
    q.local_scope = verdict.scope
    provenance = q.generation_metadata or GenerationProvenance()
    q.generation_metadata = provenance.model_copy(
        update={
            "extra": {
                **provenance.extra,
                "local_scope": {
                    "scope": verdict.scope,
                    "reason": verdict.reason,
                    "model": _CLASSIFIER_MODEL,
                },
            }
        }
    )


def has_local_scope_verdict(q: Question) -> bool:
    """Whether the classifier already labelled ``q`` (universal included)."""
    meta = q.generation_metadata
    return meta is not None and "local_scope" in meta.extra


def _answer_text(answer: object) -> str:
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)


class LocalScopeClassifier:
    """Batched LLM judge assigning ``local_scope`` per question; never raises."""

    def __init__(self, model: Optional[str] = None) -> None:
        self.model = model or _CLASSIFIER_MODEL
        self._client = None

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self.model)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception as exc:
            logger.warning("LocalScopeClassifier: LLM call failed (%r)", exc)
            return None

    @staticmethod
    def _build_prompt(questions: Sequence[Question]) -> str:
        lines = [_PROMPT_HEADER]
        for i, q in enumerate(questions, start=1):
            lines.append(
                f"{i}. [{q.language or 'en'}] Q: {q.question}\n"
                f"   A: {_answer_text(q.correct_answer)}"
            )
        return "\n".join(lines)

    @staticmethod
    def _parse(text: str, n: int) -> list[Optional[LocalScope]]:
        """Parse the batched JSON into a list aligned to the input.

        ``None`` for every question the model skipped, gave an out-of-range
        index, or a value that is not a two-letter country code.
        """
        result: list[Optional[LocalScope]] = [None] * n
        cleaned = text.strip()
        start, end = cleaned.find("{"), cleaned.rfind("}") + 1
        if start == -1 or end <= start:
            logger.warning("LocalScopeClassifier: no JSON object in response")
            return result
        data = json.loads(cleaned[start:end])
        items = data.get("labels") if isinstance(data, dict) else None
        if not isinstance(items, list):
            logger.warning("LocalScopeClassifier: response missing 'labels' list")
            return result

        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                idx = int(item.get("index"))
            except (TypeError, ValueError):
                continue
            scope = item.get("local_scope")
            if isinstance(scope, str):
                scope = scope.strip().lower() or None
            if not (1 <= idx <= n) or (
                scope is not None
                and not (isinstance(scope, str) and _COUNTRY_RE.match(scope))
            ):
                continue
            result[idx - 1] = LocalScope(
                scope=scope, reason=str(item.get("reason") or "").strip()
            )

        matched = sum(1 for r in result if r is not None)
        if matched != n:
            logger.warning(
                "LocalScopeClassifier: labelled %d/%d questions; the rest stay "
                "unlabelled (served as universal)",
                matched,
                n,
            )
        return result

    async def classify(
        self, questions: Sequence[Question]
    ) -> list[Optional[LocalScope]]:
        """Label every question in one call; list aligned to ``questions``."""
        n = len(questions)
        if n == 0:
            return []
        try:
            if not llm_factory.chat_available(self.model):
                logger.warning(
                    "LocalScopeClassifier unavailable (no key for %s); %d "
                    "questions left unlabelled",
                    self.model,
                    n,
                )
                return [None] * n
            text = await self._complete(self._build_prompt(questions))
            if text is None:
                return [None] * n
            return self._parse(text, n)
        except Exception as exc:  # bulletproof: never propagate into a caller
            logger.warning(
                "LocalScopeClassifier failed (%r); %d questions left unlabelled",
                exc,
                n,
            )
            return [None] * n

    async def label(
        self, questions: Sequence[Question], batch_size: int = DEFAULT_BATCH_SIZE
    ) -> int:
        """Classify in batches and apply every verdict; return how many labelled."""
        labelled = 0
        for i in range(0, len(questions), batch_size):
            batch = questions[i : i + batch_size]
            for q, verdict in zip(batch, await self.classify(batch)):
                if verdict is not None:
                    apply_local_scope(q, verdict)
                    labelled += 1
        return labelled
