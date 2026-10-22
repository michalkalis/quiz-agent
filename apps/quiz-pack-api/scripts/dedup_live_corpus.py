"""One-time cleanup of same-fact duplicates already in the live corpus (2026-10-22).

Generation dedup was blind for months (untrained ivfflat index, dropped in
PR #540), so approved questions that test the same fact slipped in side by
side. This replays what the dedup gate should have done, over the corpus as
players see it:

- **Pools** = what one player can draw: ``en`` (approved English rows), and
  per native language ``sk`` / ``cs`` (approved native rows + English rows
  served in that language, compared through their approved translation).
- **Candidates** = pairs inside a pool with question cosine ≥ 0.60 or
  question+answer cosine ≥ 0.75 — a wider net than the generation gate's
  0.70 / 0.90, affordable because this runs once and every pair is judged
  (prod 2026-10-22: ~190 pairs over ~2,300 pool entries).
- **Verdict** = every candidate, even one at cosine 0.99, goes to the same
  ``GrayZoneJudge`` "same fact?" call the generation gate uses; only YES is a
  duplicate. Cosine alone never archives anything.
- **Which one goes** = the one the gate would have refused: the later
  question, unless the founder rated it higher (rated beats unrated at the
  neutral 0.5). An English row is never archived from a native pool — it
  still serves English players — the native row goes instead.

Archiving flips ``review_status`` to ``'archived'`` (the read path serves
only ``approved``) and appends a note naming the kept twin; nothing is
deleted. ``--restore <decisions.json>`` puts every row of a run back.

Usage (from ``apps/quiz-pack-api``; ``LLM_GATEWAY=session`` keeps the judge on
the subscription)::

    python scripts/dedup_live_corpus.py --database-url "$PROD_DATABASE_URL" --out DIR
    python scripts/dedup_live_corpus.py --database-url ... --out DIR --execute
    python scripts/dedup_live_corpus.py --database-url ... --restore DIR/decisions.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from app.image_generation.env_loader import load_env

load_env()

from app.db import normalize_async_url
from app.orchestrator.stages.grayzone_judge import GrayZoneJudge
from quiz_shared.llm import factory as llm_factory
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

logger = logging.getLogger("dedup_live_corpus")

NOTE_PREFIX = "archived 2026-10-22 corpus dedup: same fact as"
NATIVE_LANGUAGES = ("sk", "cs")
NEUTRAL_RATING = 0.5
JUDGE_CONCURRENCY = 6
CANDIDATE_Q_FLOOR = 0.60
CANDIDATE_QA_FLOOR = 0.75


@dataclass
class Item:
    """One question as a player in this pool would read it."""

    id: str
    language: str  # the row's own language: "en" for translated English rows
    question: str
    answer: str
    created_at: datetime
    rating: float | None
    emb: np.ndarray
    emb_qa: np.ndarray | None = None
    extra: dict[str, Any] = field(default_factory=dict)


def _unit(rows: list[np.ndarray]) -> np.ndarray:
    m = np.vstack(rows).astype(np.float64)
    return m / np.linalg.norm(m, axis=1, keepdims=True)


def candidate_pairs(
    items: list[Item], skip_en_en: bool
) -> list[tuple[int, int, float, float | None]]:
    """Index pairs worth a verdict: question cosine ≥ ``CANDIDATE_Q_FLOOR``
    or QA cosine ≥ ``CANDIDATE_QA_FLOOR``. ``skip_en_en`` in native pools, where two
    English rows were already judged in the ``en`` pool."""
    sim = _unit([it.emb for it in items]) @ _unit([it.emb for it in items]).T
    qa = None
    if all(it.emb_qa is not None for it in items):
        u = _unit([it.emb_qa for it in items])
        qa = u @ u.T
    out = []
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            if skip_en_en and items[i].language == items[j].language == "en":
                continue
            q_s = float(sim[i, j])
            qa_s = float(qa[i, j]) if qa is not None else None
            if q_s >= CANDIDATE_Q_FLOOR or (
                qa_s is not None and qa_s >= CANDIDATE_QA_FLOOR
            ):
                out.append((i, j, q_s, qa_s))
    return out


def keep_order(item: Item, native_pool: bool) -> tuple:
    """Lower sorts first = kept first. English rows lead a native pool (never
    archived there); then the founder's rating; then the earlier question,
    which is the one the dedup gate would have let in."""
    rating = item.rating if item.rating is not None else NEUTRAL_RATING
    english_first = 0 if (native_pool and item.language == "en") else 1
    return (english_first, -rating, item.created_at, item.id)


def choose_archive(
    items: list[Item], dup_edges: set[tuple[str, str]], native_pool: bool
) -> dict[str, str]:
    """Greedy keep-set: walk in keep order, archive an item only when it is a
    judged duplicate of an item already KEPT. Never chains A→B→C, so every
    archived question has a live twin that tests its fact.
    Returns {archived id: kept twin id}."""
    linked: dict[str, set[str]] = {}
    for a, b in dup_edges:
        linked.setdefault(a, set()).add(b)
        linked.setdefault(b, set()).add(a)
    kept: list[str] = []
    archived: dict[str, str] = {}
    for it in sorted(items, key=lambda x: keep_order(x, native_pool)):
        twin = next((k for k in kept if k in linked.get(it.id, ())), None)
        if twin is None or (native_pool and it.language == "en"):
            kept.append(it.id)
        else:
            archived[it.id] = twin
    return archived


def _answer(correct: Any, options: Any) -> str:
    if isinstance(options, dict) and isinstance(correct, str):
        return str(options.get(correct, correct))
    return str(correct)


def _vec(raw: Any) -> np.ndarray | None:
    if raw is None:
        return None
    return np.asarray(
        json.loads(raw) if isinstance(raw, str) else raw, dtype=np.float64
    )


async def load_pools(conn, cache: Path) -> dict[str, list[Item]]:
    ratings = {
        r.qid: float(r.mean)
        for r in await conn.execute(
            text(
                "SELECT question_id::text AS qid, "
                "avg((score - scale_min)::float / NULLIF(scale_max - scale_min, 0)) AS mean "
                "FROM ratings WHERE question_id IS NOT NULL GROUP BY 1"
            )
        )
    }
    rows = (
        await conn.execute(
            text(
                "SELECT id::text AS id, COALESCE(language, 'en') AS language, question, "
                "correct_answer, possible_answers, created_at, approved_languages, "
                "embedding::text AS emb, embedding_qa::text AS emb_qa FROM questions "
                "WHERE review_status = 'approved' AND pack_id IS NULL"
            )
        )
    ).all()
    pools: dict[str, list[Item]] = {"en": [], **{lang: [] for lang in NATIVE_LANGUAGES}}
    for r in rows:
        it = Item(
            r.id,
            r.language,
            r.question,
            _answer(r.correct_answer, r.possible_answers),
            r.created_at,
            ratings.get(r.id),
            _vec(r.emb),
            _vec(r.emb_qa),
            {"approved_languages": list(r.approved_languages or [])},
        )
        pools.setdefault(r.language, []).append(it)
    unknown = set(pools) - {"en", *NATIVE_LANGUAGES}
    if unknown:
        raise SystemExit(
            f"approved rows in unhandled languages {sorted(unknown)} — refusing"
        )

    # English rows as a native player reads them: their approved translation.
    embed_cache = json.loads(cache.read_text()) if cache.exists() else {}
    for lang in NATIVE_LANGUAGES:
        tr = (
            await conn.execute(
                text(
                    "SELECT question_id::text AS qid, question, correct_answer, possible_answers "
                    "FROM question_translations WHERE language = :l AND status = 'approved'"
                ),
                {"l": lang},
            )
        ).all()
        translated = {t.qid: t for t in tr}
        for en in pools["en"]:
            if lang not in en.extra["approved_languages"]:
                continue
            t = translated.get(en.id)
            if t is None:
                raise SystemExit(
                    f"{en.id} is served in {lang} without an approved translation"
                )
            pools[lang].append(
                Item(
                    en.id,
                    "en",
                    t.question,
                    _answer(t.correct_answer, t.possible_answers),
                    en.created_at,
                    en.rating,
                    np.zeros(1),
                )
            )
        missing = [
            it.question
            for it in pools[lang]
            if it.language == "en" and it.question not in embed_cache
        ]
        client = llm_factory.openai_client(async_=True)
        for k in range(0, len(missing), 100):
            chunk = missing[k : k + 100]
            resp = await client.embeddings.create(
                model=llm_factory.resolve_model(llm_factory.EMBED), input=chunk
            )
            embed_cache.update({q: d.embedding for q, d in zip(chunk, resp.data)})
        cache.write_text(json.dumps(embed_cache))
        # Translations carry no QA vector, so a native pool is compared on
        # question cosine only (`candidate_pairs` skips QA when one is missing).
        for it in pools[lang]:
            if it.language == "en":
                it.emb = np.asarray(embed_cache[it.question], dtype=np.float64)
    return pools


async def judge_pairs(pairs, verdict_cache: Path) -> dict[str, bool | None]:
    """{"idA|idB": True/False/None}; resumable through ``verdict_cache``."""
    done: dict[str, bool | None] = (
        json.loads(verdict_cache.read_text()) if verdict_cache.exists() else {}
    )
    judge = GrayZoneJudge(max_calls=10**6)
    sem = asyncio.Semaphore(JUDGE_CONCURRENCY)

    async def one(a: Item, b: Item, score: float) -> None:
        key = "|".join(sorted((a.id, b.id)))
        if key in done and done[key] is not None:
            return
        ns = lambda it: SimpleNamespace(
            id=it.id,
            question=it.question,
            correct_answer=it.answer,
            possible_answers=None,
        )
        async with sem:
            try:
                done[key] = await judge.same_fact(ns(a), ns(b), score)
            except Exception:
                logger.warning("judge failed for %s", key, exc_info=True)
                done[key] = None
        if len(done) % 25 == 0:
            verdict_cache.write_text(json.dumps(done))

    await asyncio.gather(*(one(a, b, s) for a, b, s in pairs))
    verdict_cache.write_text(json.dumps(done))
    return done


async def run(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    engine = create_async_engine(normalize_async_url(args.database_url))
    try:
        if args.restore:
            ids = list(json.loads(Path(args.restore).read_text())["archived"])
            async with engine.begin() as conn:
                res = await conn.execute(
                    text(
                        "UPDATE questions SET review_status = 'approved' "
                        "WHERE id::text = ANY(:ids) AND review_status = 'archived'"
                    ),
                    {"ids": ids},
                )
            print(f"Restored {res.rowcount}/{len(ids)}")
            return 0

        async with engine.connect() as conn:
            pools = await load_pools(conn, out / "translation_embeddings.json")
        all_pairs, decisions = [], {}
        for name, items in pools.items():
            native = name != "en"
            pairs = candidate_pairs(items, skip_en_en=native)
            print(f"pool {name}: {len(items)} questions, {len(pairs)} candidate pairs")
            all_pairs.append((name, items, pairs))
        verdicts = await judge_pairs(
            [(it[i], it[j], s) for _, it, ps in all_pairs for i, j, s, _ in ps],
            out / "verdicts.json",
        )
        unjudged = sum(v is None for v in verdicts.values())
        archived: dict[str, dict[str, Any]] = {}
        for name, items, pairs in all_pairs:
            # English rows archived in the en pool are gone from every pool.
            live = [it for it in items if it.id not in archived]
            edges = set()
            for i, j, _, _ in pairs:
                if verdicts.get("|".join(sorted((items[i].id, items[j].id)))):
                    edges.add((items[i].id, items[j].id))
            by_id = {it.id: it for it in items}
            for gone, twin in choose_archive(
                live, edges, native_pool=name != "en"
            ).items():
                archived[gone] = {
                    "pool": name,
                    "twin": twin,
                    "question": by_id[gone].question,
                    "twin_question": by_id[twin].question,
                }
            decisions[name] = {
                "questions": len(items),
                "candidates": len(pairs),
                "same_fact": len(edges),
            }
        report = {
            "run_at": datetime.now(UTC).isoformat(),
            "pools": decisions,
            "unjudged": unjudged,
            "archived": archived,
        }
        (out / "decisions.json").write_text(
            json.dumps(report, indent=1, ensure_ascii=False)
        )
        print(
            json.dumps(decisions), f"unjudged={unjudged}", f"to archive={len(archived)}"
        )
        if unjudged:
            print("Some pairs have no verdict — rerun to retry them before --execute.")
            return 1
        if not args.execute:
            return 0
        async with engine.begin() as conn:
            n = 0
            for gone, info in archived.items():
                res = await conn.execute(
                    text(
                        "UPDATE questions SET review_status = 'archived', reviewed_at = now(), "
                        "review_notes = concat_ws(' | ', review_notes, :note) "
                        "WHERE id::text = :id AND review_status = 'approved'"
                    ),
                    {"id": gone, "note": f"{NOTE_PREFIX} {info['twin']}"},
                )
                n += res.rowcount
        print(f"Archived {n}/{len(archived)}")
        return 0
    finally:
        await engine.dispose()


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--database-url", required=True)
    p.add_argument("--out", required=True, help="Directory for caches + decisions.json")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--execute", action="store_true", help="Archive (default: dry run)"
    )
    mode.add_argument("--restore", help="decisions.json of a run to put back")
    return asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
