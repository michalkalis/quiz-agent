"""Phase-1 translation arm test for issue #168 (T3, DD8).

Four arms — `opus`, `gemini`, `gpt41`, `deepl` — translate the SAME sample of
approved English questions into SK and CS, so the founder can rate them blind
on the #154 rating web (Session B) and pick a model per language. The arms are
files, not database rows, which is why this runs before the migration gate.

Sampling is deterministic (`--seed`): eligible rows are
`pack_id IS NULL AND review_status='approved' AND language_dependent=false`,
spread round-robin across the 18 (category x difficulty) cells so no arm is
judged on an accidentally easy slice.

Cost (LD0, founder 2026-09-01): `--plan` is the default and only prints the
work set plus an estimate. Spending requires `--execute`, and anything
estimated above $5 must stop and ask the founder first.

Output: `data/translation_arms/<arm>-<language>.json`, each a JSON list in the
shape `scripts/rating_page/build_page.py:57-68` reads.

  Session B note: publish these WITHOUT `--dedupe-by-fact`. Every arm carries
  the same `source_url` values by construction, so that flag would collapse
  the four arms down to one.

Usage (from apps/quiz-pack-api/, repo .env loaded, prod reached read-only
through `fly proxy -p 5433:5432 -a quiz-pack-db` in another shell):

    uv run --no-sync python scripts/translate_arms.py --seed 168            # plan
    uv run --no-sync python scripts/translate_arms.py --seed 168 --execute
"""

import argparse
import asyncio
import json
import os
import random
import sys
from collections import defaultdict
from collections.abc import Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors
from scripts.translate_arms_backends import (
    ARMS,
    run_batch_arm,
    run_deepl_arm,
)


def _configure_environment() -> None:
    """Load the repo `.env` and pin the gateway — from `main`, never on import.

    Batch inference exists only on OpenRouter for us (see `quiz_shared.llm.batch`),
    and keeping the sync fallback on the same bill is what makes the DD9 credits
    delta a true total. Doing it at import time instead would leak into any
    process that merely imports this module — including the test suite, whose
    conftest deliberately pins `LLM_GATEWAY=direct` to keep its provider mocks
    hermetic.
    """
    load_dotenv_from_ancestors(Path(__file__).resolve())
    os.environ["LLM_GATEWAY"] = "openrouter"

CATEGORIES = (
    "science-nature",
    "history",
    "geography-world",
    "movies-music",
    "sports",
    "food-everyday",
)
DIFFICULTIES = ("easy", "medium", "hard")

#: Below this the arm test cannot separate four arms, so it fails loud rather
#: than producing a verdict nobody should trust (DD8 asks for ~30-40).
MIN_SAMPLE = 20

SELECT_COLUMNS = (
    "id",
    "question",
    "possible_answers",
    "correct_answer",
    "alternative_answers",
    "explanation",
    "topic",
    "category",
    "difficulty",
    "source_url",
)

#: Measured on the DD7 smoke (5 short requests, Opus 5 batch, $0.0044625) and
#: scaled for a real question payload. Order-of-magnitude only — it exists to
#: catch an LD0-sized surprise before it happens, not to bill anyone.
EST_USD_PER_REQUEST = {"opus": 0.010, "gemini": 0.003, "gpt41": 0.004, "deepl": 0.0}
LD0_CAP_USD = 5.0


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seed", type=int, required=True, help="deterministic sample seed")
    p.add_argument("--count", type=int, default=35, help="questions per language (~35)")
    p.add_argument("--languages", default="sk,cs")
    p.add_argument("--arms", default=",".join(ARMS), help=f"subset of {','.join(ARMS)}")
    p.add_argument("--out-dir", type=Path, default=Path("data/translation_arms"))
    p.add_argument(
        "--database-url",
        default=None,
        help="defaults to PROD_DATABASE_URL, then DATABASE_URL (read-only use)",
    )
    p.add_argument(
        "--execute",
        action="store_true",
        help="actually call the providers and write arm files (LD0: default is plan-only)",
    )
    return p.parse_args(argv)


def sample_questions(rows: list[dict[str, Any]], count: int, seed: int) -> list[dict]:
    """Round-robin the 18 (category x difficulty) cells so the sample is spread.

    A plain seeded shuffle would let one category dominate a 35-row draw, and
    the founder would then be rating translation quality on, say, mostly
    geography — which is not what the verdict is supposed to measure.
    """
    cells: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        cells[(row["category"], row["difficulty"])].append(row)

    rng = random.Random(seed)
    for bucket in cells.values():
        rng.shuffle(bucket)

    order = [
        (c, d)
        for d in DIFFICULTIES
        for c in CATEGORIES
        if cells.get((c, d))
    ]
    # Cells outside the canonical taxonomy (legacy/free-form) still count as
    # eligible corpus; append them so they can fill a thin draw.
    order += sorted(k for k in cells if k not in order)

    picked: list[dict] = []
    while len(picked) < count:
        took = False
        for key in order:
            if cells[key]:
                picked.append(cells[key].pop())
                took = True
                if len(picked) == count:
                    break
        if not took:
            break
    return picked


async def fetch_eligible(url: str) -> list[dict[str, Any]]:
    from app.db.engine import build_engine
    from quiz_shared.database.pgvector_client import questions_table as t
    from sqlalchemy import select

    engine = build_engine(url)
    stmt = select(*[t.c[c] for c in SELECT_COLUMNS]).where(
        t.c.pack_id.is_(None),
        t.c.review_status == "approved",
        t.c.language_dependent.is_(False),
    )
    try:
        async with engine.connect() as conn:
            return [dict(r._mapping) for r in (await conn.execute(stmt)).fetchall()]
    finally:
        await engine.dispose()


def to_arm_item(source: dict[str, Any], translated: dict[str, Any]) -> dict[str, Any]:
    """Translated payload + untranslated rater metadata, in build_page's shape."""
    return {
        "id": str(source["id"]),
        "question": translated.get("question"),
        "possible_answers": translated.get("possible_answers"),
        "correct_answer": translated.get("correct_answer"),
        "alternative_answers": translated.get("alternative_answers") or [],
        "explanation": translated.get("explanation"),
        "topic": source.get("topic"),
        "difficulty": source.get("difficulty"),
        "source_url": source.get("source_url"),
    }


def print_plan(sample: list[dict], arms: list[str], languages: list[str]) -> float:
    tally: dict[tuple[str, str], int] = defaultdict(int)
    for q in sample:
        tally[(q["category"], q["difficulty"])] += 1
    print(f"sample: {len(sample)} questions across {len(tally)} cells")
    for (cat, diff), n in sorted(tally.items()):
        print(f"  {cat:<16} {diff:<7} {n}")
    total = 0.0
    for arm in arms:
        cost = EST_USD_PER_REQUEST[arm] * len(sample) * len(languages)
        total += cost
        print(f"  arm {arm:<7} {len(sample) * len(languages)} requests  ~${cost:.2f}")
    print(f"estimated total ~${total:.2f} (LD0 cap ${LD0_CAP_USD:.0f})")
    return total


def run_arm(arm: str, sample: list[dict], language: str):
    spec = ARMS[arm]
    if spec.route == "deepl":
        return run_deepl_arm(sample, language)
    return run_batch_arm(spec, sample, language)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    _configure_environment()
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    unknown = [a for a in arms if a not in ARMS]
    if unknown:
        print(f"unknown arm(s): {unknown}; known: {list(ARMS)}", file=sys.stderr)
        return 1
    languages = [x.strip() for x in args.languages.split(",") if x.strip()]

    url = args.database_url or os.getenv("PROD_DATABASE_URL") or os.getenv("DATABASE_URL")
    if not url:
        print("no database URL — set PROD_DATABASE_URL or pass --database-url", file=sys.stderr)
        return 1

    rows = asyncio.run(fetch_eligible(url))
    print(f"eligible corpus: {len(rows)} questions")
    sample = sample_questions(rows, args.count, args.seed)
    if len(sample) < MIN_SAMPLE:
        print(
            f"only {len(sample)} eligible questions (need >= {MIN_SAMPLE}) — a "
            "four-arm verdict off this sample would not be trustworthy",
            file=sys.stderr,
        )
        return 1

    estimate = print_plan(sample, arms, languages)
    if not args.execute:
        print("plan only — re-run with --execute to spend (LD0)")
        return 0
    if estimate > LD0_CAP_USD:
        print(
            f"estimated ${estimate:.2f} exceeds the LD0 ${LD0_CAP_USD:.0f} cap — "
            "stop and get founder approval before running this",
            file=sys.stderr,
        )
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    spend: dict[str, Any] = {}
    failed = False
    for language in languages:
        for arm in arms:
            print(f"[{arm}/{language}] starting ({len(sample)} questions)")
            run = run_arm(arm, sample, language)
            items = [
                to_arm_item(q, run.translations[str(q["id"])])
                for q in sample
                if str(q["id"]) in run.translations
            ]
            out = args.out_dir / f"{arm}-{language}.json"
            out.write_text(
                json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            spend[f"{arm}/{language}"] = run.cost_usd
            print(f"[{arm}/{language}] wrote {out} ({len(items)} items, {run.transport})")
            if run.failures:
                failed = True
                print(f"[{arm}/{language}] {len(run.failures)} failures: {run.failures[:5]}")

    print("\ncost (USD, None = provider did not report it):")
    for key, value in spend.items():
        print(f"  {key:<14} {value}")
    if failed:
        print("some requests failed — see above", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
