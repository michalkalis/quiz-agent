"""Offline pipeline assembly shared by the CLI and the weekly job (#170 D5, #202).

One definition of "the standard offline stage walk": the in-memory
``GenerationOrder`` (``build_order``), the stage list (``build_stages``) and the
#170 dedup-switch composition (``build_strictness`` / ``build_dedup_stage`` /
``build_grayzone_judge``). ``scripts/generate_pack.py`` and
``scripts/replay_dedup_json.py`` import from here, so a corpus run, its replay
and the scheduled fresh-topup (#202) cannot drift apart.

Moved verbatim from those scripts (#202 task 202.1); the only additions are the
optional ``generation_model`` / ``answerability_model`` pins on
``build_stages``. ``app/worker/tasks.py`` has its own ``_build_stages`` and
reads none of this, so a customer pack is unaffected by construction.
"""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

from quiz_shared.llm import factory as llm_factory

from app import feature_flags
from app.db.models import GenerationOrder
from app.orchestrator.pack_generator import Stage
from app.orchestrator.stages import (
    AnswerabilityStage,
    CompositionStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    TopUpStage,
    VerificationStage,
)
from app.orchestrator.stages.dedup import AsyncDuplicateFinder, DedupStage
from app.orchestrator.stages.grayzone_judge import DEFAULT_MAX_CALLS, GrayZoneJudge
from app.orchestrator.stages.strictness import Strictness, parse_strictness

# Steering footer appended to the order prompt by `--mcq-bias` (issue #42
# task 42.19b). The order prompt never reaches the generation LLM (42.20
# BLOCKER root cause D) — the operative mechanism is the MCQ_EMPHASIS_MARKER
# this footer carries: `PackGenerator` detects it and sets
# `OrderContext.mcq_emphasis`, which travels through `GenerationStage` into
# `_format_mcq_patterns_section`'s hard quota. The footer text itself only
# informs sourcing / audit logs.
_MCQ_BIAS_INSTRUCTION = (
    "{marker}: at least 7 of every 10 questions in this "
    "batch MUST use one of these MCQ-routable reasoning patterns: "
    "{patterns} (true/false claims, odd-one-out sets, "
    "which-is-older/larger comparisons, year guesses). For this order "
    "those patterns are EXEMPT from the PATTERN DIVERSITY RULE's "
    "per-pattern cap — repeating them is expected and correct. "
    "Emit possible_answers for every question using one of those patterns."
)


def _mcq_bias_instruction() -> str:
    from app.generation.pattern_routing import MCQ_EMPHASIS_MARKER, PATTERNS_TO_MCQ

    return _MCQ_BIAS_INSTRUCTION.format(
        marker=MCQ_EMPHASIS_MARKER, patterns=", ".join(sorted(PATTERNS_TO_MCQ))
    )



def build_order(args: argparse.Namespace) -> GenerationOrder:
    """In-memory `GenerationOrder` — never inserted in dry-run mode."""
    prompt = args.prompt
    if args.mcq_bias:
        prompt = f"{prompt}\n\n{_mcq_bias_instruction()}"
    return GenerationOrder(
        id=uuid.uuid4(),
        transaction_id=f"cli-{uuid.uuid4().hex[:12]}",
        product_id="pack_cli",
        prompt=prompt,
        category=args.category,
        theme=args.theme,
        target_count=args.target_count,
        language=args.language,
        status="in_progress",
        # #157 (D4): direct mode travels as a server-side column, never as
        # marker text inside the prompt. #167 (D2): --grounded is the explicit
        # opposite; neither flag leaves the column NULL, which inherits the
        # server-side DIRECT_GENERATION default.
        generation_mode=(
            "direct" if args.direct else ("grounded" if args.grounded else None)
        ),
    )


def build_grayzone_judge() -> GrayZoneJudge | None:
    """#170 D7 — the judge from env, deliberately NOT gated by the session-mode
    judge cut (`generate_pack._judges_enabled`): it is a dedup verdict, not a
    quality judge, and is allowed on the subscription."""
    if not feature_flags.dedup_grayzone_judge():
        return None
    max_calls = feature_flags.grayzone_judge_max_calls()
    return GrayZoneJudge(
        max_calls=max_calls if max_calls is not None else DEFAULT_MAX_CALLS
    )


def build_strictness() -> Strictness:
    """#170 D6 — the per-category profile from env. `DedupStage` and
    `TopUpStage` must read the SAME object (the spent-fact filter mirrors the
    dedup content check), so both callers compose it here."""
    return Strictness(
        profiles=parse_strictness(feature_flags.dedup_strictness_per_category()),
        answer_cap=feature_flags.answer_cap(),
    )


def build_dedup_stage(
    store: AsyncDuplicateFinder,
    gold_standard_path: str | Path | None = None,
    strictness: Strictness | None = None,
) -> DedupStage:
    """Compose `DedupStage` from the #170 env flags — the one place the corpus
    CLI and this harness share, so a replay reproduces a run's switches."""
    strictness = strictness if strictness is not None else build_strictness()
    return DedupStage(
        store,
        gold_standard_path=gold_standard_path,
        strictness=strictness,
        answer_counter=store if strictness.answer_cap else None,  # type: ignore[arg-type]
        qa_embedding=feature_flags.dedup_qa_embedding(),
        grayzone_judge=build_grayzone_judge(),
    )


class FactsFileSourcingStage:
    """Stands in for SourcingStage when ``--facts-file`` is given (#153).

    Loads a fact set dumped by an earlier ``--dump-facts`` run so every
    experiment arm generates from the IDENTICAL facts — re-sourcing per arm
    would let fact variance confound the prompt comparison. Named "sourcing"
    because PackGenerator requires the first stage to carry that name.
    """

    name = "sourcing"

    def __init__(self, path: str) -> None:
        self._path = path

    async def run(self, ctx, sink):
        from app.orchestrator.context import StageResult
        from app.sourcing.models import Fact

        with open(self._path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
        ctx.facts = [Fact.from_dict(entry) for entry in payload["facts"]]
        ctx.auto_topics = payload.get("topics")
        return StageResult(
            info={"facts": len(ctx.facts), "facts_file": self._path},
            cost_cents=0,
        )


def build_stages(
    *,
    persist: bool,
    dedup_store: AsyncDuplicateFinder,
    judges: bool = True,
    gen_prompt_file: str | None = None,
    forced_topics: list[str] | None = None,
    facts_file: str | None = None,
    per_topic_cap: int | None = None,
    floor_fraction: float | None = None,
    coverage_allocator=None,
    coverage_seed: int | None = None,
    generation_model: str | None = None,
    answerability_model: str | None = None,
) -> list[Stage]:
    """Construct the standard pipeline. Persist is omitted in dry-run mode.

    #169 prod parity: this walk is the same one `app/worker/tasks.py::
    _build_stages` builds — same stages, same order, same feature flags; only
    the transport (``LLM_GATEWAY``) may differ. ``judges=False`` means what
    ``JUDGE_GATE=0`` means in prod: ``ScoringStage(None)``, i.e. no judge
    calls but the stage's deterministic craft/distractor guards still run.

    #153 Phase A experiment levers (CLI-only, worker path untouched):
    ``gen_prompt_file`` swaps the fact-first generation prompt (filename
    within ``prompts/``).
    ``forced_topics`` pins the sourced topic set; ``facts_file`` replaces
    sourcing entirely with a previously dumped fact set.
    ``per_topic_cap`` overrides CompositionStage's scaled per-topic cap
    (#167); ``None`` keeps today's scaled default, so the worker/API path —
    which never sets it — stays byte-identical.
    ``floor_fraction`` overrides TopUpStage's shortfall floor (#195); ``None``
    keeps the 80% default the worker uses.

    #170 D5 — this is the ONLY place the four #170 constructor parameters get
    filled: ``coverage_allocator`` (170.13) plus the ``strictness`` /
    ``qa_embedding`` / ``grayzone_judge`` trio composed from env by
    ``build_dedup_stage`` (imported, never forked, so a CLI
    run and its replay read the same switches). ``app/worker/tasks.py`` reads
    none of them, so a mis-set prod secret cannot reach a customer pack.

    #202 pins (both ``None`` = today's behaviour exactly): ``generation_model``
    fixes the generator model — it beats ``GENERATION_MODEL`` and skips the
    ``GEN_ALT`` mix draw, so a scheduled run is reproducible. ``persist`` is
    the pre-existing switch for ``PersistStage`` (a job that stamps its own
    ``pack_id``-free rows passes ``False``). ``answerability_model`` is handed
    to ``AnswerabilityChecker`` (only built when ``ANSWERABILITY_CHECK`` is on)
    and to ``ShapeClassifier``, which runs on the same blind-answer model.
    """
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.expiry_classifier import ExpiryClassifier
    from app.generation.topicality_classifier import TopicalityClassifier
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
    from app.sourcing.topic_pool import TopicPool
    from app.verification.answerability import AnswerabilityChecker
    from app.verification.casual_player import CasualPlayerChecker
    from app.verification.fact_verifier import FactVerifier
    from app.verification.logical_verifier import LogicalConsistencyVerifier
    from app.verification.shape_classifier import ShapeClassifier

    # Lever A (issue #72 P1.1): source the gen/critique models from the dormant
    # feature flags, exactly as the API path's `_build_advanced_generator` does,
    # so `GENERATION_MODEL=claude-opus-4-8` actually reaches the generator on a
    # CLI run. With no env set the flags return None → the canonical
    # gpt-4o/gpt-4o-mini defaults (output unchanged). The Phase-6 validation run
    # goes through this path, so the model toggle MUST be honoured here.
    generator = AdvancedQuestionGenerator(
        # Founder 2026-10-08 model mix: one pick per CLI run (= one batch).
        generation_model=(
            generation_model
            or feature_flags.generation_model()
            or llm_factory.pick_generation_model()
        ),
        critique_model=feature_flags.critique_model() or llm_factory.CRITIQUE,
        # #169 prod parity: the worker (`worker.py on_startup`) and the API
        # path both pass this flag; without it the CLI silently fell back to
        # the ctor default `v2_cot` — the pre-#166 template.
        prompt_version=feature_flags.generation_prompt_version(),
        fact_first_template=gen_prompt_file,
    )

    # Issue #76 F-3b — the founder's manual replenishment pass runs through
    # THIS path (decision B: no new command), so the expiry classifier must
    # be wired here exactly as in the worker (`worker.py on_startup`), behind
    # the same EXPIRY_CLASSIFICATION flag (default off → dormant, None).
    generation = GenerationStage(
        generator,
        expiry_classifier=(
            ExpiryClassifier() if feature_flags.expiry_classification() else None
        ),
        # Issue #195 — same wiring as the worker: default ON.
        topicality_classifier=(
            TopicalityClassifier()
            if feature_flags.topicality_classification()
            else None
        ),
        # #160 — answer-blind auditor of the logical_puzzle routing marker.
        # #202: shares the answerability pin (None = today's default).
        shape_classifier=ShapeClassifier(model=answerability_model),
        # #170 170.13 — `None` unless COVERAGE_STEERING is on (worker default).
        coverage_allocator=coverage_allocator,
        coverage_seed=coverage_seed,
    )
    # 46.B6 / #169 parity: the logical-consistency judge for lateral puzzles
    # is wired in the worker; without it here a CLI run silently verified
    # lateral puzzles on the factual path.
    verification = VerificationStage(FactVerifier(), LogicalConsistencyVerifier())
    # #166 D21b parity with `tasks._build_stages`: judges off means
    # `ScoringStage(None)` — deterministic craft + distractor gates still run.
    # #201 — the casual-player checker is always wired; the flag decides per
    # category whether it runs (worker parity: `tasks._build_stages`).
    scoring = ScoringStage(
        MultiModelScorer() if judges else None,
        casual_checker=CasualPlayerChecker(),
    )
    # #170 D6 — one strictness object for both stages (the spent-fact filter
    # and the dedup content check must read the same profile).
    strictness = build_strictness()
    dedup = build_dedup_stage(dedup_store, None, strictness)
    composition = CompositionStage(per_topic_cap=per_topic_cap)
    # #135 D10 — early round-trip answerability check between dedup and
    # verification, behind the same flag the worker honours.
    answerability = (
        AnswerabilityStage(AnswerabilityChecker(model=answerability_model))
        if feature_flags.answerability_check()
        else None
    )

    stages: list[Stage] = [
        # #72 F-1 (Scope A): the CLI/batch path wires the curated TopicPool so a
        # no-category run samples a diverse concrete topic set (no per-pack LLM
        # call). The worker/live path deliberately does NOT (stays byte-identical
        # until Scope B). Refresh the pool offline via scripts/refresh_topic_pool.py.
        (
            FactsFileSourcingStage(facts_file)
            if facts_file
            else SourcingStage(
                FactSourcer(), topic_pool=TopicPool(), forced_topics=forced_topics
            )
        ),
        generation,
        # 2026-08 perf fix: dedup runs right after generation, before
        # verification/scoring — a question dedup would discard anyway
        # should never pay for either, mirroring the worker's `_build_stages`.
        dedup,
    ]
    if answerability is not None:
        stages.append(answerability)
    stages += [
        verification,
        scoring,
        # #153 Phase 0.1 — deterministic batch caps (per-topic, T/F) right
        # after scoring, mirroring the worker's `_build_stages`.
        composition,
        # 2026-07-27 live-run F-b: the CLI omitted TopUpStage, so every pack
        # that lost questions downstream just delivered short (the plain run
        # needed 11 batches for 100 questions). Same instances as the initial
        # pass, mirroring the worker's `_build_stages` (#103 F5).
        TopUpStage(
            generation,
            verification,
            scoring,
            dedup,
            answerability_stage=answerability,
            composition_stage=composition,
            strictness=strictness,
            **({} if floor_fraction is None else {"floor_fraction": floor_fraction}),
        ),
    ]
    if persist:
        from app.db.session import AsyncSessionLocal

        stages.append(PersistStage(AsyncSessionLocal))
    return stages
