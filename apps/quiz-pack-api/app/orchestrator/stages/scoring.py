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

A question the scorer could not score at all (empty ``model_scores``) is
KEPT — we never drop on the absence of a judgment, only on a bad one. The
drop count is surfaced via ``StageResult.info["dropped_low_score"]``,
mirroring ``DedupStage.info["dropped"]`` so SSE/audit clients see it.

**#72 reviewer upgrade (founder calibration 2026-07-09/10):** deterministic
craft guards (stem answer-leak, T/F key-balance — ``app.scoring.craft_guards``)
run in shadow on every batch and drop when ``CRAFT_GUARDS_ENFORCE`` is on;
the Answerability/surprise veto gains an enforcing mode behind ``VETO_ENFORCE``.
Both default off until validated against the founder's 36-rating ground truth.
"""

from __future__ import annotations

import logging

from app import feature_flags
from app.orchestrator.context import OrderContext, StageResult
from app.orchestrator.progress_sink import ProgressSink
from app.scoring import craft_guards
from app.scoring.multi_model_scorer import MultiModelScorer

logger = logging.getLogger(__name__)

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

# The live SCORING_PROMPT emits surprise_delight / clever_framing; the richer
# question_critique_v2 rubric emits surprise_factor / answerability. The veto
# reads whichever alias the scorer produced, so it works under either prompt.
_SURPRISE_KEYS = ("surprise_factor", "surprise_delight")
_ANSWERABILITY_KEYS = ("answerability", "clever_framing")


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
            return StageResult(info={"scored": 0, "dropped_low_score": 0}, cost_cents=0)

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

            craft_reason = craft_guards.stem_leak_reason(
                q.question, q.correct_answer, q.possible_answers
            )
            if craft_reason is None:
                craft_reason = craft_guards.long_answer_reason(
                    q.correct_answer, q.possible_answers
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

            drop_reason = self._gate_reason(model_scores)
            if drop_reason is not None:
                dropped += 1
                logger.warning(
                    "ScoringStage dropped question id=%s reason=%s", q.id, drop_reason
                )
                continue
            kept.append(q)

        ctx.questions = kept
        return StageResult(
            info={
                "scored": len(ctx.scores),
                "dropped_low_score": dropped,
                "veto_shadow_flagged": veto_flagged,
                "veto_dropped": veto_dropped,
                "craft_flagged": craft_flagged,
                "craft_dropped": craft_dropped,
            },
            cost_cents=0,
        )

    @staticmethod
    def _gate_reason(model_scores: list[dict]) -> str | None:
        """Return a drop reason if the question fails the gate, else None.

        Unscored questions (empty ``model_scores``) return None — absence of
        a judgment is not a failed judgment, so they are kept.
        """
        overalls = [
            float(s["overall_score"])
            for s in model_scores
            if s.get("overall_score") is not None
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
