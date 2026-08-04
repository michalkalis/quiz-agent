"""Gate-v2 calibration validation (#135 D7 — the founder's flip condition).

Runs BOTH scoring gates over the founder-rated calibration set and reports how
each correlates with the founder's ratings:

- v1: 2 judges × 7 dimensions × 1 call each (the current default)
- v2: 3 judges × 1 panel call each, 5 dimensions, reasoning-first (GATE_V2)
- v2c (``--arms``): the T6-fallback middle ground — 5 dimensions in 2 cluster
  calls per judge (fun + craft, GATE_V2_CLUSTERED)

``JUDGE_MODELS`` (env) swaps the judge panel for every arm — e.g. the Bedrock
panel (founder directive 2026-08-04): pass ``bedrock:``-prefixed ids and set
``SCORER_MAX_CONCURRENT=3`` (Bedrock on-demand throttling, field test
2026-08-01).

The calibration set is built by joining ``data/pilot-2026-07-11/pilot_review.md``
(numbered question texts) with ``founder_ratings.md`` (blind 1-5 ratings,
27 items across two rounds). The founder's earlier 36-question session
(2026-07-09) survives only as a synthesis doc — its raw per-question log lived
in that session's scratchpad and is not in the repo — so this 27-item set is
the machine-readable calibration ground truth available.

Usage (from apps/quiz-pack-api/, feedback_qgen_import_cwd):

    LLM_GATEWAY=openrouter uv run --no-sync python scripts/validate_gate_v2.py

Writes the full per-question results next to the calibration data
(``data/pilot-2026-07-11/gate_v2_validation.json``) and prints a summary.
The GATE_V2 default is flipped manually after founder review — this script
only measures.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.scoring.multi_model_scorer import MultiModelScorer  # noqa: E402

DATA_DIR = Path(__file__).resolve().parents[1] / "data" / "pilot-2026-07-11"

_QUESTION_RE = re.compile(
    r"^\*\*(?P<id>[ABC]\d+)\.\s*\[(?P<type>[a-z_]+)\]\*\*\s*(?P<question>.+)$"
)
_OPTIONS_RE = re.compile(r"^\s*-\s*Options:\s*(?P<options>.+)$")
_ANSWER_RE = re.compile(r"^\s*-\s*Answer:\s*\*\*(?P<answer>.+?)\*\*\s*$")
_RATING_ROW_RE = re.compile(
    r"^\|\s*[^|]+\|\s*(?P<orig>[ABC]\d+)\s*\|\s*[ABC]\s*\|\s*(?P<rating>\d+(?:\.\d+)?)\s*\|"
)
_OPTION_KEY_RE = re.compile(r"^([a-z])\)\s*(.+)$")


def _parse_pilot_review(path: Path) -> dict[str, dict]:
    """{orig_id: {question, possible_answers, correct_answer}}."""
    items: dict[str, dict] = {}
    current: dict | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        m = _QUESTION_RE.match(line.strip())
        if m:
            current = {
                "orig_id": m.group("id"),
                "question": m.group("question").strip(),
                "possible_answers": None,
                "correct_answer": None,
            }
            items[m.group("id")] = current
            continue
        if current is None:
            continue
        m = _OPTIONS_RE.match(line)
        if m:
            options: dict[str, str] = {}
            for part in m.group("options").split("·"):
                om = _OPTION_KEY_RE.match(part.strip())
                if om:
                    options[om.group(1)] = om.group(2).strip()
            current["possible_answers"] = options or None
            continue
        m = _ANSWER_RE.match(line)
        if m:
            answer = m.group("answer").strip()
            # MCQ answers render as "b) International Space Station" — store
            # the option text (the post-pilot storage convention).
            om = _OPTION_KEY_RE.match(answer)
            current["correct_answer"] = om.group(2).strip() if om else answer
    return items


def _parse_founder_ratings(path: Path) -> dict[str, float]:
    """{orig_id: rating 1-5} from both rating-round tables."""
    ratings: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = _RATING_ROW_RE.match(line.strip())
        if m:
            ratings[m.group("orig")] = float(m.group("rating"))
    return ratings


def build_calibration_set() -> list[dict]:
    questions = _parse_pilot_review(DATA_DIR / "pilot_review.md")
    ratings = _parse_founder_ratings(DATA_DIR / "founder_ratings.md")
    missing = sorted(set(ratings) - set(questions))
    if missing:
        raise SystemExit(f"rated ids missing from pilot_review.md: {missing}")
    items = []
    for orig_id, rating in sorted(ratings.items()):
        q = questions[orig_id]
        if not q["correct_answer"]:
            raise SystemExit(f"{orig_id}: no answer parsed")
        items.append(
            {
                "id": orig_id,
                "question": q["question"],
                "correct_answer": q["correct_answer"],
                "possible_answers": q["possible_answers"],
                "difficulty": "medium",
                "topic": "General",
                "founder_rating": rating,
            }
        )
    return items


def _pearson(xs: list[float], ys: list[float]) -> float:
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = sum((x - mx) ** 2 for x in xs) ** 0.5
    vy = sum((y - my) ** 2 for y in ys) ** 0.5
    if vx == 0 or vy == 0:
        return float("nan")
    return cov / (vx * vy)


def _ranks(vals: list[float]) -> list[float]:
    """Average ranks (ties share the mean rank)."""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    ranks = [0.0] * len(vals)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and vals[order[j + 1]] == vals[order[i]]:
            j += 1
        mean_rank = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = mean_rank
        i = j + 1
    return ranks


def _spearman(xs: list[float], ys: list[float]) -> float:
    return _pearson(_ranks(xs), _ranks(ys))


def _mean_overall(model_scores: list[dict]) -> float | None:
    overalls = [
        float(s["overall_score"])
        for s in model_scores
        if s.get("overall_score") is not None
        and s.get("model_name") != "deterministic"
    ]
    return sum(overalls) / len(overalls) if overalls else None


# Arm label → MultiModelScorer kwargs. Explicit kwargs so an env flag flip
# can never silently change which gate an arm measures.
ARMS = {
    "v1": {"gate_v2": False},
    "v2": {"gate_v2": True, "gate_v2_clustered": False},
    "v2c": {"gate_v2": True, "gate_v2_clustered": True},
}


async def _run(out_path: Path, arms: list[str]) -> None:
    if not os.getenv("OPENROUTER_API_KEY") and os.getenv("LLM_GATEWAY") == "openrouter":
        raise SystemExit("OPENROUTER_API_KEY is not set")

    items = build_calibration_set()
    print(f"calibration set: {len(items)} founder-rated questions")

    results: dict[str, dict] = {
        "items": {i["id"]: {"founder": i["founder_rating"]} for i in items},
        "judges": {},
    }
    for label in arms:
        scorer = MultiModelScorer(**ARMS[label])
        if not scorer.models:
            raise SystemExit(f"{label}: no judges available (check API keys/gateway)")
        results["judges"][label] = [m["name"] for m in scorer.models]
        print(f"{label}: judges = {results['judges'][label]}")
        batch = await scorer.score_batch([dict(i) for i in items])
        for r in batch:
            entry = results["items"][r["id"]]
            entry[label] = _mean_overall(r["model_scores"])
            entry[f"{label}_judges"] = {
                s["model_name"]: s["overall_score"]
                for s in r["model_scores"]
                if s.get("model_name") != "deterministic"
            }

    founder: list[float] = []
    arm_scores: dict[str, list[float]] = {label: [] for label in arms}
    for i in items:
        entry = results["items"][i["id"]]
        if any(entry.get(label) is None for label in arms):
            print(f"  ! {i['id']}: unscored by at least one gate — excluded")
            continue
        founder.append(entry["founder"])
        for label in arms:
            arm_scores[label].append(entry[label])

    summary: dict = {"n": len(founder)}
    for label in arms:
        summary[f"{label}_vs_founder"] = {
            "pearson": round(_pearson(arm_scores[label], founder), 3),
            "spearman": round(_spearman(arm_scores[label], founder), 3),
        }
    for a_idx, a in enumerate(arms):
        for b in arms[a_idx + 1:]:
            summary[f"{a}_vs_{b}_spearman"] = round(
                _spearman(arm_scores[a], arm_scores[b]), 3
            )
    results["summary"] = summary
    out_path.write_text(json.dumps(results, indent=2), encoding="utf-8")

    print(json.dumps(summary, indent=2))
    print(f"full results: {out_path}")
    if "v1" in arms:
        # Pre-registered flip rule (#135 T6): a challenger arm passes only if
        # its founder correlation is not meaningfully below v1's.
        v1_s = summary["v1_vs_founder"]["spearman"]
        for label in arms:
            if label == "v1":
                continue
            arm_s = summary[f"{label}_vs_founder"]["spearman"]
            verdict = (
                f"PASS ({label} >= v1 - 0.05)"
                if arm_s >= v1_s - 0.05
                else f"FAIL — keep {label} off"
            )
            print(f"advisory verdict [{label}]: {verdict}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=DATA_DIR / "gate_v2_validation.json",
        help="where to write per-question results",
    )
    parser.add_argument(
        "--arms",
        default="v1,v2",
        help=f"comma-separated arms to run, from {sorted(ARMS)} (default: v1,v2)",
    )
    args = parser.parse_args()
    arms = [a.strip() for a in args.arms.split(",") if a.strip()]
    unknown = sorted(set(arms) - set(ARMS))
    if unknown or not arms:
        raise SystemExit(f"unknown arms {unknown}; choose from {sorted(ARMS)}")
    asyncio.run(_run(args.out, arms))


if __name__ == "__main__":
    main()
