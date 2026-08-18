"""D21b pre-publication dedupe — answer-first, embeddings as the second sieve.

Founder call (in-session 2026-08-18): duplicates are compared primarily by
ANSWER, not question wording — the same fact retold differently shares its
answer, however the stem is phrased. Two rules, applied globally across arms:

  1. answer rule — a later question whose normalised answer (incl.
     alternative_answers) already appeared is a duplicate. True/false, yes/no
     and purely numeric answers are exempt (legitimately repeatable) and fall
     through to rule 2.
  2. embedding rule — cosine similarity of "question + answer" embeddings
     >= --sim-threshold (default 0.88, same text-embedding-3-small the app
     uses) marks near-identical facts even when answers differ.

Reads `<arm>.json` produced by run_d21b_arms.py, keeps the first `--keep`
questions per arm that survive both rules, writes `<arm>.dedup.json` (input
to publish_batch.py) plus `dedupe_report.json` (every drop with its reason).
Fails loudly when an arm's pool can't fill its publish target.

    uv run --no-sync python scripts/dedupe_d21b.py \
        --keep f-base=120 --keep e-news-f=20 --keep e-news-k=10

Embeddings are cached in `<run-dir>/dedupe_embeddings.json` (keyed by
question id) so reruns are free.
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

DEFAULT_RUN_DIR = (
    Path(__file__).resolve().parents[3] / "docs" / "testing" / "runs"
    / "d21b-round-2026-08-18"
)

_ARTICLES = ("the ", "a ", "an ")
_EXEMPT = {"true", "false", "yes", "no"}


def _norm(answer: str) -> str:
    text = re.sub(r"[^\w\s]", "", answer.lower()).strip()
    for art in _ARTICLES:
        text = text.removeprefix(art)
    return re.sub(r"\s+", " ", text).strip()


def _answer_keys(q: dict) -> set[str]:
    answers = [q.get("correct_answer") or ""] + list(q.get("alternative_answers") or [])
    keys = set()
    for a in answers:
        n = _norm(a)
        if n and n not in _EXEMPT and not re.fullmatch(r"[\d\s.,]+", n):
            keys.add(n)
    return keys


def _load_embeddings(cache_path: Path) -> dict:
    if cache_path.exists():
        return json.loads(cache_path.read_text())
    return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", default=str(DEFAULT_RUN_DIR))
    ap.add_argument(
        "--keep", action="append", required=True, metavar="ARM=N",
        help="publish target per arm (repeatable), e.g. f-base=120",
    )
    ap.add_argument("--sim-threshold", type=float, default=0.88)
    args = ap.parse_args()

    from quiz_shared.utils.embeddings import calculate_similarity, generate_embedding

    run_dir = Path(args.run_dir)
    targets = {}
    for spec in args.keep:
        arm, _, n = spec.partition("=")
        targets[arm] = int(n)

    pools = {
        arm: json.loads((run_dir / f"{arm}.json").read_text()) for arm in targets
    }

    cache_path = run_dir / "dedupe_embeddings.json"
    cache = _load_embeddings(cache_path)

    def _embedding(q: dict) -> list[float]:
        qid = q["id"]
        if qid not in cache:
            cache[qid] = generate_embedding(
                f"{q['question']} Answer: {q.get('correct_answer') or ''}"
            )
        return cache[qid]

    kept: dict[str, list[dict]] = {arm: [] for arm in targets}
    kept_flat: list[tuple[str, dict, set[str], list[float]]] = []
    seen_answers: set[str] = set()
    report = []

    # Arms in CLI order; within an arm, generation order — earlier wins.
    for arm, pool in pools.items():
        for q in pool:
            if len(kept[arm]) >= targets[arm]:
                break
            keys = _answer_keys(q)
            hit = keys & seen_answers
            if hit:
                report.append({
                    "arm": arm, "id": q["id"], "rule": "answer",
                    "question": q["question"], "matched": sorted(hit),
                })
                continue
            emb = _embedding(q)
            dup_of = next(
                (
                    (o_arm, o["id"], round(sim, 3))
                    for o_arm, o, _, o_emb in kept_flat
                    if (sim := calculate_similarity(emb, o_emb)) >= args.sim_threshold
                ),
                None,
            )
            if dup_of:
                report.append({
                    "arm": arm, "id": q["id"], "rule": "embedding",
                    "question": q["question"],
                    "duplicate_of": {"arm": dup_of[0], "id": dup_of[1], "sim": dup_of[2]},
                })
                continue
            kept[arm].append(q)
            kept_flat.append((arm, q, keys, emb))
            seen_answers |= keys

    cache_path.write_text(json.dumps(cache) + "\n")

    short = {a: (targets[a], len(kept[a])) for a in targets if len(kept[a]) < targets[a]}
    for arm, qs in kept.items():
        (run_dir / f"{arm}.dedup.json").write_text(
            json.dumps(qs, ensure_ascii=False, indent=2) + "\n"
        )
    (run_dir / "dedupe_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    )

    for arm, want in targets.items():
        print(f"{arm}: kept {len(kept[arm])}/{want} (pool {len(pools[arm])})")
    print(f"dropped {len(report)} duplicates — see dedupe_report.json")
    if short:
        raise SystemExit(
            f"POOL EXHAUSTED, refusing to under-publish: {short} — "
            "generate more raw questions for these arms and rerun"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
