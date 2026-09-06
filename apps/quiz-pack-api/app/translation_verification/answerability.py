"""Delta answerability check (#168 — batch translation pipeline SK/CS, DD13/T7).

The existing ``AnswerabilityChecker`` is already the blind round trip, but it
is English-only and has no control leg. Without a control, a model that simply
cannot answer a hard question is indistinguishable from a translation-induced
answer flip, and the false-reject rate is unbounded. So the same model, with
identical settings and in the same submission, answers **both** legs: the
English source (control) and the translated draft (treatment).

Verdicts:
  ``translation_flip`` — EN passed, target failed. Critical, blocks approval.
  ``control_fail``     — EN failed (whether or not the target did). Hard or
                         ambiguous in English too; the translation is not
                         blamed and an EN-approved question is never dropped
                         for it. DD13 evaluates the rules in this order, so a
                         both-legs-failed pair is a control failure, not a
                         "pass" — same non-blocking effect, honest label.
  ``pass``             — both legs passed.
  ``unavailable``      — either leg returned ``check_unavailable``. This is a
                         GATE, so the fail-safe direction inverts: the row
                         stays ``pending`` rather than being approved on a
                         missing judgment.

Both legs are returned so ``question_translations.verification.answerability``
can persist them and a later re-tune can re-score without re-calling the model.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Literal, Optional

from quiz_shared.models.question import Question

from app.generation.pattern_routing import audited_answer_shape
from app.translation_verification.draft import TranslatedDraft
from app.translation_verification.normalize import (
    covers_tokens,
    fold,
    token_overlap,
    tokens,
)
from app.verification.answerability import (
    AnswerabilityChecker,
    AnswerabilityResult,
)

Verdict = Literal["pass", "translation_flip", "control_fail", "unavailable"]

_UNAVAILABLE = "check_unavailable"
_TEXT_OVERLAP_MATCH = 0.6
_KEY_PREFIX_RE = re.compile(r"^\s*(\w{1,2})\s*[).:]\s*(.+)$", re.DOTALL)

# _PROMPT (app/verification/answerability.py) verbatim in structure — question,
# optional OPTIONS block, JSON-only {answer, gave_up, issue} — with the
# instruction text localized and the answer required in the target language.
_PROMPTS: dict[str, str] = {
    "sk": """Si zdatný kvízový hráč. Odpovedz na otázku nižšie. Nemôžeš si nič vyhľadať — použi úsudok, odhad, vylučovaciu metódu a všeobecné vedomosti. Rozhodni sa pre jednu najlepšiu odpoveď a odpovedz po slovensky.

OTÁZKA: {question}
{options_block}
Odpovedz iba vo formáte JSON:
{{"answer": "<tvoja najlepšia odpoveď po slovensky — pri výbere z možností písmeno možnosti>", "gave_up": <true IBA ak sa nevieš rozhodnúť pre žiadnu odpoveď>, "issue": <null, alebo "ambiguous" ak formulácia pripúšťa viac platných výkladov alebo je obhájiteľná viac než jedna možnosť, alebo "unclear" ak sa nedá zistiť, na čo sa otázka pýta>}}""",
    "cs": """Jsi zdatný kvízový hráč. Odpověz na otázku níže. Nemůžeš si nic vyhledat — použij úsudek, odhad, vylučovací metodu a všeobecné znalosti. Rozhodni se pro jednu nejlepší odpověď a odpověz česky.

OTÁZKA: {question}
{options_block}
Odpověz pouze ve formátu JSON:
{{"answer": "<tvoje nejlepší odpověď česky — u výběru z možností písmeno možnosti>", "gave_up": <true POUZE pokud se nedokážeš rozhodnout pro žádnou odpověď>, "issue": <null, nebo "ambiguous" pokud formulace připouští více platných výkladů nebo je obhajitelná více než jedna možnost, nebo "unclear" pokud nelze zjistit, na co se otázka ptá>}}""",
}


@dataclass
class LegResult:
    """One blind attempt: what the model answered and how it was scored."""

    answer: Optional[str]
    passed: bool
    reason: Optional[str]

    @classmethod
    def from_result(cls, result: AnswerabilityResult) -> "LegResult":
        return cls(
            answer=result.model_answer, passed=result.passed, reason=result.reason
        )

    @property
    def unavailable(self) -> bool:
        return self.reason == _UNAVAILABLE


@dataclass
class DeltaAnswerabilityResult:
    """The DD13 pair verdict, in the shape persisted under ``verification``."""

    model: str
    en: LegResult
    target: LegResult
    verdict: Verdict
    checked_at: str

    @property
    def blocks_approval(self) -> bool:
        """A flip is a defect; a missing judgment is not an approval."""
        return self.verdict in ("translation_flip", "unavailable")

    def to_verification_json(self) -> dict:
        return {
            "model": self.model,
            "en": asdict(self.en),
            "target": asdict(self.target),
            "verdict": self.verdict,
            "checked_at": self.checked_at,
        }


def _split_key_prefix(model_answer: str) -> tuple[Optional[str], str]:
    """Split a leading option marker ("a)", "B.", "c:") off the answer text."""
    match = _KEY_PREFIX_RE.match(model_answer)
    if match is None:
        return None, model_answer
    return match.group(1).strip().lower(), match.group(2)


def _options_named(folded_answer: str, folded_options: dict[str, str]) -> set[str]:
    """Keys whose option TEXT occurs as a whole word inside the answer.

    Options nested in another option's text are skipped: naming the longer one
    would otherwise also "name" the shorter, and two keys reject the answer.
    """
    named: set[str] = set()
    for key, option in folded_options.items():
        if not option or any(
            other != key and option in folded_options[other] for other in folded_options
        ):
            continue
        if re.search(rf"(?<!\w){re.escape(option)}(?!\w)", folded_answer):
            named.add(key)
    return named


def _resolve_option_key(
    model_answer: str, possible_answers: dict[str, str]
) -> Optional[str]:
    """The option key the model picked — by letter, by option text, or both.

    Models answer an MCQ in three shapes, all correct: the bare key ("b"), the
    option text ("Venuša"), and the key with its text ("b) Venuša", "B. …",
    "c: …"). Only the first two used to resolve, so the third — the shape a
    model instructed to answer in the target language naturally produces —
    scored as a wrong answer and DD13 read it as a translation flip.

    An answer that names two DIFFERENT options ("a) Fínsko alebo b) Švédsko")
    resolves to nothing: undecided is a wrong answer, not a coin flip.
    """
    by_key = {
        str(key).strip().lower(): str(value) for key, value in possible_answers.items()
    }
    folded_options = {key: fold(value) for key, value in by_key.items()}

    prefix_key, remainder = _split_key_prefix(model_answer)
    picked: set[str] = set()
    if prefix_key is not None and prefix_key in by_key:
        picked.add(prefix_key)
        body = fold(remainder)
    else:
        body = fold(model_answer)
    if not body:
        return prefix_key if len(picked) == 1 else None
    if body in by_key:
        picked.add(body)
    picked |= _options_named(body, folded_options)
    return picked.pop() if len(picked) == 1 else None


def _text_answer_matches(model_answer: str, references: list[str]) -> bool:
    """Unicode-safe leniency: exact, containment, overlap, then SK/CS stems."""
    folded = fold(model_answer)
    if not folded:
        return False
    for reference in references:
        ref = fold(reference)
        if not ref:
            continue
        if folded == ref:
            return True
        # Containment needs a content word on the shorter side: a bare option
        # letter is a substring of half the sentences in the corpus, and for an
        # open item there is no key to legitimise it.
        if (ref in folded or folded in ref) and tokens(min(ref, folded, key=len)):
            return True
        if token_overlap(model_answer, reference) >= _TEXT_OVERLAP_MATCH:
            return True
        if covers_tokens(reference, model_answer):
            return True
    return False


def _classify(en: LegResult, target: LegResult) -> Verdict:
    if en.unavailable or target.unavailable:
        return "unavailable"
    if en.passed and not target.passed:
        return "translation_flip"
    if not en.passed:
        return "control_fail"
    return "pass"


class DeltaAnswerabilityChecker:
    """Control leg on the EN source, treatment leg on the translated draft."""

    def __init__(self, model: Optional[str] = None):
        # One checker instance for both legs — same model, same client, same
        # settings, so the only difference between the legs is the language.
        self._checker = AnswerabilityChecker(model=model)

    @property
    def model(self) -> str:
        return self._checker._model

    async def check(
        self, source: Question, draft: TranslatedDraft, language: str
    ) -> DeltaAnswerabilityResult:
        if language not in _PROMPTS:
            raise ValueError(
                f"no localized answerability prompt for language {language!r}"
            )
        en = LegResult.from_result(await self._checker.check(source))
        target = await self._check_target(source, draft, language)
        return DeltaAnswerabilityResult(
            model=self.model,
            en=en,
            target=target,
            verdict=_classify(en, target),
            checked_at=datetime.now(timezone.utc).isoformat(),
        )

    async def _check_target(
        self, source: Question, draft: TranslatedDraft, language: str
    ) -> LegResult:
        """The EN leg's logic on the draft: localized prompt, SK/CS comparison."""
        options_block = ""
        if draft.possible_answers:
            rendered = " | ".join(
                f"{str(k).lower()}) {v}" for k, v in draft.possible_answers.items()
            )
            options_block = f"OPTIONS: {rendered}\n"
        raw = await self._checker._complete(
            _PROMPTS[language].format(
                question=draft.question, options_block=options_block
            )
        )
        data = self._checker._parse(raw) if raw is not None else None
        if data is None or "answer" not in data:
            return LegResult(answer=None, passed=False, reason=_UNAVAILABLE)

        model_answer = str(data.get("answer") or "").strip()
        if data.get("gave_up") is True:
            return LegResult(
                answer=model_answer or None, passed=False, reason="unanswerable"
            )
        if not model_answer:
            return LegResult(answer=None, passed=False, reason=_UNAVAILABLE)
        issue = data.get("issue")
        if isinstance(issue, str) and issue.strip().lower() in ("ambiguous", "unclear"):
            return LegResult(
                answer=model_answer,
                passed=False,
                reason=f"flagged_{issue.strip().lower()}",
            )

        # Open shapes keep the EN leg's leniency (#160): a sentence answer
        # cannot be fuzzy-matched meaningfully in any language.
        if audited_answer_shape(source) == "open":
            return LegResult(answer=model_answer, passed=True, reason=None)

        if draft.possible_answers:
            picked = _resolve_option_key(model_answer, draft.possible_answers)
            matched = (
                picked is not None
                and picked == str(draft.correct_answer_key or "").strip().lower()
            )
        else:
            references = [draft.correct_answer, *(draft.alternative_answers or [])]
            matched = _text_answer_matches(model_answer, [str(r) for r in references])
        if matched:
            return LegResult(answer=model_answer, passed=True, reason=None)
        return LegResult(answer=model_answer, passed=False, reason="wrong_answer")
