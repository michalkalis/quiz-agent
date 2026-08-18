"""#165 — freeze the rated D21 round as a permanent eval set.

Deterministic join over the D21 run artifacts (blinded_qid is the key):

    mapping.json          blinded qid -> {arm, original_id, topic, question}
    <arm>.json            original question records (answer, explanation, ...)
    ratings_export.jsonl  michal scores (product axis, primary label)
    svitlanka_flags.json  editorial flags (fact/logic/stale/dup) + comments
    replay_results.json   layer verdicts (critique/duels/answerability/judges/verify)

Output: docs/testing/eval-sets/d21-2026-08.jsonl — one row per rated question,
fail-loud on any missing label. Evaluate new layers against it with
scripts/eval_d21_set.py.

    uv run --no-sync python scripts/build_d21_eval_set.py
"""

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_RUN_DIR = REPO_ROOT / "docs" / "testing" / "runs" / "d21-round-2026-08-15"
DEFAULT_OUT = REPO_ROOT / "docs" / "testing" / "eval-sets" / "d21-2026-08.jsonl"
BATCH_ID = "c1f109ec-9cc9-432c-88fd-d41e39292aec"

# Arm matrix as approved in issue-164 (§ Schválená matica).
ARMS = {
    "g-v3": {"mode": "grounded", "model": "kimi-k2.5", "prompt": "v3-fact-first"},
    "g-v5free": {"mode": "grounded", "model": "kimi-k2.5", "prompt": "v5-free"},
    "g-v6free": {"mode": "grounded", "model": "kimi-k2.5", "prompt": "v6-free"},
    "d-base": {"mode": "direct", "model": "kimi-k2.5", "prompt": "direct-v1"},
    "d-persona-a": {"mode": "direct", "model": "kimi-k2.5", "prompt": "direct-v1+persona-a"},
    "d-persona-b": {"mode": "direct", "model": "kimi-k2.5", "prompt": "direct-v1+persona-b"},
    "d-gemini": {"mode": "direct", "model": "gemini-3.1-pro", "prompt": "direct-v1"},
    "d-deepseek": {"mode": "direct", "model": "deepseek-v3.2", "prompt": "direct-v1"},
    "d-opus": {"mode": "direct", "model": "opus-5", "prompt": "direct-v1"},
    "d-fable": {"mode": "direct", "model": "fable-5", "prompt": "direct-v1"},
    "e-news": {"mode": "grounded+news", "model": "kimi-k2.5", "prompt": "entertainment"},
}

FLAG_KEYS = ("fact_error", "logic_flaw", "stale", "duplicate")


def _load_ratings(path: Path, rater: str) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            row = json.loads(line)
            if str(row.get("batch_id")) != BATCH_ID or row.get("rater") != rater:
                continue
            rows[row["blinded_qid"]] = row
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", default=str(DEFAULT_RUN_DIR))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    args = ap.parse_args()

    run_dir = Path(args.run_dir)
    mapping = json.loads((run_dir / "mapping.json").read_text())
    replay = json.loads((run_dir / "replay_results.json").read_text())
    flags_doc = json.loads((run_dir / "svitlanka_flags.json").read_text())["flags"]
    michal = _load_ratings(run_dir / "ratings_export.jsonl", "michal")
    svitlanka = _load_ratings(run_dir / "ratings_export.jsonl", "svitlanka")

    # original_id -> full question record, from the per-arm files
    records: dict[str, dict] = {}
    for arm in ARMS:
        for q in json.loads((run_dir / f"{arm}.json").read_text()):
            records[q["id"]] = q

    problems: list[str] = []
    out_rows = []
    for qid in sorted(mapping, key=lambda q: int(q[1:])):
        m = mapping[qid]
        arm = m["arm"]
        rec = records.get(m["original_id"])
        rep = replay.get(m["original_id"])
        mich = michal.get(qid)
        svit = svitlanka.get(qid)
        for cond, msg in (
            (rec is None, "question record"),
            (rep is None, "replay entry"),
            (mich is None, "michal rating"),
            (svit is None, "svitlanka rating"),
        ):
            if cond:
                problems.append(f"{qid}: missing {msg}")
        if rec is None or rep is None or mich is None or svit is None:
            continue

        qflags = flags_doc.get(qid, {})
        out_rows.append({
            "qid": qid,
            "arm": arm,
            **ARMS[arm],
            "topic": rec.get("topic"),
            "difficulty": rec.get("difficulty"),
            "question": rec["question"],
            "answer": rec["correct_answer"],
            "alternative_answers": rec.get("alternative_answers"),
            "explanation": rec.get("explanation"),
            # primary label: product axis (fun/playability while driving)
            "michal_score": mich["score_normalized_10"],
            "michal_comment": mich.get("reason"),
            # editorial axis: binary flags + original comment; svitlanka's 1-10
            # score kept for provenance only — it is NOT a quality label
            "flags": {k: bool(qflags.get(k)) for k in FLAG_KEYS},
            "flag_note": qflags.get("note"),
            "svitlanka_comment": svit.get("reason"),
            "svitlanka_score_raw": svit["score_normalized_10"],
            # replayed layer verdicts, for judge/layer calibration
            "layers": {k: rep.get(k) for k in
                       ("critique", "duels", "answerability", "judges", "verify")},
        })

    if problems:
        raise SystemExit("eval set INCOMPLETE, refusing to write:\n" + "\n".join(problems))
    if len(out_rows) != 88:
        raise SystemExit(f"expected 88 rows, built {len(out_rows)} — refusing to write")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.writelines(json.dumps(row, ensure_ascii=False) + "\n" for row in out_rows)

    n_flagged = sum(1 for r in out_rows if any(r["flags"].values()))
    print(f"wrote {out} — {len(out_rows)} rows, {n_flagged} with editorial flags")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
