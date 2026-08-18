"""#165 — evaluate a judge/layer against the frozen D21 eval set.

Two references, per the D21 methodology (issue-164):
  - michal axis (1-10 product label) -> Spearman, for scoring layers
  - editorial flags (fact_error/logic_flaw/stale)  -> recall/precision, for
    detection layers; duplicate-flagged rows are excluded from Spearman

Default run reports the baselines for the layers frozen inside the set
(critique, answerability, judges panel, verify). A new layer's outputs are
evaluated via --scores: a JSON object mapping qid -> number (scoring layer)
or qid -> bool (detection layer, true = "flagged as bad").

    uv run --no-sync python scripts/eval_d21_set.py
    uv run --no-sync python scripts/eval_d21_set.py --scores my_layer.json
"""

import argparse
import json
from pathlib import Path

from correlate_d21 import _judge_scores, _spearman

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SET = REPO_ROOT / "docs" / "testing" / "eval-sets" / "d21-2026-08.jsonl"
ERROR_FLAGS = ("fact_error", "logic_flaw", "stale")


def _load(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit(f"empty eval set: {path}")
    return rows


def _spearman_report(pairs, label, results):
    s = _spearman([x for x, _ in pairs], [y for _, y in pairs])
    results[label] = {"n": len(pairs), "spearman_vs_michal": round(s, 3) if s is not None else None}


def _recall_report(detected: dict[str, bool], rows, label, results):
    """detected: qid -> layer says 'bad'. Reference = editorial error flags."""
    bad = {r["qid"] for r in rows if any(r["flags"][f] for f in ERROR_FLAGS)}
    scored = {qid for qid in detected if qid in {r["qid"] for r in rows}}
    hits = sum(1 for qid in bad if detected.get(qid))
    flagged = sum(1 for qid in scored if detected.get(qid))
    results[label] = {
        "n": len(scored),
        "error_rows": len(bad),
        "recall": round(hits / len(bad), 2) if bad else None,
        "precision": round(hits / flagged, 2) if flagged else None,
        "detected": hits,
        "flagged_total": flagged,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--eval-set", default=str(DEFAULT_SET))
    ap.add_argument("--scores", help="JSON: qid -> number (scoring) or bool (detection)")
    ap.add_argument("--include-duplicates", action="store_true",
                    help="keep duplicate-flagged rows in Spearman (D21 baseline .242 was computed on all 88)")
    args = ap.parse_args()

    rows = _load(Path(args.eval_set))
    results: dict[str, dict] = {}

    spearman_rows = rows if args.include_duplicates else [
        r for r in rows if not r["flags"]["duplicate"]
    ]

    def pairs(fn):
        out = []
        for r in spearman_rows:
            v = fn(r)
            if isinstance(v, (int, float)):
                out.append((float(v), r["michal_score"]))
        return out

    _spearman_report(pairs(lambda r: (r["layers"].get("critique") or {}).get("overall_score")),
                     "critique", results)
    _spearman_report(pairs(lambda r: {True: 1.0, False: 0.0}.get(
        (r["layers"].get("answerability") or {}).get("passed"))), "answerability", results)
    _spearman_report(pairs(lambda r: (
        sum(pj.values()) / len(pj) if (pj := _judge_scores(r["layers"].get("judges"))) else None
    )), "judges_panel_mean", results)

    # verify is a detection layer: likely_wrong = detected (matches issue-164's 3/7 count)
    _recall_report(
        {r["qid"]: (r["layers"].get("verify") or {}).get("verdict") == "likely_wrong"
         for r in rows if isinstance(r["layers"].get("verify"), dict)},
        rows, "verify_detection", results)

    if args.scores:
        scores = json.loads(Path(args.scores).read_text())
        vals = [v for v in scores.values() if v is not None]
        if vals and all(isinstance(v, bool) for v in vals):
            _recall_report({q: bool(v) for q, v in scores.items()}, rows,
                           "new_layer_detection", results)
        else:
            by_qid = {r["qid"]: r for r in spearman_rows}
            p = [(float(v), by_qid[q]["michal_score"])
                 for q, v in scores.items()
                 if isinstance(v, (int, float)) and q in by_qid]
            _spearman_report(p, "new_layer", results)

    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
