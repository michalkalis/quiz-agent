"""GenerationStage — thin wrapper around AdvancedQuestionGenerator (issue #36 task 2.5).

Best-of-N and the LLM judge stay coupled inside `AdvancedQuestionGenerator`
(#32 §1.2 keep-list), so this stage is intentionally thin: it maps
`OrderContext` → the generator's existing `generate_questions` kwargs and
post-processes the returned questions with order-level metadata the
generator itself doesn't know about — `prompt_seed`, `language`, and
the `source_url`/`source_excerpt` carry-over from `Fact` references that
F8 (task 2.15) + the e2e assertion in task 2.11 depend on.
"""

from __future__ import annotations

import hashlib
import logging
import uuid
from datetime import datetime, timezone

from app import feature_flags
from app.generation.advanced_generator import AdvancedQuestionGenerator
from app.generation.answer_normalizer import AnswerNormalizer
from app.generation.classification import normalize_category, normalize_difficulty
from app.generation.mcq_answer import is_bare_option_key, resolve_mcq_answer
from app.generation.expiry_classifier import (
    CONTENT_CLASS_TTL,
    Classification,
    ExpiryClassifier,
)
from app.generation import inline_options
from app.generation.pattern_routing import (
    MCQ_ONLY_PATTERNS,
    PATTERNS_TO_MCQ,
    choose_question_type,
    normalize_mcq_pattern,
)
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.verification.shape_classifier import ShapeClassifier
from app.scoring.multi_model_scorer import _ANSWER_TAIL_MARKERS, _ANSWER_WORD_CAP
from quiz_shared.models.question import GenerationProvenance, Question

logger = logging.getLogger(__name__)

# Issue #46 task 46.B4c — fraction of `target_count` routed to the open-shape
# slice (generated through `question_generation_open.md`, 46.B3/B4b). The
# 755-question audit found open/lateral-puzzle shapes are ~4% of demand, so the
# orchestrated path mirrors that by default. Exposed as a ctor override so the
# product fraction can be tuned without touching call sites.
OPEN_SHAPE_FRACTION = 0.04

# Issue #72 P1.5 — smallest order that is guaranteed to carry the open slice.
# At the default 4% fraction `round(target * 0.04)` is 0 for every order up to
# 12 questions, so the open/lateral branch was dead at the most common order
# size (a standard 10-question pack). At or above this threshold the open count
# is floored to 1 so a standard order always gets ≥1 open question; smaller
# packs (1-9) keep rounding to zero and stay entirely factual, since open is a
# ~4% minority shape and forcing 1/5 would be 20%, far above the target slice.
OPEN_SHAPE_MIN_ORDER = 10


def _is_uuid(value: str) -> bool:
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError, AttributeError):
        return False


def _violates_answer_brevity(answer: object) -> str | None:
    """Return a reason string if the answer breaks 42.5/42.7 brevity rules.

    Pure regex/token check (no LLM, per CLAUDE.md rule #5). Mirrors the
    constraints encoded in the v2/v3 prompts: hard cap at 10 words, no
    em/en-dash, no `because` / `namely` / `i.e.` / `which means`. Returns
    `None` when the answer is acceptable so the caller can log the reason
    alongside the dropped question id.
    """
    if answer is None:
        return "empty_answer"
    text = ", ".join(str(a) for a in answer) if isinstance(answer, list) else str(answer)
    if not text.strip():
        return "empty_answer"
    if len(text.split()) > _ANSWER_WORD_CAP:
        return f"over_word_cap_{_ANSWER_WORD_CAP}"
    lowered = text.lower()
    for marker in _ANSWER_TAIL_MARKERS:
        if marker in lowered:
            return f"tail_marker:{marker.strip() or marker!r}"
    return None


# Issue #46 task 46.A2 — deterministic split markers for normalize-then-drop.
# Only UNAMBIGUOUS markers: an em/en-dash or one of these connectives always
# introduces an explanatory tail after a canonical head. A bare comma is
# deliberately excluded — it is structural in legitimate short answers
# ("Tokyo, Japan", "December 7, 1941", "salt, pepper, flour"), so comma-tailed
# verbose answers are NOT split here; they route to the LLM normalization
# fallback (46.A2b) where "canonical head vs. one indivisible answer?" is a
# judgment call (CLAUDE.md rule #5). Word markers carry surrounding spaces so
# they never match inside a longer token.
_DETERMINISTIC_SPLIT_MARKERS = (
    "—",  # em-dash
    "–",  # en-dash
    " because ",
    " while ",
    " namely ",
    " due to ",
    " i.e.",
)


def _split_answer_head(answer: str) -> tuple[str, str] | None:
    """Deterministically split a verbose answer into (head, explanation_tail).

    Returns the canonical short head and the explanatory tail when a clean
    head sits before the earliest unambiguous tail marker; returns ``None``
    when no marker is present or the head is itself empty/over the word cap
    (i.e. there is no recoverable short answer — the caller must drop or defer
    to the LLM fallback). Never splits on a bare comma.
    """
    lowered = answer.lower()
    earliest: tuple[int, int] | None = None  # (index, marker_len)
    for marker in _DETERMINISTIC_SPLIT_MARKERS:
        idx = lowered.find(marker)
        if idx > 0 and (earliest is None or idx < earliest[0]):
            earliest = (idx, len(marker))
    if earliest is None:
        return None
    idx, _mlen = earliest
    head = answer[:idx].strip(" ,;:")
    # Strip the dash glyph from a tail's lead but keep connective words
    # ("because the wall…") so the explanation reads naturally.
    tail = answer[idx:].lstrip(" —–").strip()
    if not head or _violates_answer_brevity(head) is not None:
        return None
    return head, tail


def _merge_explanation(existing: str | None, tail: str) -> str:
    """Append a recovered answer tail to any existing explanation."""
    existing = (existing or "").strip()
    if not existing:
        return tail
    return f"{existing} {tail}".strip()


def _compute_prompt_seed(
    prompt: str, language: str, category: str | None, theme: str | None
) -> str:
    """Deterministic 16-char hash grouping questions from one user prompt."""
    payload = f"{prompt}|{language}|{category or ''}|{theme or ''}"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:16]


class GenerationStage:
    """Calls AdvancedQuestionGenerator.generate_questions; stores Questions on ctx."""

    name = "generating"

    def __init__(
        self,
        generator: AdvancedQuestionGenerator,
        answer_normalizer: AnswerNormalizer | None = None,
        expiry_classifier: ExpiryClassifier | None = None,
        open_fraction: float = OPEN_SHAPE_FRACTION,
        shape_classifier: ShapeClassifier | None = None,
    ) -> None:
        self._generator = generator
        # Issue #46 task 46.A2b — optional LLM normalizer for the ambiguous
        # comma-tailed remainder the deterministic splitter can't recover.
        # `None` keeps the 46.A2 fail-safe behaviour (those answers drop).
        self._answer_normalizer = answer_normalizer
        # Issue #76 F-3b — optional batched expiry classifier. `None` (default)
        # keeps behaviour byte-identical to pre-#76: expiry left unset. When
        # present it classifies each question's temporal freshness so the
        # stamping loop below can set `expires_at`/`freshness_tag`.
        self._expiry_classifier = expiry_classifier
        # Issue #46 task 46.B4c — fraction of `target_count` generated through
        # the open/lateral-puzzle prompt instead of the factual pipeline.
        self._open_fraction = open_fraction
        # #160 — independent answer-blind auditor of the `logical_puzzle`
        # marker (P4: no model-controlled routing). `None` skips the audit —
        # unit tests and callers that never produce open-branch puzzles.
        self._shape_classifier = shape_classifier

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        topics = [t for t in (ctx.category, ctx.theme) if t] or None
        categories = [ctx.category] if ctx.category else None

        # Issue #46 task 46.B4c — route the open-shape slice (~4% per audit) of
        # the order through `question_generation_open.md`; the generator emits
        # `headline_answer` + tags pure lateral puzzles `pipeline=logical_puzzle`
        # (46.B4b). Issue #72 P1.5 — bare `round` dropped the slice to zero on a
        # standard order (round(10 * 0.04) == 0), leaving the branch dead at the
        # most common size. Floor at 1 once the order is at least a standard pack
        # (`OPEN_SHAPE_MIN_ORDER`) while keeping `round`'s proportional ~4% slice
        # at scale; smaller orders still round to zero and stay factual.
        open_count = round(ctx.target_count * self._open_fraction)
        if open_count == 0 and ctx.target_count >= OPEN_SHAPE_MIN_ORDER:
            open_count = 1

        questions = await self._generator.generate_questions(
            count=ctx.target_count,
            open_count=open_count,
            # #166 D21b — best-of-N (overgen + critique + pairwise duels) is
            # flag-gated and OFF by default: on D21b data critique predicted
            # neither fun nor factuality, duels were ruled out in D21 (#164).
            # BEST_OF_N=1 restores the full selection pipeline.
            enable_best_of_n=feature_flags.best_of_n(),
            # 2026-07-27 live-run F-e: None = mixed batch with per-question
            # assessment; an explicit order difficulty becomes the prompt's
            # target level (the model still reports its honest per-question
            # value, normalized below).
            difficulty=ctx.difficulty,
            topics=topics,
            categories=categories,
            source_facts=ctx.facts or None,
            # Issue #42 task 42.9b — the generator passes these into the
            # `{mcq_patterns_section}` of the prompt so the LLM emits
            # `possible_answers` + key-letter `correct_answer` for any
            # MCQ-routed pattern. The downstream 42.9a step (below) then
            # tags the question type from the LLM's chosen pattern.
            mcq_patterns=set(PATTERNS_TO_MCQ),
            # #42 task 42.20 blocker fix (root cause D): the order prompt is
            # never handed to the generation LLM, so MCQ emphasis travels as
            # this explicit bool and the generator injects the hard quota
            # into `{mcq_patterns_section}` itself.
            mcq_emphasis=ctx.mcq_emphasis,
            # V18 (2026-07-30) — the gold-bias exemplar sampler keys off
            # `question_type == "text_multichoice"`
            # (`app/generation/examples.py:76`) and the example pack is built
            # ONCE per invocation (`advanced_generator.py:445`), before the MCQ
            # sub-batch fan-out. Leaving this at the "text" default meant
            # MCQ-emphasis orders got type-blind exemplars — the MCQ sub-batches
            # never saw the option-dict payload shape. `ctx.mcq_emphasis` is the
            # trigger because `mcq_patterns` above is a constant (non-empty on
            # every order, so it can't discriminate) and emphasis is the same
            # flag the generator itself gates its MCQ path on
            # (`advanced_generator.py:482`).
            question_type="text_multichoice" if ctx.mcq_emphasis else "text",
        )

        prompt_seed = _compute_prompt_seed(
            ctx.prompt, ctx.language, ctx.category, ctx.theme
        )
        # Issue #76 F-3b — one batched expiry classification per run. Dormant
        # when no classifier is injected (map stays empty → nothing stamped,
        # byte-identical to pre-#76). The classifier is fail-safe by contract:
        # it never raises and returns `None` for any question it couldn't
        # classify, so a classification failure leaves expiry unset, never
        # blocking generation. Keyed by object identity because ids are
        # normalised to UUIDs inside the loop below.
        expiry_by_question: dict[int, Classification | None] = {}
        if self._expiry_classifier is not None:
            classifications = await self._expiry_classifier.classify(questions)
            expiry_by_question = {
                id(q): c for q, c in zip(questions, classifications)
            }
        now = datetime.now(timezone.utc)

        for q in questions:
            # AdvancedQuestionGenerator inherits the Phase 1 `q_<hex>` id
            # convention from `app/generation/storage.py`; PersistStage's
            # `_coerce_uuid` (app/db/models/question.py:141) refuses non-UUID
            # ids on purpose. Normalise at the stage boundary so the rest of
            # the orchestrator can rely on uuid-shaped ids.
            if not _is_uuid(q.id):
                q.id = str(uuid.uuid4())

            q.prompt_seed = prompt_seed
            q.language = ctx.language

            # 2026-07-27 live-run F-e: the model now emits per-question
            # difficulty/category; normalize fail-safe so an off-vocabulary
            # value can never reach Postgres (difficulty → easy|medium|hard,
            # category → taxonomy id, with an explicit order category winning).
            q.difficulty = normalize_difficulty(
                q.difficulty, default=ctx.difficulty or "medium"
            )
            q.category = normalize_category(q.category, order_category=ctx.category)

            provenance = q.generation_metadata or GenerationProvenance()
            # #160: never clobber the open branch's `logical_puzzle` marker —
            # it is the server-audited routing signal (the old label-tagging
            # loop used to restore it afterwards; that loop is gone).
            if ctx.facts and provenance.pipeline != "logical_puzzle":
                provenance = provenance.model_copy(update={"pipeline": "fact_first"})
            q.generation_metadata = provenance

            # #153 round-2: the old "pack_fallback" stamping (a sibling fact's
            # URL copied onto any question the generator couldn't attribute)
            # is GONE. It defeated F8's purpose — an ungrounded question
            # sailed through with a fake citation (seed-153 q26: an invented
            # logic puzzle with a WRONG answer shipped citing the Mariana
            # Trench Wikipedia page). Unattributable factual questions are now
            # dropped below instead of dressed up.

            # Issue #76 F-3b — stamp expiry from the content class. `current` /
            # `semi-stable` expire at `now + TTL` (timezone-aware UTC, which the
            # TIMESTAMPTZ column stores directly) tagged with the class;
            # `evergreen` (TTL None) and unclassified questions leave both
            # `expires_at`/`freshness_tag` untouched (None).
            classification = expiry_by_question.get(id(q))
            if classification is not None:
                ttl = CONTENT_CLASS_TTL[classification.content_class]
                if ttl is not None:
                    q.expires_at = now + ttl
                    q.freshness_tag = classification.content_class

        # Issue #42 task 42.7 + #46 task 46.A2 — post-generation brevity
        # validator, now **normalize-then-drop** instead of drop-only. A
        # `correct_answer` with a clean short head before an unambiguous tail
        # marker (em/en-dash, "because", "while", …) is split: head stays in
        # `correct_answer`, tail moves to `explanation` so nothing is lost. A
        # question is dropped only when no recoverable short head exists (the
        # comma-tailed ambiguous remainder defers to the LLM fallback, 46.A2b).
        # `dropped_quality` / `normalized_quality` are surfaced via
        # StageResult.info so SSE clients + the audit trail see the activity,
        # mirroring DedupStage.
        kept: list[Question] = []
        dropped_quality = 0
        normalized_quality = 0
        for q in questions:
            reason = _violates_answer_brevity(q.correct_answer)
            if reason is None:
                kept.append(q)
                continue
            split = (
                _split_answer_head(q.correct_answer)
                if isinstance(q.correct_answer, str)
                else None
            )
            if split is not None:
                head, tail = split
                q.explanation = _merge_explanation(q.explanation, tail)
                q.correct_answer = head
                normalized_quality += 1
                logger.info(
                    "GenerationStage normalized question id=%s head=%r reason=%s",
                    q.id,
                    head,
                    reason,
                )
                kept.append(q)
                continue
            # 46.A2b — deterministic split failed (comma-tailed / no marker).
            # Defer to the optional LLM normalizer for the judgment call
            # "canonical head + appositive vs. one indivisible answer?". It
            # fail-safes to None (→ drop) when unavailable or low-confidence,
            # so nothing is normalized to a guess.
            if self._answer_normalizer is not None and isinstance(
                q.correct_answer, str
            ):
                normalized = await self._answer_normalizer.normalize(
                    q.question, q.correct_answer
                )
                if normalized is not None:
                    if normalized.explanation:
                        q.explanation = _merge_explanation(
                            q.explanation, normalized.explanation
                        )
                    q.correct_answer = normalized.head
                    normalized_quality += 1
                    logger.info(
                        "GenerationStage LLM-normalized question id=%s head=%r "
                        "reason=%s",
                        q.id,
                        normalized.head,
                        reason,
                    )
                    kept.append(q)
                    continue
            dropped_quality += 1
            logger.warning(
                "GenerationStage dropped question id=%s reason=%s answer=%r",
                q.id,
                reason,
                q.correct_answer,
            )

        # Issue #42 task 42.9a — post-generation type tagging for MCQ.
        # The LLM picks the reasoning pattern per question (stored on the
        # provenance as `reasoning_pattern`); if that pattern is in the MCQ
        # set, the question must surface as `text_multichoice` so the iOS
        # `MCQOptionPicker` activates and the evaluator's fast-path routes
        # by `possible_answers`. Drop fail-loud when a question requires MCQ
        # but the options aren't well-formed — a half-built MCQ is worse
        # than no MCQ (evaluator would silently degrade to free-text and the
        # iOS UI would have nothing to show).
        # Pilot 2026-07-11 hardening: the guard must also cover MCQs the
        # model self-tagged under an off-list `reasoning_pattern` label
        # (`choose_question_type` fail-safes those to "text", which used to
        # bypass the check entirely) and must reject blank option texts or
        # an answer that resolves to no option — both shipped bare-letter
        # answers to founder review.
        # Founder blind rating 2026-09-03 — deterministic inline-option repair,
        # BEFORE the type tagging below so the routing sees the real structure.
        # A question that recites "closer to 400 years, 1,400 years, or 3,800
        # years?" inside a `text` stem is an MCQ the model forgot to declare;
        # the player had to speak a bucket the voice grader then had to match,
        # and iOS never raised the option picker. Pure function, no LLM call,
        # and it never guesses: an answer that resolves to no single option
        # leaves the question exactly as generated.
        inline_counts = inline_options.apply_to_questions(kept)

        tagged: list[Question] = []
        dropped_mcq_missing_options = 0
        mcq_label_kept_as_text = 0
        for q in kept:
            pattern = (
                q.generation_metadata.reasoning_pattern
                if q.generation_metadata is not None
                else None
            )
            desired_type = choose_question_type(pattern)
            # #160: structure outranks the label — a question that CARRIES
            # options is an MCQ whatever the model called it (a half-MCQ
            # served as free text is the same defect the guard exists for).
            if (
                desired_type == "text_multichoice"
                or q.type == "text_multichoice"
                or q.possible_answers
            ):
                resolved_answer = resolve_mcq_answer(
                    q.possible_answers, q.correct_answer
                )
                if resolved_answer is None:
                    # 2026-09-03: the `Pattern NN` label fix above re-activated
                    # this route for labels that used to miss it entirely, so
                    # the drop must not widen with it. With NO options at all
                    # there is nothing half-built to reject — only a label
                    # claiming a shape the question never had — so the
                    # free-text question is kept rather than deleted on the
                    # strength of the model's own untrusted self-report
                    # (#160). The decision reads structure and answer shape,
                    # never `q.type` — that field is the model's self-report
                    # too. Two shapes are NOT usable as free text and still
                    # drop: `true_false` (whose spoken answer is the word
                    # "True") and a bare option key ("c"), the pilot
                    # 2026-07-11 gemini shape.
                    if (
                        not q.possible_answers
                        and not is_bare_option_key(q.correct_answer)
                        and normalize_mcq_pattern(pattern) not in MCQ_ONLY_PATTERNS
                    ):
                        mcq_label_kept_as_text += 1
                        logger.info(
                            "GenerationStage kept question id=%s as text "
                            "(pattern=%s claims MCQ, no options to build one)",
                            q.id,
                            pattern,
                        )
                        tagged.append(q)
                        continue
                    dropped_mcq_missing_options += 1
                    logger.warning(
                        "GenerationStage dropped question id=%s reason=mcq_missing_options "
                        "pattern=%s answer=%r options=%r",
                        q.id,
                        pattern,
                        q.correct_answer,
                        q.possible_answers,
                    )
                    continue
                q.type = "text_multichoice"
                q.correct_answer = resolved_answer
                tagged.append(q)
            else:
                tagged.append(q)

        # #160 (gen-review P4, supersedes the 46.B4 label-tagging loop): the
        # `logical_puzzle` marker — which exempts a question from F8 grounding
        # AND routes it past web fact-checking to the consistency judge — may
        # only originate from the server-controlled open branch (the generator
        # stamps it in `_finalize_questions` for the `open_count` slice). The
        # old loop here re-derived it from the model's own `pattern_used`
        # label for EVERY question, so a generator labelling a factual claim
        # `lateral_thinking` skipped the only truth gate. Now the stage
        # AUDITS instead: each marker candidate gets an independent
        # answer-blind classification (no answer, no label in the prompt);
        # anything the classifier does not confirm as a self-contained puzzle
        # — including classifier outages — is demoted to the stricter factual
        # path (fail-closed).
        demoted_puzzles = 0
        if self._shape_classifier is not None:
            for q in tagged:
                if (
                    q.generation_metadata is None
                    or q.generation_metadata.pipeline != "logical_puzzle"
                ):
                    continue
                verdict = await self._shape_classifier.classify(
                    q.question, q.possible_answers
                )
                if verdict == "logical":
                    continue
                demoted_puzzles += 1
                logger.warning(
                    "GenerationStage demoted logical_puzzle id=%s to factual "
                    "(classifier verdict=%s) — routed to web verification/F8 "
                    "(#160)",
                    q.id,
                    verdict,
                )
                q.generation_metadata = q.generation_metadata.model_copy(
                    update={"pipeline": None}
                )

        # #153 round-2: enforce grounding by dropping, not decorating. A
        # factual-mode question that ends up with no source_url, or whose URL
        # is only a fallback stamp ("unmatched_fallback" = the generator found
        # no fact sharing ≥2 content words), is ungrounded — the model
        # invented it or paraphrased beyond recognition. Shipping it with a
        # sibling fact's citation is how seed-153 q26/q29 got Mariana-Trench
        # sources on logic puzzles. Logical puzzles themselves are legitimate
        # inventions: they keep flowing to the consistency judge, but any
        # fallback-stamped URL on them is cleared (fake by construction).
        # Direct-generation mode has no facts to ground against — skip.
        grounded: list[Question] = []
        dropped_ungrounded = 0
        if ctx.facts and not ctx.direct_generation:
            for q in tagged:
                extra = (
                    dict(q.generation_metadata.extra)
                    if q.generation_metadata is not None
                    else {}
                )
                fallback_marked = (
                    extra.get("source_attribution") == "unmatched_fallback"
                )
                is_puzzle = (
                    q.generation_metadata is not None
                    and q.generation_metadata.pipeline == "logical_puzzle"
                )
                if is_puzzle:
                    if fallback_marked:
                        q.source_url = None
                        q.source_excerpt = None
                    grounded.append(q)
                    continue
                if q.source_url is None or fallback_marked:
                    dropped_ungrounded += 1
                    logger.warning(
                        "GenerationStage dropped ungrounded question id=%s "
                        "fallback_marked=%s question=%r",
                        q.id,
                        fallback_marked,
                        q.question,
                    )
                    continue
                grounded.append(q)
            if tagged and not grounded:
                # Every question in the batch was unattributable — that is a
                # sourcing/attribution failure, not a trim. Fail loud rather
                # than deliver an empty pack that downstream stages would
                # treat as a mysterious shortfall.
                raise ValueError(
                    f"F8 violated: all {len(tagged)} questions ungrounded "
                    f"after attribution (no question carries a real "
                    f"source_url)"
                )
        else:
            grounded = tagged

        ctx.questions = grounded

        # F8 (task 2.15): every persisted question must carry a real source URL.
        # If the per-question fallback above couldn't fill `source_url` (e.g.
        # all sourced facts lacked URLs — OpenTriviaDB without attribution),
        # fail loudly here instead of letting the gap slip into Postgres.
        # Issue #46 D4/D5: logical puzzles (`pipeline == "logical_puzzle"`) are
        # exempt — they are invented, have no web source, and ship with
        # `source_url = null` plus a provenance marker. The relaxation is keyed
        # strictly on that marker (set only by the open branch above) so a
        # mislabelled factual question can never slip through unsourced (R3).
        missing = [
            q
            for q in ctx.questions
            if not q.source_url
            and not (
                q.generation_metadata is not None
                and q.generation_metadata.pipeline == "logical_puzzle"
            )
        ]
        # #153 Phase 0.4: in direct-generation mode there are no source facts
        # to attribute, so F8 has nothing to enforce — verification remains
        # the truth gate for these questions.
        if missing and not ctx.direct_generation:
            attributed = sum(
                1 for f in (ctx.facts or []) if getattr(f, "source_url", None)
            )
            raise ValueError(
                f"F8 violated: {len(missing)}/{len(ctx.questions)} questions "
                f"have no source_url after GenerationStage "
                f"({attributed}/{len(ctx.facts or [])} facts had source_url)"
            )

        return StageResult(
            info={
                "questions": len(ctx.questions),
                "dropped_quality": dropped_quality,
                "normalized_quality": normalized_quality,
                "dropped_mcq_missing_options": dropped_mcq_missing_options,
                "mcq_label_kept_as_text": mcq_label_kept_as_text,
                "dropped_ungrounded": dropped_ungrounded,
                "demoted_puzzles": demoted_puzzles,
                **inline_counts.as_info(),
            },
            cost_cents=0,
        )
