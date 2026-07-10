#!/usr/bin/env python3
"""Phase-5 validation harness for issue #72 (question fun/engagement redesign).

Runs the reworked generation flow over a small fixed set of dev topics across
**all** question types and asserts machine-checkable QUALITY PROXIES. These
prove the flow is *plumbing-correct and not-obviously-boring* — they do **not**
prove "fun". Fun is the founder's Phase-6 by-ear gate (6b); no proxy replaces it.

Proxies asserted (issue #72 Plan, Phase 5):
  * non-empty           — the flow produced questions at all (a no-crash proxy)
  * non-recall per type — ≥1 reasoning (pattern 7-13) question per question type
  * pattern diversity    — ≥ MIN_DISTINCT_PATTERNS distinct reasoning patterns
  * banned openers       — zero "What is the capital…/Who wrote…/What year did…"
  * "Which" openers       — ≤ MAX_WHICH_OPENER_FRACTION of the batch
  * MCQ valid            — option dict + correct key + distractor rules
  * answer brevity       — the spoken answer stays short (voice-first)

CORPUS-WRITE GUARD: the flow is built with ``persist=False`` and
``assert_no_corpus_write`` raises if any persisting stage is present, so this
harness can **never** write to the corpus (issue #72 stop condition). It spends
no paid generation by itself — the actual LLM run is the founder-authorized
Phase-6 step; this module only wires the flow and scores its output.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Sequence

if TYPE_CHECKING:  # avoid importing the heavy model at module import time
    from quiz_shared.models.question import Question

# ---------------------------------------------------------------------------
# Pattern taxonomy (issue #72 — Pattern Library 1-13 + MCQ synthetic forms)
# ---------------------------------------------------------------------------

# Recall-leaning fact-retrieval patterns (Pattern Library 1-6).
RECALL_PATTERNS: frozenset[str] = frozenset(
    {
        "surprising_connection",
        "hidden_property",
        "wordplay_revelation",
        "scale_surprise",
        "historical_quirk",
        "biological_physical_oddity",
        "true_false",  # MCQ synthetic recall form (RC-6 complement of fun)
    }
)

# Reasoning / non-recall patterns (Pattern Library 7-13) plus the MCQ
# synthetic reasoning forms unlocked in Phase 1 (order_of_magnitude — P1.4) and
# the estimation-flavoured year_guess.
REASONING_PATTERNS: frozenset[str] = frozenset(
    {
        "number_sequence",
        "verbal_analogy",
        "odd_one_out",
        "lateral_thinking_puzzle",
        "estimation",
        "comparison_bet_older_larger",
        "reverse_engineer",
        "order_of_magnitude",
        "year_guess",
    }
)

# Documented format red flags from prompts/question_generation_v2_cot.md.
# Normalized to lowercase prefixes; matched against the stripped question text.
BANNED_OPENERS: tuple[str, ...] = (
    "what is the capital of",
    "who wrote",
    "what year did",
    "which author",
)

# Thresholds (named so the test pins intent, not magic numbers).
MIN_DISTINCT_PATTERNS = 3  # mirrors the prompt's "≥3 reasoning patterns / 10"
MAX_WHICH_OPENER_FRACTION = 0.30  # "Which" is an MCQ crutch; cap it
MIN_MCQ_OPTIONS = 2  # ≥2 options ⇒ ≥1 distractor
MAX_ANSWER_WORDS = 6  # voice-first: the spoken answer must stay short

# Small fixed set of dev topics for the Phase-6 flow run (throwaway output).
DEV_TOPICS: tuple[str, ...] = (
    "space exploration",
    "the human body",
    "ancient Rome",
    "famous inventions",
)

# The PackGenerator stage that writes the corpus (PersistStage.name).
PERSIST_STAGE_NAME = "persisting"


# ---------------------------------------------------------------------------
# Proxy results
# ---------------------------------------------------------------------------


@dataclass
class ProxyResult:
    """Outcome of one quality proxy over a batch of questions."""

    name: str
    passed: bool
    detail: str
    violations: list[str] = field(default_factory=list)


def _pattern_of(q: "Question") -> str | None:
    meta = getattr(q, "generation_metadata", None)
    return getattr(meta, "reasoning_pattern", None) if meta else None


def _norm_text(text: str) -> str:
    return " ".join((text or "").lower().split())


def _spoken_answer(q: "Question") -> str:
    """Resolve the answer the user must *say*, regardless of type.

    For MCQ the stored ``correct_answer`` is the option key ("a"); the spoken
    answer is that option's value. Multi-select keys join their values.
    """
    correct = getattr(q, "correct_answer", None)
    options = getattr(q, "possible_answers", None) or {}
    keys = correct if isinstance(correct, list) else [correct]
    if options:
        resolved = [str(options.get(k, k)) for k in keys]
        return " ".join(resolved).strip()
    return " ".join(str(k) for k in keys).strip()


# ---------------------------------------------------------------------------
# Proxies — each is pure: (questions) -> ProxyResult
# ---------------------------------------------------------------------------


def proxy_non_empty(questions: Sequence["Question"]) -> ProxyResult:
    """The flow produced questions at all — a stand-in for "did not crash"."""
    passed = len(questions) > 0
    return ProxyResult(
        name="non_empty",
        passed=passed,
        detail=f"{len(questions)} question(s) produced",
        violations=[] if passed else ["flow produced zero questions"],
    )


def proxy_non_recall_per_type(questions: Sequence["Question"]) -> ProxyResult:
    """Every question *type* present carries ≥1 reasoning (non-recall) pattern."""
    by_type: dict[str, bool] = {}
    for q in questions:
        qtype = getattr(q, "type", "?")
        has = _pattern_of(q) in REASONING_PATTERNS
        by_type[qtype] = by_type.get(qtype, False) or has
    violations = [f"type {t!r} has no reasoning pattern" for t, ok in by_type.items() if not ok]
    return ProxyResult(
        name="non_recall_per_type",
        passed=not violations and bool(by_type),
        detail=f"types checked: {sorted(by_type)}",
        violations=violations,
    )


def proxy_pattern_diversity(questions: Sequence["Question"]) -> ProxyResult:
    """At least MIN_DISTINCT_PATTERNS distinct reasoning patterns in the batch."""
    distinct = {p for q in questions if (p := _pattern_of(q)) in REASONING_PATTERNS}
    passed = len(distinct) >= MIN_DISTINCT_PATTERNS
    detail = f"{len(distinct)} distinct reasoning pattern(s); need ≥{MIN_DISTINCT_PATTERNS}"
    return ProxyResult(
        name="pattern_diversity",
        passed=passed,
        detail=detail,
        violations=[] if passed else [detail],
    )


def proxy_no_banned_openers(questions: Sequence["Question"]) -> ProxyResult:
    """No question opens with a documented format red flag."""
    violations: list[str] = []
    for q in questions:
        text = _norm_text(getattr(q, "question", ""))
        for opener in BANNED_OPENERS:
            if text.startswith(opener):
                violations.append(f"{opener!r}: {getattr(q, 'question', '')!r}")
                break
    return ProxyResult(
        name="no_banned_openers",
        passed=not violations,
        detail=f"{len(violations)} banned opener(s)",
        violations=violations,
    )


def proxy_which_opener_fraction(questions: Sequence["Question"]) -> ProxyResult:
    """At most MAX_WHICH_OPENER_FRACTION of questions open with "Which"."""
    if not questions:
        return ProxyResult("which_opener_fraction", True, "no questions", [])
    which = sum(1 for q in questions if _norm_text(getattr(q, "question", "")).startswith("which"))
    frac = which / len(questions)
    passed = frac <= MAX_WHICH_OPENER_FRACTION
    detail = f"{which}/{len(questions)} = {frac:.0%} 'Which' openers; cap {MAX_WHICH_OPENER_FRACTION:.0%}"
    return ProxyResult(
        name="which_opener_fraction",
        passed=passed,
        detail=detail,
        violations=[] if passed else [detail],
    )


def proxy_mcq_valid(questions: Sequence["Question"]) -> ProxyResult:
    """MCQ questions have a valid option dict, a correct key, and ≥1 distractor."""
    violations: list[str] = []
    mcq = [q for q in questions if getattr(q, "type", None) == "text_multichoice"]
    for q in mcq:
        label = (getattr(q, "question", "") or "")[:50]
        options = getattr(q, "possible_answers", None)
        if not isinstance(options, dict) or len(options) < MIN_MCQ_OPTIONS:
            violations.append(f"{label!r}: needs ≥{MIN_MCQ_OPTIONS} options, got {options!r}")
            continue
        values = [str(v).strip() for v in options.values()]
        if any(not v for v in values):
            violations.append(f"{label!r}: blank option value")
        if len(set(values)) != len(values):
            violations.append(f"{label!r}: duplicate option values")
        correct = getattr(q, "correct_answer", None)
        keys = correct if isinstance(correct, list) else [correct]
        missing = [k for k in keys if k not in options]
        if missing:
            violations.append(f"{label!r}: correct key(s) {missing!r} not in options {sorted(options)}")
    return ProxyResult(
        name="mcq_valid",
        passed=not violations,
        detail=f"{len(mcq)} MCQ question(s) checked",
        violations=violations,
    )


def proxy_answer_brevity(questions: Sequence["Question"]) -> ProxyResult:
    """The spoken answer stays short (≤ MAX_ANSWER_WORDS words) for voice-first."""
    violations: list[str] = []
    for q in questions:
        spoken = _spoken_answer(q)
        words = len(spoken.split())
        if words > MAX_ANSWER_WORDS:
            violations.append(f"{spoken!r} ({words} words > {MAX_ANSWER_WORDS})")
    return ProxyResult(
        name="answer_brevity",
        passed=not violations,
        detail=f"max {MAX_ANSWER_WORDS} words/answer",
        violations=violations,
    )


ALL_PROXIES = (
    proxy_non_empty,
    proxy_non_recall_per_type,
    proxy_pattern_diversity,
    proxy_no_banned_openers,
    proxy_which_opener_fraction,
    proxy_mcq_valid,
    proxy_answer_brevity,
)


def run_proxies(questions: Sequence["Question"]) -> list[ProxyResult]:
    """Run every proxy and return the per-proxy results."""
    return [proxy(questions) for proxy in ALL_PROXIES]


def all_passed(results: Sequence[ProxyResult]) -> bool:
    return all(r.passed for r in results)


def report_lines(results: Sequence[ProxyResult]) -> list[str]:
    lines: list[str] = []
    for r in results:
        mark = "PASS" if r.passed else "FAIL"
        lines.append(f"[{mark}] {r.name}: {r.detail}")
        for v in r.violations:
            lines.append(f"        - {v}")
    return lines


# ---------------------------------------------------------------------------
# Corpus-write guard (issue #72 stop condition: never write the corpus)
# ---------------------------------------------------------------------------


def _is_persister(stage: object) -> bool:
    return (
        getattr(stage, "name", None) == PERSIST_STAGE_NAME
        or type(stage).__name__ == "PersistStage"
    )


def assert_no_corpus_write(stages: Sequence[object]) -> None:
    """Raise if any stage would persist to the corpus.

    The validation flow is always built with ``persist=False``; this is the
    belt-and-suspenders check that nothing slips a PersistStage into the run.
    """
    persisters = [type(s).__name__ for s in stages if _is_persister(s)]
    if persisters:
        raise RuntimeError(
            "validate_generation must never write to the corpus, but the stage "
            f"list contains a persisting stage: {persisters}"
        )


# ---------------------------------------------------------------------------
# Dry-run flow (Phase-6 execution path; not exercised by the offline gate)
# ---------------------------------------------------------------------------


def build_dry_run_stages(dedup_store_name: str = "noop") -> list[object]:
    """Build the persist-free stage list and assert it never writes the corpus.

    Reuses ``generate_pack``'s builders so the validated flow is byte-identical
    to production minus the PersistStage.
    """
    import scripts.generate_pack as generate_pack

    dedup_store = generate_pack._build_dedup_store(dedup_store_name)
    stages = generate_pack._build_stages(persist=False, dedup_store=dedup_store)
    assert_no_corpus_write(stages)
    return stages


def _order_namespace(
    prompt: str, *, target_count: int, language: str, mcq_bias: bool = False
) -> argparse.Namespace:
    """The exact attribute set `generate_pack._build_order` consumes.

    Kept as one helper (and pinned by a test) so a new `_build_order` CLI
    attribute breaks loudly here instead of failing every topic at runtime
    (2026-07-10: `--mcq-bias` drift produced a zero-question run).
    """
    return argparse.Namespace(
        prompt=prompt,
        language=language,
        target_count=target_count,
        category=None,
        theme=None,
        mcq_bias=mcq_bias,
    )


async def run_validation_flow(
    prompt: str, *, target_count: int, language: str, mcq_bias: bool = False
) -> list["Question"]:
    """Run the reworked flow for one prompt and return its questions (no persist)."""
    import scripts.generate_pack as generate_pack
    from app.orchestrator.pack_generator import PackGenerator
    from app.orchestrator.progress_sink import ProgressSink

    args = _order_namespace(
        prompt, target_count=target_count, language=language, mcq_bias=mcq_bias
    )
    order = generate_pack._build_order(args)
    stages = build_dry_run_stages()

    def _sink_factory(_order_id: str) -> ProgressSink:
        return generate_pack._StdoutSink()  # type: ignore[return-value]

    pack_generator = PackGenerator(stages=stages, sink_factory=_sink_factory)
    await pack_generator.run(order)
    ctx = pack_generator.last_ctx
    return list(ctx.questions) if ctx else []


async def _run(args: argparse.Namespace) -> int:
    prompts = list(args.prompt) if args.prompt else list(DEV_TOPICS)
    questions: list["Question"] = []
    for prompt in prompts:
        questions.extend(
            await run_validation_flow(
                prompt, target_count=args.target_count, language=args.language
            )
        )

    results = run_proxies(questions)
    print(f"validated {len(questions)} question(s) across {len(prompts)} topic(s)\n")
    for line in report_lines(results):
        print(line)
    ok = all_passed(results)
    print("\n" + ("ALL PROXIES PASSED" if ok else "PROXY FAILURES — flow not plumbing-clean"))
    return 0 if ok else 1


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="validate_generation",
        description="Issue #72 Phase-5 quality-proxy harness (never writes the corpus).",
    )
    parser.add_argument(
        "--prompt",
        action="append",
        default=None,
        help="Topic prompt (repeatable); defaults to the fixed DEV_TOPICS set.",
    )
    parser.add_argument("--language", default="en", help="ISO 639-1 language code")
    parser.add_argument("--target-count", type=int, default=10, help="Questions per topic")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    return asyncio.run(_run(_parse_args(argv)))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
