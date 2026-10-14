"""Weekly fresh-entertainment top-up (#202 task 202.3).

    python -m app.corpus.run_fresh_topup --languages en,sk,cs [--dry-run]
        [--max-usd 15] [--count 15] [--cron-checkin]

Per language: seeds (``seed_research``) → brief (``fresh_brief``) → pinned
generation (``fresh_generate``) → post-filters → import with the machine
review status (``importer.import_questions(review_status="auto")``): rows that
clear every gate go straight to the App Store, the rest wait in
``pending_review``. ``--dry-run`` does all of it except DB writes. The
generated questions are in the summary printed to stdout either way.

Guards, all before the first paid call: ``LLM_GATEWAY=session`` is refused
(never the subscription); the resolved role map must equal the pinned one
(``fresh_roles.check_roles``).

Spend (``--max-usd``, env ``FRESH_TOPUP_MAX_USD``, default $15), two gates per
language, the order rotated by ISO week so the cap never always hits the same
language:

1. A language starts only while the remaining budget covers its worst case
   (env ``FRESH_TOPUP_LANG_WORST_USD``, default $5.50 = seed max + generation
   worst case).
2. After its seeds, it generates only while the remaining budget still covers
   the generation worst case (env ``FRESH_TOPUP_GEN_WORST_USD``, default $3);
   otherwise it is skipped with the reason.

The seed call itself stops resuming at ``FRESH_TOPUP_SEED_MAX_USD`` (default
$2.50, ``seed_research``). Bound: every paid step starts only when the budget
left covers that step's worst case, so the run total can exceed ``--max-usd``
only by what one step spends beyond its estimate — one seed segment past the
seed max, or a generation past ``FRESH_TOPUP_GEN_WORST_USD`` — never by a
whole language. Measured 2026-10-14 (count 5, before these bounds): seeds
$6.17 en / $15.89 sk, generation + fact-check ~$1.2 per language.

Output: the JSON summary, then a compact human block between the
``fresh_report.SUMMARY_START`` / ``SUMMARY_END`` markers that the workflow cuts
out of the machine log for the GitHub step summary.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from datetime import date
from typing import Any

from quiz_shared.llm import factory as llm_factory

from app.corpus import fresh_report
from app.corpus.fresh_brief import build_fresh_brief
from app.corpus.fresh_generate import GenerationResult, post_filter
from app.corpus.fresh_roles import check_roles

logger = logging.getLogger("fresh_topup")

LANGUAGES = ("en", "sk", "cs")
DEFAULT_MAX_USD = 15.0
DEFAULT_LANG_WORST_USD = 5.5  # seed max $2.50 + generation worst case $3
DEFAULT_GEN_WORST_USD = 3.0
DEFAULT_COUNT = 15


class SessionGatewayRefused(SystemExit):
    """The job never runs on the Claude Code subscription."""


@dataclass
class Deps:
    """The paid / DB collaborators, injectable so tests never touch them."""

    research_seeds: Callable[..., Awaitable[Any]]
    load_covered: Callable[[date], Awaitable[list[str]]]
    generate: Callable[[str, str, int], Awaitable[GenerationResult]]
    import_questions: Callable[..., Awaitable[Any]]


def default_deps() -> Deps:
    from app.corpus import covered, importer
    from app.corpus.fresh_generate import generate_language
    from app.corpus.seed_research import research_seeds
    from app.db import engine

    async def _covered(today: date) -> list[str]:
        return await covered.load_covered(engine, today=today)

    return Deps(research_seeds, _covered, generate_language, importer.import_questions)


def rotate(languages: Sequence[str], today: date) -> list[str]:
    """Shift the order by one language per ISO week."""
    langs = list(languages)
    if not langs:
        return langs
    k = today.isocalendar()[1] % len(langs)
    return langs[k:] + langs[:k]


def refuse_session_gateway() -> None:
    if llm_factory.gateway() == llm_factory.SESSION:
        raise SessionGatewayRefused(
            "fresh_topup refuses LLM_GATEWAY=session: the weekly job runs on the "
            "Anthropic API, never on the Claude Code subscription."
        )


def _usd(cents: float) -> float:
    return round(cents / 100, 4)


def _env_cents(name: str, default_usd: float) -> float:
    return float(os.getenv(name) or default_usd) * 100


async def run_language(
    lang: str,
    today: date,
    *,
    count: int,
    dry_run: bool,
    covered: list[str],
    deps: Deps,
    budget_cents: float = float("inf"),
) -> tuple[dict[str, Any], float]:
    """One language end to end → (summary entry, spend in cents).

    ``budget_cents`` is what the run has left when this language starts.
    """
    entry: dict[str, Any] = {"status": "done", "reason": None}
    seeds = await deps.research_seeds(lang, today)
    spent = seeds.cost_cents
    entry.update(
        seeds=len(seeds.seeds),
        seed_candidates=seeds.candidates,
        seed_dropped=seeds.dropped,
        page_check=seeds.page_check,
        domestic_share=seeds.domestic_share,
        fame_checked=seeds.fame_checked,
    )
    if seeds.budget_stopped:
        entry["seed_budget_stopped"] = True
    # Sentry scrubs keys containing "token" (tokens_usd arrived as null in the
    # 2026-10-14 summary), so the generation's model spend is "model_usd".
    cost = {"seeds_usd": _usd(seeds.cost_cents), "total_usd": _usd(spent)}
    entry["cost"] = cost
    if seeds.error or not seeds.seeds:
        entry.update(status="failed", reason=seeds.error or "no usable seeds")
        return entry, spent
    gen_worst = _env_cents("FRESH_TOPUP_GEN_WORST_USD", DEFAULT_GEN_WORST_USD)
    if budget_cents - spent < gen_worst:
        entry.update(
            status="skipped",
            reason=(
                f"budget after seeds: ${_usd(budget_cents - spent):.2f} left < "
                f"generation worst case ${_usd(gen_worst):.2f}"
            ),
        )
        return entry, spent

    brief = build_fresh_brief(lang, today, seeds.seeds, covered)
    gen = await deps.generate(lang, brief, count)
    spent += gen.cost_cents
    cost.update(
        model_usd=_usd(gen.tokens_cents),
        factcheck_search_usd=_usd(gen.factcheck_search_cents),
        total_usd=_usd(spent),
    )
    if gen.unpriced_models:
        entry["unpriced_models"] = gen.unpriced_models
    entry["generated"] = len(gen.questions)
    if gen.error:
        entry.update(status="failed", reason=gen.error)
        return entry, spent

    kept, dropped = post_filter(gen.questions, lang)
    try:
        result = await deps.import_questions(
            kept, review_status="auto", execute=not dry_run
        )
    except Exception as exc:  # keep the measured spend; report the language failed
        logger.exception("fresh import %s failed", lang)
        entry.update(status="failed", reason=f"import: {type(exc).__name__}: {exc}")
        return entry, spent
    for reason in result.skipped.values():
        dropped[f"guard:{reason}"] = dropped.get(f"guard:{reason}", 0) + 1
    if result.already_present:
        dropped["already_present"] = result.already_present
    entry.update(
        approved=result.approved,
        pending=result.pending,
        inserted=result.inserted,
        dropped=dropped,
        pending_reasons=result.block_reasons,
    )
    # Corpus content only (logs are public): the founder spot-checks it in the
    # workflow summary, live runs included.
    entry["questions"] = [
        {
            **q.model_dump(mode="json", exclude={"embedding", "embedding_qa"}),
            "review_status": result.statuses.get(q.id),
        }
        for q in kept
    ]
    return entry, spent


async def run(
    args: argparse.Namespace, deps: Deps | None = None, today: date | None = None
) -> dict:
    """Guards, then the languages in rotated order under the spend cap."""
    refuse_session_gateway()
    today = today or date.today()
    languages = rotate(args.languages, today)
    check_roles(languages)
    deps = deps or default_deps()
    worst_cents = _env_cents("FRESH_TOPUP_LANG_WORST_USD", DEFAULT_LANG_WORST_USD)
    max_cents = args.max_usd * 100
    summary: dict[str, Any] = {
        "run": "fresh-topup",
        "date": today.isoformat(),
        "iso_week": fresh_report.iso_week(today),
        "dry_run": args.dry_run,
        "order": languages,
        "max_usd": args.max_usd,
        "cap_hit": False,
        "languages": {},
    }
    covered = await deps.load_covered(today)
    spent = 0.0
    for lang in languages:
        if max_cents - spent < worst_cents:
            summary["cap_hit"] = True
            summary["languages"][lang] = {
                "status": "skipped",
                "reason": f"budget: ${_usd(max_cents - spent):.2f} left < worst case ${_usd(worst_cents):.2f}",
            }
            continue
        entry, cents = await run_language(
            lang,
            today,
            count=args.count,
            dry_run=args.dry_run,
            covered=covered,
            deps=deps,
            budget_cents=max_cents - spent,
        )
        spent += cents
        summary["languages"][lang] = entry
        if entry["status"] == "skipped":
            summary["cap_hit"] = True
    if spent > max_cents:
        summary["cap_hit"] = True
    summary["spent_usd"] = _usd(spent)
    return summary


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Weekly fresh-entertainment top-up (#202)."
    )
    parser.add_argument("--languages", default="en,sk,cs")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--max-usd",
        type=float,
        default=float(os.getenv("FRESH_TOPUP_MAX_USD") or DEFAULT_MAX_USD),
    )
    parser.add_argument("--count", type=int, default=DEFAULT_COUNT)
    parser.add_argument(
        "--cron-checkin",
        action="store_true",
        help="Sentry Crons check-ins (scheduled runs only)",
    )
    args = parser.parse_args(argv)
    args.languages = [x.strip() for x in args.languages.split(",") if x.strip()]
    unknown = sorted(set(args.languages) - set(LANGUAGES))
    if unknown or not args.languages:
        parser.error(
            f"--languages must be a subset of {','.join(LANGUAGES)}; got {unknown}"
        )
    return args


def main(argv: Sequence[str] | None = None, deps: Deps | None = None) -> int:
    from app.config import get_settings
    from app.logging_config import init_sentry, setup_logging

    args = parse_args(argv)
    setup_logging()
    init_sentry(get_settings().sentry_dsn)
    check_in = fresh_report.checkin_start(args.cron_checkin)
    ok = False
    try:
        summary = asyncio.run(run(args, deps))
        ok = not any(e["status"] == "failed" for e in summary["languages"].values())
        fresh_report.send_summary(summary)
        # Compact block first, flushed: Fly's log shipping dropped the tail of
        # the big JSON dump on 2026-10-14, block and all. The JSON stays for
        # the artifact; losing its end no longer loses the summary.
        sys.stdout.write(fresh_report.compact_summary(summary) + "\n")
        sys.stdout.flush()
        json.dump(summary, sys.stdout, ensure_ascii=False, default=str)
        sys.stdout.write("\n")
        sys.stdout.flush()
    except BaseException as exc:
        import sentry_sdk

        sentry_sdk.capture_exception(exc)
        raise
    finally:
        fresh_report.checkin_finish(check_in, ok)
        import sentry_sdk

        sentry_sdk.flush(timeout=10)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
