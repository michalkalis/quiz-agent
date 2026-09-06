"""#168 — batch translation pipeline SK/CS, T9: validate the MQM-Quiz judge.

Sibling of ``scripts/factcheck_eval_166.py``: same JSONL-resume (``:90``) and
``cmd_report`` scorer shape, but its OWN items. DD6 is explicit about why the
qids are not shared — the seven from #166 — experimentálne kolo D21b (gen-review
blok 3b) are *factual* errors in English questions and exercise nothing in a
source-vs-target judge, so passing on them would certify nothing.

Reference sets (task T5, Session C, extended in T8 with the defect classes the
founder named while rating the SK arm batch on 2026-09-03/06):
``docs/testing/translation-defect-reference-sk.json`` and ``-cs.json``.

**Bar, per language (DD6):** every item labelled ``critical`` is caught (the
judge returns at least one ``critical`` finding on it) and there are ZERO
critical findings on the ``control`` items. Major/minor recall is printed and
is explicitly NOT gating. ``report`` exits non-zero when the bar is missed.

Held rows (an unavailable or unparseable judge) count as misses on defects and
are reported separately: the gate holds them as ``pending``, which is safe in
production but is not a catch.

Usage (from apps/quiz-pack-api/; run on the Claude Code subscription so the
eval spends no API credits — #169 — Session gateway):

    LLM_GATEWAY=session uv run --no-sync python scripts/translation_judge_eval.py \\
        judge --language sk
    uv run --no-sync python scripts/translation_judge_eval.py report --language sk
"""

import argparse
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors

load_dotenv_from_ancestors(Path(__file__).resolve())

from app.translation_verification.judge import TranslationJudge

REPO = Path(__file__).resolve().parents[3]
REFERENCE_DIR = REPO / "docs" / "testing"
OUT_DIR = REFERENCE_DIR / "runs" / "translation-judge-168"

LANGUAGES = ("sk", "cs")
CONCURRENCY = 4  # matches LLM_SESSION_CONCURRENCY's default (#169)


def load_items(language: str) -> list[dict]:
    path = REFERENCE_DIR / f"translation-defect-reference-{language}.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    items = data["items"]
    if not items:
        raise SystemExit(f"{path} has no items")
    return items


def done_qids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {json.loads(line)["qid"] for line in path.read_text().split("\n") if line}


def append_jsonl(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def out_path(language: str, tag: str) -> Path:
    return OUT_DIR / f"judge_{language}_{tag}.jsonl"


# ----------------------------------------------------------------- judge ----

async def cmd_judge(language: str, model: str | None, tag: str) -> None:
    """Run the judge over every reference item, resuming already-done qids."""
    items = load_items(language)
    path = out_path(language, tag)
    done = done_qids(path)
    todo = [i for i in items if i["qid"] not in done]
    print(f"{language}: {len(todo)} to judge, {len(done)} already done -> {path}")

    judge = TranslationJudge(model=model)
    semaphore = asyncio.Semaphore(CONCURRENCY)

    async def one(item: dict) -> None:
        async with semaphore:
            result = await judge.judge(item["source"], item["target"], language)
        findings = [f.as_dict() for f in result.findings]
        append_jsonl(
            path,
            {
                "qid": item["qid"],
                "origin": item["origin"],
                "expected_severity": item["severity"],
                "expected_category": item["defect_category"],
                "verdict": result.verdict,
                "held_for_review": result.held_for_review,
                "notes": result.notes,
                "findings": findings,
            },
        )
        worst = _worst(findings) or ("held" if result.held_for_review else "ok")
        print(f"  {item['qid']} ({item['severity']}) -> {worst}")

    await asyncio.gather(*(one(i) for i in todo))
    print(f"verdicts -> {path}")


# ---------------------------------------------------------------- report ----

_RANK = {"minor": 1, "major": 2, "critical": 3}


def _worst(findings: list[dict]) -> str | None:
    severities = [f.get("severity") for f in findings if f.get("severity") in _RANK]
    if not severities:
        return None
    return max(severities, key=lambda s: _RANK[s])


def cmd_report(language: str, tag: str) -> int:
    """Score one language against the DD6 bar. Returns the process exit code."""
    path = out_path(language, tag)
    if not path.exists():
        raise SystemExit(f"no verdicts at {path} — run `judge --language {language}`")
    records = {
        json.loads(line)["qid"]: json.loads(line)
        for line in path.read_text().split("\n")
        if line
    }
    items = load_items(language)
    missing = [i["qid"] for i in items if i["qid"] not in records]

    criticals = [i for i in items if i["severity"] == "critical"]
    controls = [i for i in items if i["origin"] == "control"]
    lesser = [i for i in items if i["severity"] in ("major", "minor")]

    caught, missed = [], []
    for item in criticals:
        record = records.get(item["qid"], {})
        if _worst(record.get("findings") or []) == "critical":
            caught.append(item["qid"])
        else:
            missed.append(item["qid"])

    false_alarms = [
        i["qid"]
        for i in controls
        if _worst(records.get(i["qid"], {}).get("findings") or []) == "critical"
    ]
    control_noise = [
        i["qid"]
        for i in controls
        if (records.get(i["qid"], {}).get("findings") or [])
        and i["qid"] not in false_alarms
    ]
    lesser_caught = [
        i["qid"] for i in lesser if records.get(i["qid"], {}).get("findings")
    ]
    held = [q for q, r in records.items() if r.get("held_for_review")]

    print(f"\n=== {path.name} (n={len(records)}/{len(items)}) ===")
    print(
        f"CRITICAL recall (GATING):   {len(caught)}/{len(criticals)}  "
        f"missed={sorted(missed)}"
    )
    print(
        f"CRITICAL false positives on controls (GATING): {len(false_alarms)}  "
        f"{sorted(false_alarms)}"
    )
    print(
        f"major/minor recall (NOT gating): {len(lesser_caught)}/{len(lesser)}  "
        f"missed={sorted(i['qid'] for i in lesser if i['qid'] not in lesser_caught)}"
    )
    print(f"non-critical findings on controls (NOT gating): {len(control_noise)}  {sorted(control_noise)}")
    print(f"held/unjudged: {len(held)}  {sorted(held)}")
    if missing:
        print(f"NOT JUDGED: {len(missing)}  {sorted(missing)}")
    for qid in sorted(missed) + sorted(false_alarms):
        record = records.get(qid, {})
        tag_ = "MISS" if qid in missed else "FP  "
        detail = "; ".join(
            f"{f.get('severity')}/{f.get('category')}: {str(f.get('note'))[:90]}"
            for f in (record.get("findings") or [])
        ) or record.get("notes") or "(no findings)"
        print(f"  {tag_} {qid}: {detail[:220]}")

    ok = not missed and not false_alarms and not missing
    print(
        f"\nDD6 bar for {language}: {'PASS' if ok else 'FAIL'} "
        f"(every critical caught, zero critical FP on controls)"
    )
    return 0 if ok else 1


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("judge", "report"):
        p = sub.add_parser(name)
        p.add_argument("--language", required=True, choices=LANGUAGES)
        p.add_argument(
            "--tag",
            default="run1",
            help="verdict-file suffix; a new tag starts a fresh run",
        )
        if name == "judge":
            p.add_argument("--model", default=None, help="override the judge model id")
    args = ap.parse_args()

    if args.cmd == "judge":
        asyncio.run(cmd_judge(args.language, args.model, args.tag))
    else:
        raise SystemExit(cmd_report(args.language, args.tag))


if __name__ == "__main__":
    main()
