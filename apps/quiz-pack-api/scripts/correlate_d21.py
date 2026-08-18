"""D21 correlations — join human ratings with replayed layer verdicts.

One command, after the batch is rated and replay_d21_layers.py has run:

    uv run --no-sync python scripts/correlate_d21.py \
        --ratings ratings_export.jsonl --batch-id <uuid> [--rater michal ...]

Inputs: replay_results.json + mapping.json (both in --run-dir; mapping saved
by publish_batch.py --save-mapping) + the JSONL from export_ratings.py.
Output: per-arm human means (the axis verdicts) and per-layer correlation
with human scores (which pipeline layers deserve to stay — D21), printed and
written to `<run-dir>/correlations.json`.
"""

import argparse
import json
import sys
from pathlib import Path

DEFAULT_RUN_DIR = (
    Path(__file__).resolve().parents[3] / "docs" / "testing" / "runs"
    / "d21-round-2026-08-15"
)


def _ranks(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def _pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    vx = sum((x - mx) ** 2 for x in xs) ** 0.5
    vy = sum((y - my) ** 2 for y in ys) ** 0.5
    if vx == 0 or vy == 0:
        return None
    return cov / (vx * vy)


def _spearman(xs, ys):
    if len(xs) < 3:
        return None
    return _pearson(_ranks(xs), _ranks(ys))


def _judge_scores(judges_payload):
    """Mean overall score across the panel's judges, tolerant of shape."""
    if not isinstance(judges_payload, list):
        return {}
    per_judge = {}
    for j in judges_payload:
        if not isinstance(j, dict):
            continue
        name = j.get("model") or j.get("judge") or j.get("name") or "judge"
        score = j.get("overall_score") or j.get("overall") or j.get("score")
        if score is None and isinstance(j.get("scores"), dict) and j["scores"]:
            vals = [v for v in j["scores"].values() if isinstance(v, (int, float))]
            score = sum(vals) / len(vals) if vals else None
        if isinstance(score, (int, float)):
            per_judge[name] = float(score)
    return per_judge


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", default=str(DEFAULT_RUN_DIR))
    ap.add_argument("--ratings", required=True, help="JSONL from export_ratings.py")
    ap.add_argument("--batch-id", required=True)
    ap.add_argument(
        "--rater", action="append", default=None,
        help="only these raters (repeatable); default = all, averaged per question",
    )
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    replay = json.loads((run_dir / "replay_results.json").read_text())
    mapping = json.loads((run_dir / "mapping.json").read_text())

    # qid -> mean human score (normalized to /10 when the export provides it)
    per_q: dict[str, list[float]] = {}
    raters_seen = set()
    with open(args.ratings, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if str(row.get("batch_id")) != args.batch_id:
                continue
            if args.rater and row.get("rater") not in args.rater:
                continue
            score = row.get("score_normalized_10", row.get("score"))
            if score is None:
                continue
            raters_seen.add(row.get("rater"))
            qid = row.get("blinded_qid") or row.get("qid")
            if qid is None:
                continue
            per_q.setdefault(qid, []).append(float(score))
    human = {qid: sum(v) / len(v) for qid, v in per_q.items()}
    if not human:
        raise SystemExit("no ratings matched the batch/rater filter — check inputs")

    # join: blinded qid -> original question id -> replay entry
    rows = []
    missing = 0
    for qid, score in human.items():
        m = mapping.get(qid)
        entry = replay.get(m["original_id"]) if m else None
        if entry is None:
            missing += 1
            continue
        rows.append({"qid": qid, "human": score, "arm": m["arm"], **entry})
    if missing:
        print(f"WARNING: {missing} rated questions missing from replay results")

    report = {
        "batch_id": args.batch_id,
        "raters": sorted(r for r in raters_seen if r),
        "n": len(rows),
        "per_arm_human_mean": {},
        "layers": {},
    }

    by_arm: dict[str, list[float]] = {}
    for r in rows:
        by_arm.setdefault(r["arm"], []).append(r["human"])
    report["per_arm_human_mean"] = {
        arm: {"mean": round(sum(v) / len(v), 2), "n": len(v)}
        for arm, v in sorted(by_arm.items(), key=lambda kv: -sum(kv[1]) / len(kv[1]))
    }

    def _corr(pairs, label):
        xs, ys = [x for x, _ in pairs], [y for _, y in pairs]
        report["layers"][label] = {
            "n": len(pairs),
            "spearman": round(s, 3) if (s := _spearman(xs, ys)) is not None else None,
            "pearson": round(p, 3) if (p := _pearson(xs, ys)) is not None else None,
        }

    # critique overall score
    pairs = [
        (r["critique"]["overall_score"], r["human"])
        for r in rows
        if isinstance(r.get("critique"), dict)
        and isinstance(r["critique"].get("overall_score"), (int, float))
    ]
    if pairs:
        _corr(pairs, "critique")

    # duels: win-rate only ranks within one arm — average per-arm Spearman
    arm_corrs = []
    for arm in by_arm:
        p = [
            (r["duels"]["win_rate"], r["human"])
            for r in rows
            if r["arm"] == arm
            and isinstance(r.get("duels"), dict)
            and isinstance(r["duels"].get("win_rate"), (int, float))
        ]
        if len(p) >= 4:
            s = _spearman([x for x, _ in p], [y for _, y in p])
            if s is not None:
                arm_corrs.append(s)
    if arm_corrs:
        report["layers"]["duels"] = {
            "arms": len(arm_corrs),
            "mean_within_arm_spearman": round(sum(arm_corrs) / len(arm_corrs), 3),
        }

    # answerability: binary → mean human score per outcome + point-biserial
    ans = [
        (1.0 if r["answerability"]["passed"] else 0.0, r["human"])
        for r in rows
        if isinstance(r.get("answerability"), dict)
        and isinstance(r["answerability"].get("passed"), bool)
    ]
    if ans:
        _corr(ans, "answerability")
        passed = [h for f, h in ans if f]
        failed = [h for f, h in ans if not f]
        report["layers"]["answerability"].update(
            mean_when_passed=round(sum(passed) / len(passed), 2) if passed else None,
            mean_when_failed=round(sum(failed) / len(failed), 2) if failed else None,
        )

    # judges: panel mean + per-judge
    panel_pairs, per_judge_pairs = [], {}
    for r in rows:
        pj = _judge_scores(r.get("judges"))
        if pj:
            panel_pairs.append((sum(pj.values()) / len(pj), r["human"]))
            for name, score in pj.items():
                per_judge_pairs.setdefault(name, []).append((score, r["human"]))
    if panel_pairs:
        _corr(panel_pairs, "judges_panel_mean")
        for name, p in per_judge_pairs.items():
            _corr(p, f"judge:{name}")

    # verify (D27): verdict groups + verified-vs-not point-biserial
    ver = [
        (1.0 if r["verify"].get("verdict") == "verified" else 0.0, r["human"])
        for r in rows
        if isinstance(r.get("verify"), dict) and "verdict" in r["verify"]
    ]
    if ver:
        _corr(ver, "verify")
        groups: dict[str, list[float]] = {}
        for r in rows:
            if isinstance(r.get("verify"), dict) and "verdict" in r["verify"]:
                groups.setdefault(r["verify"]["verdict"], []).append(r["human"])
        report["layers"]["verify"]["mean_by_verdict"] = {
            k: round(sum(v) / len(v), 2) for k, v in groups.items()
        }

    out = run_dir / "correlations.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"\nwrote {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
