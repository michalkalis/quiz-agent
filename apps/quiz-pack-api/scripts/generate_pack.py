#!/usr/bin/env python3
"""Thin-client CLI for `PackGenerator` (issue #36 task 2.16).

Wraps the same Phase-2 orchestrator the ARQ worker runs (`PackGenerator` +
the six stages in `app.orchestrator.stages`) behind a single entrypoint so
the `/generate-questions` skill, ad-hoc admin runs, and the e2e test fixture
all reach the pipeline through one path — no reimplemented sourcing /
critique / verification logic on the skill side (#32 §1.2 U1 keep-list).

Modes
-----
``--dry-run``  Skips ``PersistStage``: no Postgres / Redis required, no
               row writes. Real LLM clients are still constructed so
               respx-installed HTTP mocks (as used by the ``e2e_http_mocks``
               fixture in ``tests/integration/conftest.py``) drive the
               pipeline end-to-end. A synthetic ``pack_id`` is printed so
               the output shape matches a real run.

(default)      Live mode. Inserts an in-memory ``GenerationOrder`` into
               the database, runs the full 6-stage pipeline against real
               APIs, and persists the resulting pack. Requires
               ``DATABASE_URL`` + the provider keys the worker reads at
               startup. Not exercised in CI.

Per memory ``feedback_qgen_import_cwd``: run from ``apps/quiz-pack-api/``
so ``app.*`` and ``quiz_shared`` resolve from this repo's workspace setup.

Usage
-----
::

    cd apps/quiz-pack-api
    python scripts/generate_pack.py --prompt "famous capitals" --target-count 3 --dry-run
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Sequence

# Ensure `app.*` imports resolve when invoked as `python scripts/generate_pack.py`
# from the apps/quiz-pack-api/ working dir.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_APP_DIR = os.path.dirname(_SCRIPT_DIR)
# _APP_DIR must be FIRST, not merely present: the workspace venv's editable
# .pth entries put apps/quiz-agent (which also owns a top-level `app`
# package) ahead of apps/quiz-pack-api, so a plain membership check leaves
# `import app` resolving to the wrong service under `uv run python scripts/…`.
if _APP_DIR in sys.path:
    sys.path.remove(_APP_DIR)
sys.path.insert(0, _APP_DIR)

from app import cost_tracking, llm_usage
from app.db.models import GenerationOrder
from app.orchestrator import PackGenerator, ProgressSink
from app.orchestrator.pack_generator import Stage
from app.orchestrator.stages import (
    AnswerabilityStage,
    CompositionStage,
    DedupStage,
    GenerationStage,
    PersistStage,
    ScoringStage,
    SourcingStage,
    TopUpStage,
    VerificationStage,
)
from app.orchestrator.stages.dedup import AsyncDuplicateFinder
from quiz_shared.llm import factory as llm_factory
from quiz_shared.models.question import Question

logger = logging.getLogger("generate_pack")


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


# ---------------------------------------------------------------------------
# Sinks + stub stores for --dry-run (no Redis / no DB)
# ---------------------------------------------------------------------------


class _StdoutSink:
    """`ProgressSink` that prints one line per lifecycle event.

    The ARQ worker uses `DBProgressSink` (Postgres step_log + Redis pubsub).
    For the CLI we just want a visible breadcrumb so the operator sees
    the pipeline moving — no infra dependency.
    """

    def __init__(self) -> None:
        self._next_id = 0

    async def start_step(
        self, step: str, info: dict[str, Any] | None = None
    ) -> int:
        eid = self._next_id
        self._next_id += 1
        print(f"[{eid:02d}] start  {step}" + (f" {info}" if info else ""))
        return eid

    async def finish_step(
        self, step: str, event_id: int, info: dict[str, Any] | None = None
    ) -> None:
        print(f"[{event_id:02d}] finish {step}" + (f" {info}" if info else ""))

    async def publish(
        self,
        event_id: int,
        step: str,
        progress: int,
        info: dict[str, Any] | None = None,
    ) -> None:
        # `publish` is the live SSE event in production; on the CLI it is
        # redundant with `finish_step`, so we no-op to keep stdout legible.
        return None


class _NoopQuestionStore:
    """Duplicate finder that owns nothing and finds no duplicates.

    `DedupStage` only awaits `find_duplicates` (#150), so that is the whole
    surface. Returning ``[]`` is safe for a one-shot CLI run — the user is
    generating a fresh pack, not deduping against an existing corpus.
    """

    async def find_duplicates(
        self, question_text: str, threshold: float = 0.85
    ) -> list[tuple[Question, float]]:
        return []


# ---------------------------------------------------------------------------
# Order + stage assembly
# ---------------------------------------------------------------------------


def _build_order(args: argparse.Namespace) -> GenerationOrder:
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


def _build_dedup_store(name: str) -> AsyncDuplicateFinder:
    """Select the corpus `DedupStage` checks against.

    ``noop`` (default) finds no duplicates — correct for a one-shot fresh
    pack with no existing corpus. ``pgvector`` dedups against the live
    Postgres corpus (requires ``DATABASE_URL``), so the 0.85 cosine guard
    fires against real history (issue #42 task 42.27, was deferred 42.19c).
    #150: the async store is handed to `DedupStage` directly — no sync bridge.
    """
    if name == "pgvector":
        from app.db.engine import normalize_async_url
        from quiz_shared.database.pgvector_client import PgvectorQuestionStore

        url = os.environ.get("DATABASE_URL")
        if not url:
            raise SystemExit(
                "--dedup-store pgvector requires DATABASE_URL (Postgres + pgvector)."
            )
        return PgvectorQuestionStore(database_url=normalize_async_url(url))
    return _NoopQuestionStore()


class _FactsFileSourcingStage:
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


def _judges_enabled(no_judges: bool) -> bool:
    """Judge panel on/off for this run.

    #169 (founder 2026-09-02): session runs never pay for judges — D21 showed
    the panel adds no signal, and on the subscription it was ~80 % of the
    quota (42 opus calls for 3 questions). Parity with the prod worker, where
    ``judge_gate`` is OFF. ``--no-judges`` stays the explicit lever elsewhere.
    """
    return not (no_judges or llm_factory.gateway() == llm_factory.SESSION)


def _build_stages(
    *,
    persist: bool,
    dedup_store: AsyncDuplicateFinder,
    judges: bool = True,
    gen_prompt_file: str | None = None,
    forced_topics: list[str] | None = None,
    facts_file: str | None = None,
    per_topic_cap: int | None = None,
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
    """
    from app import feature_flags
    from app.generation.advanced_generator import AdvancedQuestionGenerator
    from app.generation.expiry_classifier import ExpiryClassifier
    from app.scoring.multi_model_scorer import MultiModelScorer
    from app.sourcing.fact_sourcer import FactSourcer
    from app.sourcing.topic_pool import TopicPool
    from app.verification.answerability import AnswerabilityChecker
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
        generation_model=feature_flags.generation_model() or llm_factory.GEN,
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
        # #160 — answer-blind auditor of the logical_puzzle routing marker.
        shape_classifier=ShapeClassifier(),
    )
    # 46.B6 / #169 parity: the logical-consistency judge for lateral puzzles
    # is wired in the worker; without it here a CLI run silently verified
    # lateral puzzles on the factual path.
    verification = VerificationStage(FactVerifier(), LogicalConsistencyVerifier())
    # #166 D21b parity with `tasks._build_stages`: judges off means
    # `ScoringStage(None)` — deterministic craft + distractor gates still run.
    scoring = ScoringStage(MultiModelScorer() if judges else None)
    dedup = DedupStage(dedup_store, gold_standard_path=None)
    composition = CompositionStage(per_topic_cap=per_topic_cap)
    # #135 D10 — early round-trip answerability check between dedup and
    # verification, behind the same flag the worker honours.
    answerability = (
        AnswerabilityStage(AnswerabilityChecker())
        if feature_flags.answerability_check()
        else None
    )

    stages: list[Stage] = [
        # #72 F-1 (Scope A): the CLI/batch path wires the curated TopicPool so a
        # no-category run samples a diverse concrete topic set (no per-pack LLM
        # call). The worker/live path deliberately does NOT (stays byte-identical
        # until Scope B). Refresh the pool offline via scripts/refresh_topic_pool.py.
        (
            _FactsFileSourcingStage(facts_file)
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
        ),
    ]
    if persist:
        from app.db.session import AsyncSessionLocal

        stages.append(PersistStage(AsyncSessionLocal))
    return stages


def _write_out(questions: Sequence[Question], path: str) -> None:
    """Dump surviving questions to ``path`` as a reviewable JSON array.

    Every entry is a full ``Question.model_dump`` stamped
    ``review_status="pending_review"`` so dry-run batches land on disk in
    the same shape `Question.from_dict` reads back (42.20 review loop /
    42.23 importer).
    """
    payload = []
    for q in questions:
        entry = q.model_dump(mode="json")
        entry["review_status"] = "pending_review"
        payload.append(entry)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def _print_usage_table(summary: dict) -> None:
    """Compact per-stage/model token+cost table (#153 Phase 0.5)."""
    print()
    print("llm usage by stage/model:")
    for stage, models in summary["stages"].items():
        for model, stats in models.items():
            cost = (
                f"{stats['cost_cents']:.2f}¢"
                if stats["cost_cents"] is not None
                else "cost UNKNOWN"
            )
            print(
                f"  {stage:<14} {model:<32} calls={stats['calls']:<3} "
                f"in={stats['input_tokens']:<8} out={stats['output_tokens']:<8} "
                f"gaps={stats['calls_without_usage']:<3} {cost}"
            )
    print(f"  total known cost: {summary['total_cost_cents_known']:.2f}¢")
    if summary["unpriced_models"]:
        print(f"  unpriced models (cost omitted): {', '.join(summary['unpriced_models'])}")


# ---------------------------------------------------------------------------
# Run + report
# ---------------------------------------------------------------------------


async def _run(args: argparse.Namespace) -> int:
    persist = not args.dry_run
    order = _build_order(args)
    dedup_store = _build_dedup_store(args.dedup_store)
    # #153 Phase 0.5 — the handler must be registered BEFORE _build_stages:
    # generation/critique clients are constructed inside it and pick up the
    # handler at construction time. Registering after (the original order)
    # silently dropped every generation-stage call from the usage table —
    # only lazily-created clients (verification) were counted.
    usage_recorder = llm_usage.UsageRecorder()
    llm_factory.set_usage_handler(llm_usage.UsageCallbackHandler(usage_recorder))
    stages = _build_stages(
        persist=persist,
        dedup_store=dedup_store,
        judges=_judges_enabled(args.no_judges),
        gen_prompt_file=args.gen_prompt_file,
        forced_topics=(
            [t.strip() for t in args.topics.split(",") if t.strip()]
            if args.topics
            else None
        ),
        facts_file=args.facts_file,
        per_topic_cap=args.per_topic_cap,
    )

    def _sink_factory(_order_id: str) -> ProgressSink:
        return _StdoutSink()  # type: ignore[return-value]

    pack_generator = PackGenerator(stages=stages, sink_factory=_sink_factory)

    if persist:
        from app.db.session import AsyncSessionLocal

        async with AsyncSessionLocal() as session:
            session.add(order)
            await session.commit()

    # 2026-07-27 live-run F-c: stage-summed cost_cents is structurally 0 on
    # the CLI (every stage returns cost_cents=0; only the worker drained the
    # cost tracker), so the printed cost and the order row were meaningless.
    # Mirror the worker's capture: Tavily calls report into the contextvar
    # tracker as they happen, OpenRouter account-usage snapshots bracket the
    # run (see app.cost_tracking for the shared-account caveat).
    tracker, tracker_token = cost_tracking.activate()
    usage_before = await cost_tracking.fetch_openrouter_usage()
    try:
        pack = await pack_generator.run(order)
    finally:
        cost_tracking.deactivate(tracker_token)
        llm_factory.set_usage_handler(None)
    usage_after = await cost_tracking.fetch_openrouter_usage()

    ctx = pack_generator.last_ctx
    questions = list(ctx.questions) if ctx else []

    if args.dump_facts and ctx is not None:
        with open(args.dump_facts, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "topics": ctx.auto_topics,
                    "facts": [f.to_dict() for f in ctx.facts],
                },
                fh,
                ensure_ascii=False,
                indent=2,
            )
        print(f"facts dumped: {args.dump_facts} ({len(ctx.facts)} facts)")

    llm_cost_usd: Decimal | None = None
    if usage_before is not None and usage_after is not None:
        llm_cost_usd = round(Decimal(str(max(usage_after - usage_before, 0.0))), 6)
    search_cost_cents = tracker.search_cost_cents
    stage_cost_cents = ctx.cost_cents if ctx else 0
    llm_cost_cents = int(round(llm_cost_usd * 100)) if llm_cost_usd is not None else 0
    cost_cents = stage_cost_cents + search_cost_cents + llm_cost_cents

    if persist and pack is not None:
        # Make the measured spend durable on the order row (the worker's
        # contract) and close the order out — a CLI order left `in_progress`
        # forever reads as a stuck order to the #103 sweep's operator.
        async with AsyncSessionLocal() as session:
            db_order = await session.get(GenerationOrder, order.id)
            if db_order is not None:
                db_order.status = "delivered"
                db_order.pack_id = pack.id
                db_order.delivered_at = datetime.now(timezone.utc)
                db_order.llm_cost_usd = llm_cost_usd
                db_order.search_cost_cents = search_cost_cents
                await session.commit()

    pack_id = str(pack.id) if pack is not None else f"dry-run:{order.id}"
    print()
    print(f"pack_id: {pack_id}")
    print(f"questions: {len(questions)}")
    print(f"cost_cents: {cost_cents}")
    print(f"  search (Tavily): {search_cost_cents}¢ ({tracker.tavily_credits} credits)")
    if llm_cost_usd is not None:
        print(f"  llm (OpenRouter delta): ${llm_cost_usd}")
    else:
        print(
            "  llm: UNMEASURED — OpenRouter usage snapshot unavailable "
            "(gateway not 'openrouter', key missing, or API failure)"
        )
    for i, q in enumerate(questions, start=1):
        source = q.source_url or "(no source)"
        print(f"  {i}. {q.question}  →  {q.correct_answer}   [{source}]")

    usage_summary = usage_recorder.summary()
    _print_usage_table(usage_summary)

    if args.out:
        _write_out(questions, args.out)
        print(f"out: wrote {len(questions)} questions to {args.out}")
        usage_path = f"{args.out}.usage.json"
        with open(usage_path, "w", encoding="utf-8") as fh:
            json.dump(usage_summary, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"usage: wrote per-stage/model summary to {usage_path}")
    return 0


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="generate_pack",
        description="Thin-client CLI for the PackGenerator orchestrator.",
    )
    parser.add_argument(
        "--prompt",
        default="",
        help=(
            "User-facing pack prompt. Optional: omit (or pass a generic prompt "
            "like 'general knowledge') to trigger #72 F-1 no-category mode, "
            "where an LLM proposes a diverse concrete topic set for sourcing."
        ),
    )
    parser.add_argument("--language", default="en", help="ISO 639-1 language code")
    parser.add_argument(
        "--target-count",
        type=int,
        default=10,
        help="How many questions to generate (default: 10)",
    )
    parser.add_argument("--category", default=None, help="Optional category filter")
    parser.add_argument("--theme", default=None, help="Optional theme filter")
    parser.add_argument(
        "--out",
        default=None,
        help=(
            "After the run, dump surviving questions to this path as a JSON "
            "array (full Question dumps, review_status=pending_review)."
        ),
    )
    parser.add_argument(
        "--mcq-bias",
        action="store_true",
        help=(
            "Append a steering instruction to the order prompt nudging the "
            "LLM toward MCQ-routable patterns (PATTERNS_TO_MCQ)."
        ),
    )
    parser.add_argument(
        "--dedup-store",
        choices=["noop", "pgvector"],
        default="noop",
        help=(
            "Corpus the dedup stage checks against. 'noop' (default) finds no "
            "duplicates; 'pgvector' dedups against the live DATABASE_URL "
            "corpus so the 0.85 cosine guard fires against real history."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Skip the persist stage (no DB writes). Pipeline still runs; "
            "HTTP calls hit real providers unless respx mocks are installed."
        ),
    )
    parser.add_argument(
        "--topics",
        default=None,
        help=(
            "#153 experiment lever: comma-separated explicit topic list — "
            "bypasses derivation and pool sampling so every arm sources the "
            "SAME topics."
        ),
    )
    parser.add_argument(
        "--dump-facts",
        default=None,
        metavar="PATH",
        help=(
            "#153 experiment lever: after the run, dump the sourced facts "
            "(+ topics) to PATH as JSON for --facts-file re-use by other arms."
        ),
    )
    parser.add_argument(
        "--facts-file",
        default=None,
        metavar="PATH",
        help=(
            "#153 experiment lever: skip sourcing; load the fact set dumped "
            "by an earlier --dump-facts run so arms share identical facts."
        ),
    )
    # #167 (D2): the two generation modes are mutually exclusive, and each one
    # pins the order's `generation_mode` column against the server-side
    # DIRECT_GENERATION default. Omitting both leaves the column NULL, which
    # inherits that default (unchanged behaviour).
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--direct",
        action="store_true",
        help=(
            "#153 Phase 0.4 direct-generation mode: skip fact sourcing "
            "entirely (the LLM generates unconstrained by web-found facts); "
            "end-of-pipe verification still runs and carries the truth gate."
        ),
    )
    mode_group.add_argument(
        "--grounded",
        action="store_true",
        help=(
            "#167: force the grounded fact-first flow even while the "
            "server-side DIRECT_GENERATION default is on — sourcing runs (or "
            "--facts-file is joined) and the attribution gates (ungrounded "
            "drop + F8 source_url) stay armed."
        ),
    )
    parser.add_argument(
        "--per-topic-cap",
        type=int,
        default=None,
        metavar="N",
        help=(
            "#167: override CompositionStage's per-topic cap for this run. "
            "The default scales from 2-per-30 and assumes ~target/2 sourced "
            "topics; a batch with a deliberately small locked topic set (the "
            "entertainment pilot: 6 themes x ~5 questions) cannot reach its "
            "target under it, and the top-up loop pays for the full "
            "judge/verify/score pipeline chasing the impossible remainder. "
            "Omit to keep the scaled default."
        ),
    )
    parser.add_argument(
        "--no-judges",
        action="store_true",
        help=(
            "#153 experiment lever: omit the ScoringStage judge panel (and "
            "its #147 fail-closed gate) so survivors ship ungated for "
            "offline selection. Experiment runs only — never real orders."
        ),
    )
    parser.add_argument(
        "--gen-prompt-file",
        default=None,
        metavar="FILENAME",
        help=(
            "#153 experiment lever: filename within prompts/ replacing the "
            "default question_generation_v3_fact_first.md template. Fails "
            "loud when the file does not exist."
        ),
    )
    return parser.parse_args(argv)


def cli_main(argv: Sequence[str] | None = None) -> int:
    """Entrypoint — importable so tests can drive the CLI in-process."""
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    args = _parse_args(argv)
    if llm_factory.gateway() == llm_factory.SESSION:
        # #169: one-shot preflight — a logged-out CLI would otherwise surface
        # only as every question held_for_review, not as one loud failure.
        from quiz_shared.llm.session_cli import ensure_subscription_login

        ensure_subscription_login()
        print(
            "[session gateway] LLM steps run on the Claude Code subscription "
            "(unpriced tokens); judge panel OFF (founder 2026-09-02, D21: no signal)"
        )
    return asyncio.run(_run(args))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(cli_main())
