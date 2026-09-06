"""MQM-Quiz judge over a (source_question, translated_draft, language) triple.

Issue #168 — batch translation pipeline SK/CS, tasks T8/T9 (DD6, DD12).

Nothing in this repo scores a source/target pair, so this stage is built, not
adopted — except for its *contract*, which is deliberately the fail-**closed**
one from ``app/verification/fact_verifier.py`` (``VerificationResult:69-83``,
``_held():337-345``): a missing key, a dead call, a refusal or an unparseable
reply is never evidence that a translation is fine, so the row is held and
stays ``pending``. It is never approved on the judge's silence.

What the judge decides (the deterministic guards and the blind answerability
check are separate stages — this one is about *translation quality*):
calques, idioms, naturalness and register, titles and proper nouns, and the
answer-integrity failures those cause. Severity is MQM-shaped —
``critical | major | minor`` — and **critical blocks approval**
(``approval_status``); major/minor ride along in ``verification`` JSONB for
the human review loop.

The per-language glossary (``glossary/sk.json``, ``glossary/cs.json``) is a
reviewed git artefact curated from the correction histogram (DD3). It is read
into the prompt, never written by this module — an auto-derived glossary would
put unreviewed corrections back into the gate.

Validated per DD6 by ``scripts/translation_judge_eval.py`` against
``docs/testing/translation-defect-reference-{sk,cs}.json``.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from quiz_shared.llm import factory as llm_factory

logger = logging.getLogger(__name__)

Severity = Literal["critical", "major", "minor"]

#: Frontier-class role. Judging a source/target pair is a reasoning task on two
#: languages at once; the flash-class answerability model is not it. Under
#: ``LLM_GATEWAY=session`` (#169 — Session gateway) this id maps to Opus on the
#: Claude Code subscription, so the eval runs cost no API credits.
_DEFAULT_MODEL = os.getenv("TRANSLATION_JUDGE_MODEL") or llm_factory.CRITIQUE

_GLOSSARY_DIR = Path(__file__).resolve().parent / "glossary"

_LANGUAGE_NAMES = {"sk": "Slovak", "cs": "Czech"}
#: The neighbouring language whose forms leak in (real defect sk-r05).
_NEIGHBOUR = {"sk": "Czech", "cs": "Slovak"}


@dataclass
class Finding:
    """One MQM-Quiz defect. ``category`` matches the reference-set vocabulary."""

    category: str
    severity: Severity
    span: str
    note: str

    def as_dict(self) -> dict[str, str]:
        return {
            "category": self.category,
            "severity": self.severity,
            "span": self.span,
            "note": self.note,
        }


@dataclass
class JudgeResult:
    """Fail-closed verdict (``fact_verifier.VerificationResult`` contract).

    ``verdict == "unverified"`` with ``held_for_review`` is what an unavailable
    or unparseable judge returns — it must never read as "ok".
    """

    verdict: Literal["ok", "defects", "unverified"]
    findings: list[Finding] = field(default_factory=list)
    held_for_review: bool = False
    notes: str = ""
    cost_cents: float = 0.0

    @property
    def has_critical(self) -> bool:
        return any(f.severity == "critical" for f in self.findings)

    @property
    def blocks_approval(self) -> bool:
        """Critical blocks; so does a held (unavailable) judge."""
        return self.held_for_review or self.has_critical

    def as_verification_json(self) -> dict[str, Any]:
        """The ``question_translations.verification`` fragment for this stage."""
        return {
            "verdict": self.verdict,
            "held_for_review": self.held_for_review,
            "findings": [f.as_dict() for f in self.findings],
            "notes": self.notes,
            "cost_cents": self.cost_cents,
        }


def approval_status(
    *, guards_ok: bool, answerable: bool, judge: JudgeResult
) -> Literal["approved", "pending", "rejected"]:
    """Map the three *blocking* gate stages onto a row status.

    The regional-relevance flag is deliberately **not** a parameter: locked
    decision 3(d) says it flags and never drops, and the cheapest way to keep
    that true forever is for the decision to have no way of reading it.

    ``pending`` (not ``rejected``) for a held judge: the row is unjudged, not
    judged bad, and a retry can still approve it.
    """
    if judge.held_for_review or judge.verdict == "unverified":
        return "pending"
    if not guards_ok or not answerable or judge.has_critical:
        return "rejected"
    return "approved"


def load_glossary(language: str) -> list[dict[str, Any]]:
    """Read the reviewed glossary file. Missing/broken file → no entries."""
    path = _GLOSSARY_DIR / f"{language}.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        logger.warning("Glossary %s unreadable — judging without it", path)
        return []
    entries = data.get("entries") or []
    return [e for e in entries if isinstance(e, dict)]


_PROMPT = """You are an MQM-Quiz reviewer for a voice-first trivia app. You are given an English quiz item and its {language_name} translation. Find translation defects. Be adversarial about defects that break the game, and conservative about matters of taste.

A player hears the {language_name} question aloud and answers aloud in {language_name}. Their spoken answer is graded against the {language_name} correct answer.

SEVERITY — assign by consequence, not by how wrong it feels:
- "critical": a {language_name} player is harmed. The answer is changed, revealed by the question, made ungradable or unrecognisable, a number/unit/date no longer matches the source, an option set no longer matches the source, the item is unplayable ({language_name} text is truncated, or left in English so it cannot be answered in {language_name}), OR the {language_name} wording asks about something that does not exist and the stated answer is simply false in {language_name}. Apply one test before you settle for a lower severity: would a {language_name} speaker who knows the subject perfectly still answer this correctly and be graded right? If not, it is critical, however small the wrong word looks.
- "major": clearly wrong language that a native speaker would correct — a word or grammatical form from {neighbour}, an English spelling kept where {language_name} has an established form, a foreign term left untouched where {language_name} has a normal word for it, a wrongly declined or wrongly inflected name, a literal calque of an English phrase. The item is still playable and still gradable.
- "minor": register, word choice or rhythm a native would phrase differently. Nothing is wrong.

DEFECT CATEGORIES (use exactly one per finding):
answer_flip · answer_leak · unit_change · untranslated_string · title_mistranslation · mcq_options_translated · idiom_calque · lexical_calque · register_calque · fluency_grammar · related_language_interference · truncated_output · other

WHAT TO HUNT:
1. Answer integrity. Does the {language_name} correct answer still denote the same thing as the English one? Did the correct option key move? Does the explanation still support the correct answer? → answer_flip, critical.
2. Answer leaked. Translating or localising a proper noun *in the question* can hand the player the answer (English "Joachimsthal" localised to the {language_name} exonym when the answer is that very place or the word derived from it). → answer_leak, critical.
3. Titles and names. Films, songs, books, bands, products: keep the original title unless an official {language_name} release title is certain. Inventing a title, or translating a title literally, is critical when that title is the answer (the player says the real title and is graded wrong) and major otherwise. Names of bands and brands that do not inflect must not be declined ("Queen" → "Queenina"). → title_mistranslation / fluency_grammar.
4. Options. The option keys, their count and their order must match the source. Option values must be translated when they are ordinary words ("True"/"False"), and must be kept verbatim when they are titles, band names or other strings the player must say in the original. Translating those is critical (the spoken original no longer matches); leaving ordinary words in English is critical too (a {language_name} speaker cannot answer them). → mcq_options_translated / untranslated_string.
5. Numbers, dates and units. Every figure in the source must survive unchanged; a converted or altered unit is a different question. → unit_change, critical.
6. Untranslated or half-translated text. Whole sentences left in English, or a foreign term left as-is where {language_name} has an established word for it. Judge the consequence: unplayable → critical, merely lazy → major. → untranslated_string.
7. Calques and idioms. English idioms rendered word for word ("cheap as dirt"), collective nouns and wordplay that only work in English, an English sense of a word carried over into a {language_name} word that does not have it, English syntax worn as {language_name}. Severity by the same test: a calqued term that names a category which does not exist in {language_name}, or a question whose answer holds only as an English lexical fact, is critical — the {language_name} question asks something unanswerable and grades a knowledgeable player wrong. A clumsy but understandable literal phrase is major; a merely stiff turn of phrase is minor. → idiom_calque / lexical_calque / register_calque.
8. Language purity and grammar. Any word or inflection from {neighbour} inside {language_name} output; wrong case, agreement or gender. → related_language_interference / fluency_grammar.
9. Truncation. A fragment served as the whole question or answer. → truncated_output, critical.

DO NOT FLAG (these are correct translations, and calling them defects is the failure this review is scored on):
- A faithful translation that reorders words, drops English articles, or picks a natural {language_name} construction instead of the English one.
- An original title, band name or proper noun kept in its source form when no official {language_name} form exists — keeping it is the rule, not a defect.
- Ordinary words correctly localised, including option values like "True"/"False".
- A correct {language_name} exonym for a place, when the answer does not depend on that name.
- The explanation being rephrased rather than translated literally, as long as it still supports the same answer.
- Anything you merely would have worded differently, unless you can name the concrete harm.

GLOSSARY (reviewed {language_name} terminology; an entry with target null means keep the source form):
{glossary_block}

=== ENGLISH SOURCE ===
{source_block}

=== {language_upper} TRANSLATION ===
{target_block}

Respond with ONLY a single JSON object:
{{"findings": [{{"category": "...", "severity": "critical|major|minor", "span": "the exact offending {language_name} text", "note": "one sentence: what is wrong and what harm it causes"}}], "overall": "ok|defects"}}
An empty findings list with "overall": "ok" is the right answer for a clean translation."""


def _render_payload(payload: dict[str, Any]) -> str:
    lines = [f"question: {payload.get('question', '')}"]
    options = payload.get("possible_answers")
    if options:
        rendered = " | ".join(f"{k}) {v}" for k, v in options.items())
        lines.append(f"options: {rendered}")
        if payload.get("correct_answer_key"):
            lines.append(f"correct_answer_key: {payload['correct_answer_key']}")
    lines.append(f"correct_answer: {payload.get('correct_answer', '')}")
    alternatives = payload.get("alternative_answers")
    if alternatives:
        lines.append(f"alternative_answers: {', '.join(map(str, alternatives))}")
    if payload.get("explanation"):
        lines.append(f"explanation: {payload['explanation']}")
    return "\n".join(lines)


def _render_glossary(entries: list[dict[str, Any]]) -> str:
    if not entries:
        return "(no reviewed entries yet — judge on the rules above alone)"
    return "\n".join(
        f"- {e.get('source')} -> {e.get('target') if e.get('target') else 'KEEP AS-IS'}"
        f"{' (' + e['note'] + ')' if e.get('note') else ''}"
        for e in entries
    )


class TranslationJudge:
    """One MQM-Quiz call per (question, language) pair."""

    def __init__(self, model: str | None = None):
        self._model = model or _DEFAULT_MODEL
        self._client = None

    async def judge(
        self,
        source_question: dict[str, Any],
        translated_draft: dict[str, Any],
        language: str,
    ) -> JudgeResult:
        """Score one translation. Any failure holds the row (never approves)."""
        language_name = _LANGUAGE_NAMES.get(language, language)
        prompt = _PROMPT.format(
            language_name=language_name,
            language_upper=language_name.upper(),
            neighbour=_NEIGHBOUR.get(language, "a closely related language"),
            glossary_block=_render_glossary(load_glossary(language)),
            source_block=_render_payload(source_question),
            target_block=_render_payload(translated_draft),
        )
        try:
            if self._client is None:
                self._client = llm_factory.chat_model(self._model)
            response = await self._client.ainvoke(prompt)
            raw = llm_factory.message_text(response)
        # Broad on purpose: this is the call boundary, and every failure holds
        # the row rather than approving it.
        except Exception:
            logger.warning("MQM-Quiz judge call failed", exc_info=True)
            return _held("judge call failed (provider error or refusal)")
        parsed = _parse(raw)
        if parsed is None:
            logger.warning("MQM-Quiz judge reply unparseable: %.200r", raw)
            return _held("judge reply had no parseable findings JSON")
        return parsed


def _held(reason: str) -> JudgeResult:
    return JudgeResult(verdict="unverified", held_for_review=True, notes=reason)


def _parse(raw: str | None) -> JudgeResult | None:
    if not raw:
        return None
    cleaned = raw.strip()
    if cleaned.startswith("```"):
        cleaned = cleaned.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    start, end = cleaned.find("{"), cleaned.rfind("}") + 1
    if start == -1 or end <= start:
        return None
    try:
        data = json.loads(cleaned[start:end])
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or "findings" not in data:
        return None
    findings = []
    for item in data.get("findings") or []:
        if not isinstance(item, dict):
            continue
        severity = str(item.get("severity", "")).strip().lower()
        if severity not in ("critical", "major", "minor"):
            # An unknown severity is not a licence to drop the finding; the
            # safe reading of "the judge saw something" is the blocking one.
            severity = "critical"
        findings.append(
            Finding(
                category=str(item.get("category") or "other").strip().lower(),
                severity=severity,  # type: ignore[arg-type]
                span=str(item.get("span") or ""),
                note=str(item.get("note") or ""),
            )
        )
    return JudgeResult(verdict="defects" if findings else "ok", findings=findings)
