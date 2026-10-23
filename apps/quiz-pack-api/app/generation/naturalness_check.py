"""Issue #211 — naturalness check for native Slovak / Czech questions.

Founder 2026-10-22: "Krčmové kvízy, pri ktorých tímy súťažia nad pivom, dnes
nájdete v Bratislave, Košiciach…" reads as cringe: an English calque ("over a
pint") and a home reference that neither helps answer nor carries the point.
The MQM judge that knows calques (``translation_verification/judge.py``) only
runs on translations, so native sk/cs rows had no language check at all.

The verdict, including a proposed rewrite of the stem, lands in
``generation_metadata.extra["naturalness"]`` (the ``provenance`` JSONB column),
which doubles as the "already checked" marker for the backfill. It started as
a LABEL only, because LLM judges are unreliable on fluency in smaller
languages. Founder's blind pairs 2026-10-23 (#211 211.4): the rewrite won
15/20 and the originals had "quite big errors", but the 4 losing rewrites
changed the meaning, added words or rebuilt a sound sentence. So the prompt
now asks for the smallest edit (``PROMPT_VERSION`` 2), and
:func:`apply_rewrite` swaps the text in, keeping the original in provenance.
The importer does that only behind ``NATURALNESS_AUTOFIX``.

Shape mirrors ``LocalScopeClassifier`` (#206): one batched call through
``quiz_shared.llm.factory``. Fail-safe, fail-loud: any LLM error, malformed
response or count mismatch logs a warning and leaves the affected questions
unchecked (``None``), so ``scripts/check_naturalness.py`` picks them up again.
NEVER raises.
"""

from __future__ import annotations

import json
import logging
import unicodedata
from dataclasses import dataclass, field
from typing import Optional, Sequence

from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

_CHECK_MODEL = llm_factory.NATURALNESS

# Only native-language corpora; English rows are written by an English model.
LANGUAGES = ("sk", "cs")

PROBLEM_KINDS = (
    "calque",  # an English phrase or construction carried over literally
    "empty_hook",  # a home-country mention that neither helps nor carries the point
    "padding",  # other information that neither helps answer nor delights
    "unnatural",  # stiff, written-style or wrong collocation
    "grammar",
    "neighbour",  # Czech words in Slovak or Slovak words in Czech
)

DEFAULT_BATCH_SIZE = 20

#: Stamped on every verdict. 2 = smallest-edit rewrites (10-23 round 1);
#: 3 = v1's sensitivity back: round 2 showed v2's "when in doubt, ok" let
#: through 4/4 rows whose v1 rewrite the founder preferred.
PROMPT_VERSION = 3

_PROMPT_HEADER = """You are a native Slovak and Czech editor of a voice quiz \
read aloud to friends in a car. Judge each question as a native speaker of its \
language would hear it. Think in that language, not in English.

Report a problem only when a native speaker would notice it:
- "calque": an English phrase or construction carried over literally \
(sk "tímy súťažia nad pivom" from "over a pint", proper "pri pive"; \
sk "robí to zmysel", proper "dáva to zmysel"; cs "soutěž vzala místo", proper \
"soutěž se konala"; "Ktorá krajina je domovom…", proper "V ktorej krajine žije…").
- "empty_hook": a mention of Slovakia/Czechia, its cities or its people that \
neither helps the player answer nor carries the point, added only to sound \
local (sk "Krčmové kvízy … dnes nájdete v Bratislave, Košiciach aj v menších \
mestách. Z ktorej krajiny pochádzajú?"). A home reference that builds the \
point is fine ("Kým na Slovensku je na Štedrý večer kapor so šalátom, v ktorej \
ázijskej krajine si rodiny objednávajú vianočnú večeru z KFC?").
- "padding": any other part that neither helps answer nor is part of the fun.
- "unnatural": stiff, bookish or translated-sounding wording, chains of \
participles, needless passive, a collocation natives would not use.
- "grammar": a grammar or spelling error.
- "neighbour": a Czech word or form in a Slovak question, or the reverse.

Report every problem a native listener would notice, small ones too: a \
clumsy clitic order (cs "čeho na jeho oblečení byste se měli chytit", proper \
"čeho byste se na jeho oblečení měli chytit"), an unclear reference (sk \
"zastavujú autá a prikážu im", proper "prikazujú vodičom"), a home mention \
that adds nothing (cs "Úhoř, kterého rybáři chytají i v Labi, …"; sk "v \
slovenskej florbalovej extralige"). Do not flag common colloquial forms (sk \
"poprosíte niečo na hnačku") or a sound phrasing that is merely not the one \
you would pick (sk "postupne nás robí ospalými").

For every question with a problem, quote the exact offending words and give \
a "rewrite": the whole question with the smallest edit that removes the \
problems. Change only the quoted words and what grammar forces around them; \
copy every other word as it is. Never add words or information (not "aby v \
nej mohol pracovať" → "aby v nej mohol na železnici pracovať"), never rebuild \
a sentence that has no problem, and keep the exact meaning ("robí ospalými", \
makes sleepy, is not "uspáva", puts to sleep). Deleting an empty hook or \
padding is the right edit; then check that what is left still reads on its \
own: a word that pointed to the deleted part ("ich", "to", "tam") gets its \
noun back. Same facts, same correct answer, same difficulty. \
When the question is fine, "ok": true, no problems, "rewrite": null.

Respond with JSON only, no prose:
{"checks": [{"index": <1-based int>, "ok": <bool>, "problems": \
[{"kind": "<kind>", "quote": "<exact words>"}], "rewrite": "<question>" | null}]}

Questions:
"""


def _foreign_letters(text: str) -> set[str]:
    """Letters outside Latin script. A 10-23 re-check rewrite carried a
    look-alike Cyrillic "а": it reads the same and breaks search and speech."""
    return {
        ch for ch in text
        if ch.isalpha() and not unicodedata.name(ch, "").startswith("LATIN")
    }


@dataclass
class Naturalness:
    """A question's naturalness verdict and, when flagged, a proposed rewrite."""

    ok: bool
    problems: list[dict] = field(default_factory=list)
    rewrite: Optional[str] = None


def apply_naturalness(q: Question, verdict: Naturalness) -> None:
    """Record the verdict in provenance; the question text is never changed."""
    provenance = q.generation_metadata or GenerationProvenance()
    q.generation_metadata = provenance.model_copy(
        update={
            "extra": {
                **provenance.extra,
                "naturalness": {
                    "ok": verdict.ok,
                    "problems": verdict.problems,
                    "rewrite": verdict.rewrite,
                    "model": _CHECK_MODEL,
                    "version": PROMPT_VERSION,
                },
            }
        }
    )


def apply_rewrite(q: Question, applied_by: str) -> bool:
    """Swap a flagged question's text for its proposed rewrite.

    The original text stays in the verdict (``original_question``) so a swap
    can be audited and undone. Both vectors are cleared: they embed the old
    text, and a writer re-embeds a row whose vector is ``None``. Returns
    ``False`` (nothing changed) for an ok, unchecked or already applied row.
    """
    meta = q.generation_metadata
    verdict = meta.extra.get("naturalness") if meta else None
    if not verdict or verdict.get("ok") or "original_question" in verdict:
        return False
    rewrite = verdict.get("rewrite")
    if not rewrite or rewrite == q.question:
        return False
    q.generation_metadata = meta.model_copy(
        update={
            "extra": {
                **meta.extra,
                "naturalness": {
                    **verdict,
                    "original_question": q.question,
                    "applied_by": applied_by,
                },
            }
        }
    )
    q.question = rewrite
    q.embedding = q.embedding_model = q.embedding_dim = None
    q.embedding_qa = q.embedding_qa_model = None
    return True


def has_naturalness_verdict(q: Question) -> bool:
    meta = q.generation_metadata
    return meta is not None and "naturalness" in meta.extra


def needs_check(q: Question) -> bool:
    """A native sk/cs row the check has not seen yet."""
    return q.language in LANGUAGES and not has_naturalness_verdict(q)


class NaturalnessChecker:
    """Batched LLM editor flagging unnatural sk/cs questions; never raises."""

    def __init__(self, model: Optional[str] = None) -> None:
        self.model = model or _CHECK_MODEL
        self._client = None

    async def _complete(self, prompt: str) -> Optional[str]:
        """Single LLM boundary: raw model text, or ``None`` on any failure."""
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self.model)
            response = await self._client.ainvoke(prompt)
            return llm_factory.message_text(response)
        except Exception as exc:
            logger.warning("NaturalnessChecker: LLM call failed (%r)", exc)
            return None

    @staticmethod
    def _build_prompt(questions: Sequence[Question]) -> str:
        lines = [_PROMPT_HEADER]
        for i, q in enumerate(questions, start=1):
            lines.append(f"{i}. [{q.language}] {q.question}")
        return "\n".join(lines)

    @staticmethod
    def _parse(text: str, n: int) -> list[Optional[Naturalness]]:
        """Parse the batched JSON into a list aligned to the input.

        ``None`` for every question the model skipped or answered with an
        inconsistent verdict (flagged without a rewrite, or ok with problems).
        """
        result: list[Optional[Naturalness]] = [None] * n
        cleaned = text.strip()
        start, end = cleaned.find("{"), cleaned.rfind("}") + 1
        if start == -1 or end <= start:
            logger.warning("NaturalnessChecker: no JSON object in response")
            return result
        data = json.loads(cleaned[start:end])
        items = data.get("checks") if isinstance(data, dict) else None
        if not isinstance(items, list):
            logger.warning("NaturalnessChecker: response missing 'checks' list")
            return result

        for item in items:
            if not isinstance(item, dict):
                continue
            try:
                idx = int(item.get("index"))
            except (TypeError, ValueError):
                continue
            ok = item.get("ok")
            problems = [
                {"kind": p["kind"], "quote": str(p.get("quote") or "").strip()}
                for p in item.get("problems") or []
                if isinstance(p, dict) and p.get("kind") in PROBLEM_KINDS
            ]
            rewrite = item.get("rewrite")
            rewrite = rewrite.strip() if isinstance(rewrite, str) else None
            consistent = (ok is True and not problems) or (
                ok is False and problems and rewrite
            )
            if not (1 <= idx <= n) or not consistent:
                continue
            result[idx - 1] = Naturalness(
                ok=ok, problems=problems, rewrite=rewrite if not ok else None
            )

        matched = sum(1 for r in result if r is not None)
        if matched != n:
            logger.warning(
                "NaturalnessChecker: checked %d/%d questions; the rest stay "
                "unchecked",
                matched,
                n,
            )
        return result

    async def check(self, questions: Sequence[Question]) -> list[Optional[Naturalness]]:
        """Check every question in one call; list aligned to ``questions``."""
        n = len(questions)
        if n == 0:
            return []
        try:
            if not llm_factory.chat_available(self.model):
                logger.warning(
                    "NaturalnessChecker unavailable (no key for %s); %d "
                    "questions left unchecked",
                    self.model,
                    n,
                )
                return [None] * n
            text = await self._complete(self._build_prompt(questions))
            if text is None:
                return [None] * n
            verdicts = self._parse(text, n)
            for i, (q, v) in enumerate(zip(questions, verdicts)):
                added = v and v.rewrite and (
                    _foreign_letters(v.rewrite) - _foreign_letters(q.question)
                )
                if added:
                    logger.warning(
                        "NaturalnessChecker: rewrite of %s adds non-Latin letters; "
                        "left unchecked", q.id,
                    )
                    verdicts[i] = None
            return verdicts
        except Exception as exc:  # bulletproof: never propagate into a caller
            logger.warning(
                "NaturalnessChecker failed (%r); %d questions left unchecked",
                exc,
                n,
            )
            return [None] * n

    async def label(
        self, questions: Sequence[Question], batch_size: int = DEFAULT_BATCH_SIZE
    ) -> int:
        """Check in batches and record every verdict; return how many checked."""
        checked = 0
        for i in range(0, len(questions), batch_size):
            batch = questions[i : i + batch_size]
            for q, verdict in zip(batch, await self.check(batch)):
                if verdict is not None:
                    apply_naturalness(q, verdict)
                    checked += 1
        return checked
