#!/usr/bin/env python3
"""#168 batch translation runner — the corpus-scale SK/CS translator (T15–T17).

Run from apps/quiz-pack-api/:

    uv run --no-sync python scripts/translate_corpus.py [plan] --language sk
    uv run --no-sync python scripts/translate_corpus.py submit --language sk --limit 50 --confirm
    uv run --no-sync python scripts/translate_corpus.py ingest --job-id <id>
    uv run --no-sync python scripts/translate_corpus.py verify --language sk --limit 50 --confirm
    uv run --no-sync python scripts/translate_corpus.py review-export --language sk
    uv run --no-sync python scripts/translate_corpus.py report --coverage --language sk
    uv run --no-sync python scripts/translate_corpus.py reconcile --language sk

`plan` is the default and free. `submit` and `verify` spend (API credits or
subscription quota) and therefore require `--limit` AND `--confirm`. The DB is
written only by `ingest` (pending rows), `verify` (verdicts + the
`approved_languages` gate), `corrections` and `reconcile` — never by `submit`.
Under `LLM_GATEWAY=session` every LLM leg runs on the Claude Code subscription
(#169); the model actually used is recorded in each row's provenance.

`--database-url` defaults to `DATABASE_URL`; pass `$PROD_DATABASE_URL` for prod.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors

load_dotenv_from_ancestors(Path(__file__))

from scripts.translation_runner import reconcile as rec
from scripts.translation_runner import report as rep
from scripts.translation_runner import review as rv
from scripts.translation_runner import translate as tr
from scripts.translation_runner import verify as ver
from scripts.translation_runner import workset as ws


def _parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--database-url", default=None, help="defaults to DATABASE_URL")
    sub = p.add_subparsers(dest="command")

    def lang(sp):
        sp.add_argument("--language", required=True, choices=ws.SUPPORTED_LANGUAGES)

    def channels(sp):
        sp.add_argument(
            "--review-status",
            default=",".join(ws.DEFAULT_REVIEW_STATUSES),
            help="comma-separated review channels that count as work",
        )

    s = sub.add_parser("plan", help="work set + estimate (default, free)")
    lang(s)
    channels(s)

    s = sub.add_parser("submit", help="translate the work set into a job JSONL")
    lang(s)
    channels(s)
    s.add_argument("--limit", type=int, required=True)
    s.add_argument("--confirm", action="store_true", help="required: this step spends")
    s.add_argument(
        "--model", default=None, help=f"override the DD8 model {tr.TRANSLATION_MODEL}"
    )
    s.add_argument("--concurrency", type=int, default=4)
    s.add_argument("--job-id", default=None, help="resume an existing job")

    s = sub.add_parser("poll", help="job status")
    s.add_argument("--job-id", required=True)

    s = sub.add_parser("ingest", help="write a job's translations as pending rows")
    s.add_argument("--job-id", required=True)

    s = sub.add_parser("verify", help="run the gate over pending rows")
    lang(s)
    s.add_argument("--limit", type=int, required=True)
    s.add_argument("--confirm", action="store_true", help="required: this step spends")
    s.add_argument("--concurrency", type=int, default=4)
    s.add_argument("--judge-model", default=None)
    s.add_argument("--answerability-model", default=None)

    s = sub.add_parser("review-export", help="critical + flagged + sample → arm file")
    lang(s)
    s.add_argument("--sample", type=int, default=20)
    s.add_argument("--seed", type=int, default=168)
    s.add_argument("--out", type=Path, default=None)

    s = sub.add_parser("corrections", help="append founder corrections (JSON list)")
    s.add_argument("--file", type=Path, required=True)

    s = sub.add_parser("glossary", help="print the MQM category histogram")
    lang(s)

    s = sub.add_parser("report", help="coverage bars (--coverage)")
    s.add_argument("--coverage", action="store_true", required=True)
    lang(s)
    s.add_argument("--cell-floor", type=int, default=rep.CELL_FLOOR)
    s.add_argument("--cell-ratio", type=float, default=rep.CELL_RATIO)
    s.add_argument("--category-floor", type=int, default=rep.CATEGORY_FLOOR)
    s.add_argument(
        "--waive",
        action="append",
        default=[],
        metavar='CATEGORY[/DIFFICULTY]="reason"',
        help="per-run waiver, recorded verbatim in the run report",
    )

    s = sub.add_parser("reconcile", help="consistency + staleness legs")
    lang(s)
    s.add_argument(
        "--fix", action="store_true", help="rewrite approved_languages on mismatch"
    )

    args = p.parse_args(argv)
    if args.command is None:
        p.error(
            "a subcommand is required (plan is the free default: `plan --language sk`)"
        )
    return args


def _engine(url: str | None):
    import os

    from app.db.engine import build_engine

    raw = url or os.environ.get("DATABASE_URL")
    if not raw:
        raise SystemExit("--database-url or DATABASE_URL is required")
    return build_engine(raw)


def _statuses(arg: str) -> list[str]:
    return [s.strip() for s in arg.split(",") if s.strip()]


async def _work(engine, language: str, statuses: list[str]) -> list[dict]:
    rows = await ws.fetch_source_rows(engine, statuses)
    states = await ws.fetch_translation_states(engine, language)
    return ws.work_set(rows, states)


async def cmd_plan(args, engine) -> int:
    work = await _work(engine, args.language, _statuses(args.review_status))
    model = tr.TRANSLATION_MODEL[args.language]
    transport, used = tr.resolve_transport(model)
    cells = Counter((r["category"], r["difficulty"]) for r in work)
    print(
        f"plan --language {args.language}: {len(work)} row(s) to translate "
        f"(channels {args.review_status}; model {used} via {transport})"
    )
    for (cat, diff), n in sorted(cells.items()):
        print(f"  {cat:<18}{diff:<8}{n:>4}")
    est = 0.0 if transport == "session" else len(work) * tr.EST_USD_PER_REQUEST
    print(
        f"estimate: {len(work)} request(s), ~${est:.2f} "
        f"({'subscription, 0 API credits' if transport == 'session' else 'order of magnitude'})"
    )
    return 0


async def cmd_submit(args, engine) -> int:
    if not args.confirm:
        print("submit spends — re-run with --confirm", file=sys.stderr)
        return 2
    model = args.model or tr.TRANSLATION_MODEL[args.language]
    job = ws.Job(args.job_id or ws.Job.new_id(args.language))
    if job.meta() is None:
        job.append(
            {
                "kind": "meta",
                "language": args.language,
                "model": model,
                "review_status": args.review_status,
            }
        )
    work = await _work(engine, args.language, _statuses(args.review_status))
    done = job.done_qids()
    todo = [r for r in work if str(r["id"]) not in done][: args.limit]
    print(
        f"job {job.id}: {len(todo)} to translate ({len(done)} already done in this job)"
    )
    if not todo:
        return 0
    transport, _ = tr.resolve_transport(model)
    before = None
    if transport != "session":
        from app.cost_tracking import fetch_openrouter_usage

        before = await fetch_openrouter_usage()
    failures = await tr.translate_rows(
        todo, args.language, model=model, job=job, concurrency=args.concurrency
    )
    await tr.record_cost(
        job,
        transport=transport,
        n_requests=len(todo) - len(failures),
        usage_before=before,
    )
    print(
        f"job {job.id}: {len(todo) - len(failures)} translated, {len(failures)} failed "
        f"→ next: ingest --job-id {job.id}"
    )
    if failures:
        print("FAILED ids: " + ", ".join(failures), file=sys.stderr)
        return 1
    return 0


async def cmd_poll(args, engine) -> int:
    job = ws.Job(args.job_id)
    meta = job.meta()
    if meta is None:
        print(f"no job {args.job_id}", file=sys.stderr)
        return 1
    print(
        f"job {job.id}: {len(job.done_qids())} translated, "
        f"{len(job.done_qids('failure'))} failed, {len(job.done_qids('ingested'))} ingested, "
        f"cost_usd={job.cost_usd()} (sync/session transport: nothing to poll)"
    )
    return 0


async def cmd_ingest(args, engine) -> int:
    n = await tr.ingest_job(engine, ws.Job(args.job_id))
    return 0 if n >= 0 else 1


async def cmd_verify(args, engine) -> int:
    if not args.confirm:
        print("verify spends — re-run with --confirm", file=sys.stderr)
        return 2
    outcomes = await ver.verify_rows(
        engine,
        args.language,
        limit=args.limit,
        concurrency=args.concurrency,
        judge_model=args.judge_model,
        answerability_model=args.answerability_model,
    )
    print(f"verify --language {args.language}: {dict(outcomes)}")
    return 0


async def cmd_review_export(args, engine) -> int:
    out = args.out or Path(f"data/translation_review/{args.language}-review.json")
    buckets = await rv.review_export(
        engine, args.language, sample=args.sample, seed=args.seed, out=out
    )
    print(
        f"review export → {out} ({dict(buckets)}); reasons in {out.with_suffix('.reasons.json')}"
    )
    print(
        f"publish: python scripts/rating_page/publish_batch.py --arm {args.language}={out} "
        f"--seed {args.seed} --title 'Preklad {args.language} — review' --base-url <prod>"
    )
    return 0


async def cmd_corrections(args, engine) -> int:
    items = json.loads(args.file.read_text(encoding="utf-8"))
    n = await rv.ingest_corrections(engine, items)
    print(f"appended {n} correction(s)")
    return 0


async def cmd_glossary(args, engine) -> int:
    hist = await rv.glossary_histogram(engine, args.language)
    print(
        f"MQM category histogram ({args.language}) — report only; glossary files are curated by PR:"
    )
    for cat, n in hist.most_common():
        print(f"  {cat:<24}{n:>4}")
    return 0


def _parse_waivers(specs: list[str]) -> dict[str, str]:
    out = {}
    for spec in specs:
        target, sep, reason = spec.partition("=")
        if not sep or not reason.strip():
            raise SystemExit(
                f'--waive expects CATEGORY[/DIFFICULTY]="reason", got {spec!r}'
            )
        out[target.strip()] = reason.strip().strip('"')
    return out


async def cmd_report(args, engine) -> int:
    report = await rep.coverage(
        engine,
        args.language,
        cell_floor=args.cell_floor,
        cell_ratio=args.cell_ratio,
        category_floor=args.category_floor,
        waivers=_parse_waivers(args.waive),
    )
    print(rep.render(report))
    path = rep.write_run_report(report)
    print(f"run report: {path}")
    if not report.ok:
        print("missing qids: " + " ".join(report.missing_qids), file=sys.stderr)
        return 1
    return 0


async def cmd_reconcile(args, engine) -> int:
    findings = await rec.reconcile(engine, args.language, fix=args.fix)
    for f in findings.stale:
        print(
            f"STALE {f['qid']} {f['language']} {f['old_hash'][:12]} → {f['new_hash'][:12]} (demoted)"
        )
    for f in findings.consistency:
        print(f"MISMATCH {f['qid']}: {f['issue']}" + (" (fixed)" if args.fix else ""))
    print(
        f"reconcile --language {args.language}: {len(findings.stale)} stale, "
        f"{len(findings.consistency)} mismatch → {'clean' if findings.clean else 'FINDINGS'}"
    )
    return 0 if findings.clean else 1


COMMANDS = {
    "plan": cmd_plan,
    "submit": cmd_submit,
    "poll": cmd_poll,
    "ingest": cmd_ingest,
    "verify": cmd_verify,
    "review-export": cmd_review_export,
    "corrections": cmd_corrections,
    "glossary": cmd_glossary,
    "report": cmd_report,
    "reconcile": cmd_reconcile,
}


async def _main(args) -> int:
    engine = _engine(args.database_url)
    try:
        return await COMMANDS[args.command](args, engine)
    finally:
        await engine.dispose()


def main(argv=None) -> int:
    return asyncio.run(_main(_parse_args(argv)))


if __name__ == "__main__":
    sys.exit(main())
