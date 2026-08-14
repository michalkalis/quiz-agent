#!/usr/bin/env python3
"""Build a blind rating page from one or more experiment arms.

Usage:
    python build_page.py --arm old=runs/153-phase-a/old_prompt.json \
                         --arm new=runs/153-phase-a/new_prompt.json \
                         --out-dir docs/testing/runs/153-phase-a \
                         --title "Hodnotenie otázok — kolo 1" \
                         --batch-id 153-phase-a --seed 153

Each arm file is a JSON list of question dicts (dry-run pipeline output).
Questions from all arms are interleaved with a seeded shuffle and re-keyed
to blinded ids (q01, q02, …). The page (`rating.html`) contains NO arm
information; `mapping.json` (blinded id -> arm + original id) is written
next to it and must never be sent to the rater alongside the page.

Founder exports ratings as JSON keyed by blinded id; join with mapping.json
for analysis.

This static mode is the offline fallback. The server-backed multi-rater flow
is `publish_batch.py`, which imports the selection/blinding functions below so
both modes blind identically — a second copy of this logic would eventually
drift and make two rounds incomparable.
"""

import argparse
import json
import random
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent / "template.html"


def add_selection_args(ap: argparse.ArgumentParser) -> None:
    """The arm/seed/dedupe flags shared with `publish_batch.py`."""
    ap.add_argument("--arm", action="append", required=True, metavar="NAME=FILE",
                    help="arm name and its questions JSON (repeatable)")
    ap.add_argument("--seed", type=int, required=True,
                    help="shuffle seed (reproducible blinding)")
    ap.add_argument("--dedupe-by-fact", action="store_true",
                    help="show each source fact only once: when several arms built a "
                         "question on the same fact (same source_url), keep one arm's "
                         "version, chosen seeded + balanced across arms. Round-1 lesson: "
                         "the founder rates repeats 1-3, which punishes whichever arm "
                         "the shuffle puts later.")


def load_arm(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "questions" in data:
        data = data["questions"]
    if not isinstance(data, list):
        raise SystemExit(f"{path}: expected a JSON list of questions")
    return data


def blind_question(q: dict, blinded_id: str) -> dict:
    return {
        "id": blinded_id,
        "question": q.get("question"),
        "options": q.get("possible_answers") or None,
        "correct_answer": q.get("correct_answer"),
        "alternative_answers": q.get("alternative_answers") or [],
        "explanation": q.get("explanation"),
        "topic": q.get("topic"),
        "difficulty": q.get("difficulty"),
        "source_url": q.get("source_url"),
    }


def build_pool(arm_specs: list[str]) -> list[tuple[str, dict]]:
    """Load every `NAME=FILE` arm into one (arm, question) pool."""
    pool: list[tuple[str, dict]] = []
    for spec in arm_specs:
        name, _, file = spec.partition("=")
        if not file:
            raise SystemExit(f"--arm expects NAME=FILE, got: {spec}")
        for q in load_arm(Path(file)):
            pool.append((name, q))
    return pool


def dedupe_by_fact(pool: list[tuple[str, dict]], seed: int) -> list[tuple[str, dict]]:
    """Keep one arm's version of each source fact, seeded and arm-balanced."""
    rng = random.Random(seed)
    by_fact: dict[str, list[tuple[str, dict]]] = {}
    for i, (name, q) in enumerate(pool):
        key = q.get("source_url") or f"__unsourced_{i}"
        by_fact.setdefault(key, []).append((name, q))
    arm_kept: dict[str, int] = {}
    deduped: list[tuple[str, dict]] = []
    dropped = 0
    for items in by_fact.values():
        if len(items) == 1:
            chosen = items[0]
        else:
            low = min(arm_kept.get(n, 0) for n, _ in items)
            chosen = rng.choice(
                [it for it in items if arm_kept.get(it[0], 0) == low]
            )
            dropped += len(items) - 1
        arm_kept[chosen[0]] = arm_kept.get(chosen[0], 0) + 1
        deduped.append(chosen)
    print(f"dedupe-by-fact: kept {len(deduped)}, dropped {dropped} same-fact "
          f"duplicates; per arm kept: {dict(sorted(arm_kept.items()))}")
    return deduped


def interleave(pool: list[tuple[str, dict]], seed: int) -> list[tuple[str, dict]]:
    """Seeded shuffle so arms are interleaved reproducibly."""
    shuffled = list(pool)
    random.Random(seed).shuffle(shuffled)
    return shuffled


def blind_pool(pool: list[tuple[str, dict]]) -> tuple[list[dict], dict]:
    """Re-key the pool to q01, q02, … returning (blinded questions, mapping)."""
    questions, mapping = [], {}
    for i, (arm, q) in enumerate(pool, 1):
        bid = f"q{i:02d}"
        questions.append(blind_question(q, bid))
        mapping[bid] = {
            "arm": arm,
            "original_id": q.get("id"),
            "topic": q.get("topic"),
            "question": q.get("question"),
        }
    return questions, mapping


def select_and_blind(
    arm_specs: list[str], seed: int, dedupe: bool
) -> tuple[list[dict], dict]:
    """Whole selection pipeline: load arms → optional dedupe → shuffle → blind."""
    pool = build_pool(arm_specs)
    if dedupe:
        pool = dedupe_by_fact(pool, seed)
    return blind_pool(interleave(pool, seed))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    add_selection_args(ap)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--title", default="Hodnotenie otázok")
    ap.add_argument("--batch-id", required=True,
                    help="unique id; also namespaces localStorage so old ratings don't collide")
    args = ap.parse_args()

    questions, mapping = select_and_blind(args.arm, args.seed, args.dedupe_by_fact)

    meta = {"title": args.title, "batch_id": args.batch_id, "count": len(questions)}

    html = TEMPLATE.read_text(encoding="utf-8")
    html = html.replace("__TITLE__", args.title)
    html = html.replace("__META__", json.dumps(meta, ensure_ascii=False).replace("</", "<\\/"))
    html = html.replace("__DATA__", json.dumps(questions, ensure_ascii=False).replace("</", "<\\/"))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    page = args.out_dir / "rating.html"
    page.write_text(html, encoding="utf-8")
    (args.out_dir / "mapping.json").write_text(
        json.dumps(mapping, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"wrote {page} ({len(questions)} questions, {len(args.arm)} arms) + mapping.json")
    print("mapping.json stays in the run dir — never send it with the page.")


if __name__ == "__main__":
    main()
