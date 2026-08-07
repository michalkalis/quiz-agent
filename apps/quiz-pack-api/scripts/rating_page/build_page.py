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
"""

import argparse
import json
import random
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent / "template.html"


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


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arm", action="append", required=True, metavar="NAME=FILE",
                    help="arm name and its questions JSON (repeatable)")
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--title", default="Hodnotenie otázok")
    ap.add_argument("--batch-id", required=True,
                    help="unique id; also namespaces localStorage so old ratings don't collide")
    ap.add_argument("--seed", type=int, required=True, help="shuffle seed (reproducible blinding)")
    ap.add_argument("--dedupe-by-fact", action="store_true",
                    help="show each source fact only once: when several arms built a "
                         "question on the same fact (same source_url), keep one arm's "
                         "version, chosen seeded + balanced across arms. Round-1 lesson: "
                         "the founder rates repeats 1-3, which punishes whichever arm "
                         "the shuffle puts later.")
    args = ap.parse_args()

    pool: list[tuple[str, dict]] = []
    for spec in args.arm:
        name, _, file = spec.partition("=")
        if not file:
            raise SystemExit(f"--arm expects NAME=FILE, got: {spec}")
        for q in load_arm(Path(file)):
            pool.append((name, q))

    if args.dedupe_by_fact:
        rng = random.Random(args.seed)
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
        pool = deduped
        print(f"dedupe-by-fact: kept {len(pool)}, dropped {dropped} same-fact "
              f"duplicates; per arm kept: {dict(sorted(arm_kept.items()))}")

    random.Random(args.seed).shuffle(pool)

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
