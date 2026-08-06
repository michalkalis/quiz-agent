"""ScoringStage — MultiModelScorer as the fail-loud ship gate (issue #36 task
2.7; gate added #42 task 42.29).

The stage adapts `OrderContext.questions` to the dict shape
`MultiModelScorer.score_batch` expects, calls the existing scorer, then
writes per-model overall scores into `ctx.scores` keyed by question id:

    ctx.scores[question_id] = {
        "<model_name>": overall_score,
        ...
    }

**#42 task 42.29 — this stage now DROPS, not just scores.** The Track F-R
review (2026-06-19) designated `MultiModelScorer` the single blocking
quality gate; two scorers that only ever warned were "false confidence"
(CLAUDE.md Rule #2 — fail loud). A question is dropped when:

- its mean ``overall_score`` across models is below ``MIN_OVERALL_SCORE``
  (a low floor — only catastrophically bad questions), or
- (MCQ only) its ``distractor_quality`` is below ``MIN_DISTRACTOR_QUALITY``
  — catches duplicate / substring-leaking / length-skewed distractors
  (``distractor_quality`` is the deterministic dim from task 42.6, attached
  identically to every model's ``scores`` sub-dict; ``None`` for free-form).

**#147 — the gate is FAIL-CLOSED on a judge outage (founder decision
2026-08-06).** A question that reaches the gate with zero *real* judge
verdicts is UNJUDGED, and an unjudged question is never delivered: it is
withheld, and the stage then raises `JudgePanelUnavailable`, failing the
order into the existing failure/retry machinery (ARQ, the stuck-order sweep,
`POST /retry`) instead of shipping an ungated paid pack. Repeated retries are
bounded by the per-order spend ceiling (#145, `app.order_budget`), and the
terminal-failure path already marks the order `refund_eligible`.

The threshold is deliberately "ANY question with zero judgments fails the
stage", not a ratio: the customer paid for judged questions, a partial panel
still produces verdicts (so a single failing judge does not trip this), and
the realistic cause of a zero-verdict question is a panel-wide outage that
hits the whole batch anyway. The judge-failure count is surfaced via
``StageResult.info["judge_failures"]`` and an error-level Sentry event, so an
outage is legible in the order's step log rather than only in worker logs.

The drop count is surfaced via ``StageResult.info["dropped_low_score"]``,
mirroring ``DedupStage.info["dropped"]`` so SSE/audit clients see it.

**#72 reviewer upgrade (founder calibration 2026-07-09/10):** deterministic
craft guards (stem answer-leak, T/F key-balance — ``app.scoring.craft_guards``)
run in shadow on every batch and drop when ``CRAFT_GUARDS_ENFORCE`` is on;
the Answerability/surprise veto gains an enforcing mode behind ``VETO_ENFORCE``.
Both default off until validated against the founder's 36-rating ground truth.
"""

from __future__ import annotations

import logging

import sentry_sdk

from app import feature_flags
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring import craft_guards
from app.scoring.multi_model_scorer import MultiModelScorer, is_judge_verdict

logger = logging.getLogger(__name__)


class JudgePanelUnavailable(RuntimeError):
    """Questions reached the ship gate with zero real judge verdicts (#147).

    Raised instead of delivering an ungated pack. It is a retryable failure by
    construction — the worker's failure path treats it like any other stage
    exception, so the order re-enters the ARQ/sweep/manual-retry machinery and
    ends `refund_eligible` once its #145 budget is gone.

    ``info`` carries the counters the stage would have returned in
    ``StageResult.info``: the stage failed, so nothing else can hand them to
    the step log or to a test.
    """

    def __init__(self, message: str, info: dict | None = None) -> None:
        super().__init__(message)
        self.info = dict(info or {})

# Drop thresholds (module-level constants, not magic numbers — #42 task 42.29).
# Deliberately lenient: the gate removes broken questions, it is not a top-K
# trimmer. Tune here, not at call sites.
MIN_OVERALL_SCORE = 3.0
MIN_DISTRACTOR_QUALITY = 4

# --- Answerability/surprise veto (issue #72 P4.1, Lever C — SHADOW only) -------
# Flags the "starboard-class" boring dead-end recall question ("What term do
# sailors use for the right side? → Starboard") so fun is *enforced* in at least
# one place. In VETO_SHADOW mode this only logs + counts would-drops; it never
# removes a question (drop is gated on by the founder at Phase 6, not Ralph).
#
# Thresholds are calibrated to the question_critique_v2 anchors: the "Poor 3-4"
# boring-recall band sits at surprise 2 / answerability 2 (pure memorization,
# "the most boring possible format"), while the "Average 5-6 meets minimum bar"
# anchor sits at surprise 5 / clever_framing 4. A question is flagged only when
# BOTH signals are at/below the low threshold (logical AND) — so a merely
# unsurprising estimation question, or a surprising-but-slightly-dead-end one,
# is never falsely vetoed (the gate's "no false-veto of the good ones").
VETO_SURPRISE_MAX = 3.0
VETO_ANSWERABILITY_MAX = 3.0

# The per-dimension scorer emits surprise_delight + answerability; the richer
# question_critique_v2 rubric emits surprise_factor + answerability. The veto
# reads whichever surprise alias the scorer produced. Answerability is a real
# scored dimension since the 2026-07-30 redesign (generation review A5) — the
# old clever_framing fallback is gone: clever_framing is capped by nine
# unrelated craft defects, so reading it here turned the documented
# dead-end-recall veto into "any craft defect + low surprise → drop".
_SURPRISE_KEYS = ("surprise_factor", "surprise_delight")
_ANSWERABILITY_KEYS = ("answerability",)


def _mean_dim(model_scores: list[dict], keys: tuple[str, ...]) -> float | None:
    """Mean of the first present alias in ``keys`` across models' score dicts.

    Returns None when no model scored any alias — absence of a judgment must
    not read as a low score (and so must not trigger the veto).
    """
    vals: list[float] = []
    for s in model_scores:
        dims = s.get("scores") or {}
        for k in keys:
            if dims.get(k) is not None:
                vals.append(float(dims[k]))
                break
    return sum(vals) / len(vals) if vals else None


def _shadow_veto_reason(model_scores: list[dict]) -> str | None:
    """Return a would-drop reason for a boring dead-end recall question, else None.

    Shadow only — the caller logs/counts this and KEEPS the question. Returns
    None unless BOTH the surprise and answerability signals were scored AND both
    are at/below their low thresholds.
    """
    surprise = _mean_dim(model_scores, _SURPRISE_KEYS)
    answerability = _mean_dim(model_scores, _ANSWERABILITY_KEYS)
    if surprise is None or answerability is None:
        return None
    if surprise <= VETO_SURPRISE_MAX and answerability <= VETO_ANSWERABILITY_MAX:
        return (
            f"answerability_surprise_veto(surprise={surprise:.1f}"
            f"<={VETO_SURPRISE_MAX},answerability={answerability:.1f}"
            f"<={VETO_ANSWERABILITY_MAX})"
        )
    return None


class ScoringStage:
    """Scores via MultiModelScorer; drops questions below the quality gate."""

    name = "scoring"

    def __init__(self, scorer: MultiModelScorer) -> None:
        self._scorer = scorer

    async def run(self, ctx: OrderContext, sink: ProgressSink) -> StageResult:
        if not ctx.questions:
            return StageResult(
                info={"scored": 0, "dropped_low_score": 0, "judge_failures": 0},
                cost_cents=0,
            )

        payload = [
            {
                "id": q.id,
                "question": q.question,
                "correct_answer": _stringify_answer(q.correct_answer),
                "difficulty": q.difficulty,
                "topic": q.topic,
                "possible_answers": q.possible_answers,
            }
            for q in ctx.questions
        ]
        results = await self._scorer.score_batch(payload)
        scores_by_id = {
            r.get("id"): r.get("model_scores", [])
            for r in results
            if r.get("id") is not None
        }

        veto_enforce = feature_flags.veto_enforce()
        veto_consult = veto_enforce or feature_flags.veto_shadow()
        craft_enforce = feature_flags.craft_guards_enforce()

        # Craft guards (#72 reviewer upgrade) — deterministic, computed for
        # every batch (free); enforcement is flag-gated. T/F key balance is a
        # batch-level property, so the excess set is resolved before the loop.
        tf_items = []
        for q in ctx.questions:
            key = craft_guards.true_false_key(q.correct_answer, q.possible_answers)
            if key is not None:
                tf_items.append((q.id, key))
        tf_excess = set(craft_guards.tf_imbalance_excess(tf_items))

        kept: list = []
        dropped = 0
        veto_flagged = 0
        veto_dropped = 0
        craft_flagged = 0
        craft_dropped = 0
        undated_flagged = 0
        judge_failures = 0
        for q in ctx.questions:
            model_scores = scores_by_id.get(q.id, [])

            # Keep the per-model overall map in ctx.scores for downstream
            # review tooling (advisory) — including for dropped questions, so
            # an audit can see *why* they failed the gate.
            per_model: dict[str, float] = {}
            for score in model_scores:
                name = score.get("model_name")
                overall = score.get("overall_score")
                if name is None or overall is None:
                    continue
                per_model[name] = float(overall)
            ctx.scores[q.id] = per_model

            # #99 D2-subset telemetry — shadow-only BY CONTRACT (see
            # craft_guards.undated_record_reason): counted and logged for
            # every question, never a drop, even under CRAFT_GUARDS_ENFORCE.
            undated_reason = craft_guards.undated_record_reason(
                q.question, q.explanation
            )
            if undated_reason is not None:
                undated_flagged += 1
                logger.warning(
                    "ScoringStage undated-record flagged id=%s reason=%s "
                    "(shadow-only telemetry: kept)",
                    q.id,
                    undated_reason,
                )

            craft_reason = craft_guards.stem_leak_reason(
                q.question, q.correct_answer, q.possible_answers
            )
            if craft_reason is None:
                craft_reason = craft_guards.long_answer_reason(
                    q.correct_answer, q.possible_answers
                )
            if craft_reason is None:
                craft_reason = craft_guards.units_reason(
                    q.question, q.correct_answer, q.possible_answers
                )
            if craft_reason is None and q.id in tf_excess:
                craft_reason = "tf_key_imbalance"
            if craft_reason is not None:
                if craft_enforce:
                    craft_dropped += 1
                    logger.warning(
                        "ScoringStage craft-guard dropped id=%s reason=%s",
                        q.id,
                        craft_reason,
                    )
                    continue
                craft_flagged += 1
                logger.warning(
                    "ScoringStage craft-guard would-drop id=%s reason=%s "
                    "(shadow mode: kept)",
                    q.id,
                    craft_reason,
                )

            # Lever C veto: shadow logs would-drops (#72 P4.1); VETO_ENFORCE
            # promotes it to dropping (#72 reviewer upgrade). Independent of the
            # score gate below — a boring question can clear the lenient floor
            # yet still be a dead-end recall question.
            if veto_consult:
                veto_reason = _shadow_veto_reason(model_scores)
                if veto_reason is not None:
                    if veto_enforce:
                        veto_dropped += 1
                        logger.warning(
                            "ScoringStage VETO dropped id=%s reason=%s",
                            q.id,
                            veto_reason,
                        )
                        continue
                    veto_flagged += 1
                    logger.warning(
                        "ScoringStage VETO_SHADOW would-drop id=%s reason=%s "
                        "(shadow mode: kept)",
                        q.id,
                        veto_reason,
                    )

            # #147 fail-closed: no real verdict → the question is unjudged, so
            # it cannot be delivered and the gate below has nothing to decide
            # on. Counted here (at the gate, after the deterministic drops) so
            # the count means "would have shipped unjudged".
            if not any(is_judge_verdict(s) for s in model_scores):
                judge_failures += 1
                logger.warning(
                    "ScoringStage judge outage: question id=%s reached the ship "
                    "gate with zero judge verdicts — withheld",
                    q.id,
                )
                continue

            drop_reason = self._gate_reason(model_scores)
            if drop_reason is not None:
                dropped += 1
                logger.warning(
                    "ScoringStage dropped question id=%s reason=%s", q.id, drop_reason
                )
                continue
            kept.append(q)

        ctx.questions = kept
        info = {
            "scored": len(ctx.scores),
            "dropped_low_score": dropped,
            "veto_shadow_flagged": veto_flagged,
            "veto_dropped": veto_dropped,
            "craft_flagged": craft_flagged,
            "craft_dropped": craft_dropped,
            "undated_shadow_flagged": undated_flagged,
            "judge_failures": judge_failures,
        }
        if judge_failures:
            self._report_judge_outage(ctx, judge_failures, len(payload), info)
            raise JudgePanelUnavailable(
                f"{judge_failures} question(s) reached the ship gate with zero "
                "judge verdicts — refusing to deliver an ungated pack",
                info=info,
            )
        return StageResult(info=info, cost_cents=0)

    @staticmethod
    def _report_judge_outage(
        ctx: OrderContext, judge_failures: int, batch_size: int, info: dict
    ) -> None:
        """Error-level Sentry event for the outage that failed this stage.

        The order's step log records the same counter, but the pack is now
        late for a paying customer and the cause is upstream (provider outage,
        exhausted credits, throttling) — that has to page us, not sit in
        worker logs. Mirrors `order_budget.report_breach`'s shape.
        """
        message = (
            f"order {ctx.order_id} scoring gate failed: {judge_failures} of "
            f"{batch_size} question(s) had zero judge verdicts "
            "(judge panel unavailable)"
        )
        logger.error(message)
        with sentry_sdk.new_scope() as scope:
            scope.set_context(
                "scoring_gate",
                {
                    "order_id": str(ctx.order_id),
                    "policy": "fail_closed",
                    **info,
                },
            )
            sentry_sdk.capture_message(message, level="error")

    @staticmethod
    def _gate_reason(model_scores: list[dict]) -> str | None:
        """Return a drop reason if the question fails the gate, else None.

        Only REAL judge verdicts count (`is_judge_verdict`): the deterministic
        advisory entry emitted during a judge outage carries no
        ``overall_score`` and must never move this average (#147). Callers do
        not reach this method for an unjudged question at all — `run` withholds
        it and fails the stage, because "no judgment" is no longer "keep it".
        """
        overalls = [
            float(s["overall_score"]) for s in model_scores if is_judge_verdict(s)
        ]
        if overalls and (sum(overalls) / len(overalls)) < MIN_OVERALL_SCORE:
            return f"overall_below_{MIN_OVERALL_SCORE}"

        # distractor_quality is deterministic and identical across models
        # (#42 task 42.6); MCQ-only (None for free-form). First entry carrying
        # it is representative.
        for s in model_scores:
            dq = (s.get("scores") or {}).get("distractor_quality")
            if dq is not None and dq < MIN_DISTRACTOR_QUALITY:
                return f"distractor_quality_below_{MIN_DISTRACTOR_QUALITY}"
        return None


def _stringify_answer(answer: object) -> str:
    """Flatten Question.correct_answer (str | list[str]) for the scorer API."""
    if isinstance(answer, list):
        return ", ".join(str(a) for a in answer)
    return str(answer)
