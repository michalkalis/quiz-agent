"""May a freshly imported question skip the human review queue? (#177)

Founder decision 2026-09-10 changes the 2026-08-28 rule (PR #81): `approved`
now means "a human **or** the machine gates vouched for this question", and the
*state* decides what serves, not who set it. An English shared-corpus question
that came through the pipeline with **zero findings** is `approved` on import;
anything with a finding stays `pending_review` (TestFlight-only serving).

``machine_approval_block_reason`` is that predicate, and it is **fail-closed by
construction**: it returns a reason string (do NOT auto-approve) for every
missing, unparsable or unknown piece of evidence. Only a row that positively
proves each gate cleared returns ``None``. The two shapes this protects
against:

- *hand-curated rows* (no pipeline provenance) — no gate ever ran on them, so
  they can never be machine-approved, only human-promoted;
- *pre-#177 JSON batches* that predate the shadow-flag keys — a missing
  ``craft_flag`` must not read as "clean", so the deterministic guards
  (`app.scoring.craft_guards`, pure functions) are **recomputed** here for
  every row instead of trusted from the file.

The judge-dependent veto (`veto_flag`) cannot be recomputed: it reads judge
score dimensions that never reach the JSON batch. It blocks when present, and
with the judge panel off (``JUDGE_GATE=0``, today's configuration) it is inert
by construction — which is exactly why the marker below is *versioned*:
``GATE_VERSION`` names "the gates as configured", and a changed gate set gets a
new version rather than a silently different meaning for the same string.
"""

from __future__ import annotations

from collections.abc import Collection, Iterable

from quiz_shared.models.question import GenerationProvenance, Question

from app.scoring import craft_guards

# Stamped into `reviewed_by` so a machine approval is distinguishable from a
# human one in SQL (`reviewed_by LIKE 'machine:%'`); humans stay `michal`.
GATE_VERSION = "machine:gates-v1"

# Shadow-flag keys written into `generation_metadata.extra` by ScoringStage
# (#177 T1). Defined here — the predicate is the consumer that gives them
# meaning — and imported by the stage so the two can never drift apart.
CRAFT_FLAG_KEY = "craft_flag"
UNDATED_FLAG_KEY = "undated_flag"
VETO_FLAG_KEY = "veto_flag"
_FLAG_KEYS = (CRAFT_FLAG_KEY, UNDATED_FLAG_KEY, VETO_FLAG_KEY)

# Mirrors `app.orchestrator.stages.verification.DEFAULT_MIN_CONFIDENCE`. Not
# imported from there: that module pulls the LLM verifiers in, and this
# predicate runs inside a CLI importer. `tests/scoring/test_machine_approval.py`
# pins the two values equal, so drift fails loudly instead of silently
# loosening the bar.
MIN_VERIFICATION_SCORE = 0.5

# The only fact-check tier that evidences a completed web check. `evergreen`
# rows were kept WITHOUT one (founder decision pending, #177), and any other /
# absent value is unknown evidence — both fail closed.
_WEB_FACTCHECK_TIER = "web"


def stamp_review_flag(q: Question, key: str, reason: str) -> None:
    """Persist a shadow finding on the question itself (#177 T1).

    Called by `ScoringStage` for a flagged-but-KEPT question, which used to
    leave no trace outside the worker log: the counters in
    ``StageResult.info`` say *how many*, never *which*. The reason now travels
    with the row (``_write_out`` → ``Question.from_dict`` → the corpus) so the
    predicate below can read it at import time. Counters are untouched.

    It lives next to the predicate on purpose: writer, reader and key names in
    one module is the only way the two sides cannot drift.
    """
    provenance = q.generation_metadata or GenerationProvenance()
    extra = dict(provenance.extra)
    extra[key] = reason
    q.generation_metadata = provenance.model_copy(update={"extra": extra})


def tf_imbalance_excess_ids(questions: Iterable[Question]) -> set[str]:
    """Ids of the true/false rows a batch must shed for key balance.

    T/F key balance is a **batch-level** property, so it cannot be judged one
    row at a time — the importer resolves it across the whole import set and
    hands the result to `machine_approval_block_reason`, mirroring how
    `ScoringStage` resolves it before its per-question loop.
    """
    items: list[tuple[str, str]] = []
    for q in questions:
        key = craft_guards.true_false_key(q.correct_answer, q.possible_answers)
        if key is not None:
            items.append((q.id, key))
    return set(craft_guards.tf_imbalance_excess(items))


def machine_approval_block_reason(
    q: Question, tf_excess: Collection[str] = ()
) -> str | None:
    """Why this row must NOT be machine-approved, or ``None`` when it is clean.

    The returned string is a short, greppable reason (it lands in the
    importer's dry-run summary), not a sentence.
    """
    if q.language != "en":
        # Only the EN corpus went through the gates this predicate models; the
        # sk/cs rows (#168) are translations and carry their own review track.
        return f"language={q.language!r}"
    if q.pack_id is not None:
        return "pack_scoped"
    if not (q.source_url or "").strip():
        return "no_source_url"

    provenance = q.generation_metadata
    if provenance is None:
        return "no_provenance"
    extra = provenance.extra or {}

    if extra.get("held_for_review"):
        return "held_for_review"

    verified = extra.get("verified")
    if verified is not True:
        return f"verified={verified!r}"

    score = extra.get("verification_score")
    if isinstance(score, bool) or not isinstance(score, (int, float)):
        return f"verification_score={score!r}"
    if score < MIN_VERIFICATION_SCORE:
        return f"verification_score={score}<{MIN_VERIFICATION_SCORE}"

    tier = extra.get("factcheck_tier")
    if tier != _WEB_FACTCHECK_TIER:
        return f"factcheck_tier={tier!r}"

    for key in _FLAG_KEYS:
        flag = extra.get(key)
        if flag:
            return f"{key}={flag}"

    return _recomputed_guard_reason(q, tf_excess)


def _recomputed_guard_reason(q: Question, tf_excess: Collection[str]) -> str | None:
    """Deterministic craft/undated guards, recomputed from the row itself.

    Never trust a batch file to tell us it is clean: the guards are pure and
    free, and a pre-#177 file has no flag keys at all.
    """
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
    if craft_reason is not None:
        return f"{CRAFT_FLAG_KEY}={craft_reason}"
    if q.id in tf_excess:
        return f"{CRAFT_FLAG_KEY}=tf_key_imbalance"
    undated_reason = craft_guards.undated_record_reason(q.question, q.explanation)
    if undated_reason is not None:
        return f"{UNDATED_FLAG_KEY}={undated_reason}"
    return None
