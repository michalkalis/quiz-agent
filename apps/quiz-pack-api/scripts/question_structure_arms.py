"""Blind test of the question-structure rule (founder 2026-09-21).

SK/CS questions in the corpus copy the English word order, so a listener in
the car cannot tell what is being asked. Two fixes are compared blind on the
#154 rating web against the hidden ``original`` (the approved row in prod):

  retranslate — arm A: the whole row re-translated from English under
                ``translate.QUESTION_STRUCTURE_RULE`` (prompt corpus-v2).
  rewrite     — arm B: the approved translation kept, only the question
                sentence rewritten under the same rule (``rewrite.py``).

Nothing here writes to the database. Sampling is seeded: most of the sample
is rows whose English question buries the question word ("...thanks to which
thriller..."), the rest are controls whose question already leads with it, so
the rule is also judged on rows it should leave alone.

Usage (from apps/quiz-pack-api/, prod reached read-only through the tunnel):

    uv run --no-sync python scripts/question_structure_arms.py build \\
        --language sk --n 20 --seed 2026 --out-dir DIR --database-url URL
    # publish DIR/retranslate-sk.json + DIR/rewrite-sk.json with
    # scripts/rating_page/publish_batch.py --save-mapping DIR/mapping.json,
    # founder rates blind, then:
    uv run --no-sync python scripts/question_structure_arms.py reveal \\
        --language sk --out-dir DIR --ratings DIR/ratings.jsonl
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import sys
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from statistics import mean
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from langchain_core.messages import HumanMessage, SystemMessage  # noqa: E402
from quiz_shared.llm import factory  # noqa: E402
from quiz_shared.paths import load_dotenv_from_ancestors  # noqa: E402

from app.translation_verification.draft import TranslatedDraft  # noqa: E402
from app.translation_verification.guards import run_guards  # noqa: E402
from app.translation_verification.judge import TranslationJudge  # noqa: E402
from scripts.translation_runner import translate as tr  # noqa: E402
from scripts.translation_runner import workset as ws  # noqa: E402
from scripts.translation_runner.rewrite import rewrite_question  # noqa: E402
from scripts.translation_runner.verify import (  # noqa: E402
    _draft_payload,
    _pending_rows,
    _split,
)

ARMS = ("retranslate", "rewrite")

#: An English question is "clean" when its last sentence already opens with the
#: question word or an auxiliary; anything else buries the interrogative.
_LEADING_INTERROGATIVE = re.compile(
    r"^(?:(?:in|on|for|from|to|by|of|at|with|under|during) )?"
    r"(?:what|which|who|whom|whose|where|when|why|how|name|is|are|was|were|"
    r"do|does|did|can|could|has|have|had|should|would)\b",
    re.IGNORECASE,
)


def buries_question_word(question: str) -> bool:
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", question.strip()) if s]
    last = sentences[-1] if sentences else question
    return not _LEADING_INTERROGATIVE.match(last.strip().lstrip("\"'“„("))


def select_sample(
    joined: list[dict[str, Any]], n: int, seed: int, controls: int
) -> list[tuple[str, dict[str, Any]]]:
    """``(bucket, joined_row)`` — ``buried`` rows spread round-robin over the
    source category, then ``control`` rows. Pure so the rule is testable."""
    rng = random.Random(seed)
    by_bucket: dict[str, dict[str, list[dict[str, Any]]]] = {
        "buried": defaultdict(list),
        "control": defaultdict(list),
    }
    for row in joined:
        bucket = "buried" if buries_question_word(row["src_question"]) else "control"
        by_bucket[bucket][row.get("src_category") or ""].append(row)
    out: list[tuple[str, dict[str, Any]]] = []
    for bucket, want in (("buried", n - controls), ("control", controls)):
        cells = [rows for rows in by_bucket[bucket].values() if rows]
        for rows in cells:
            rng.shuffle(rows)
        rng.shuffle(cells)
        picked: list[dict[str, Any]] = []
        while cells and len(picked) < want:
            for rows in list(cells):
                if len(picked) >= want:
                    break
                picked.append(rows.pop())
                if not rows:
                    cells.remove(rows)
        out.extend((bucket, r) for r in picked)
    return out


def arm_item(src: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    """``publish_batch.py`` arm-file shape; nothing here names the arm."""
    return {
        "id": str(src["id"]),
        "question": payload["question"],
        "possible_answers": payload.get("possible_answers") or None,
        "correct_answer": payload["correct_answer"],
        "alternative_answers": list(payload.get("alternative_answers") or []),
        "explanation": payload.get("explanation"),
        "topic": src.get("category") or "",
        "difficulty": src.get("difficulty"),
        "source_url": src.get("source_url"),
    }


async def gate(
    judge: TranslationJudge, src: dict[str, Any], payload: dict[str, Any], language: str
) -> dict[str, Any]:
    # The option key is DB provenance, not part of the translated payload — the
    # runner passes it the same way (``verify._draft``), else mcq_shape fires.
    draft = TranslatedDraft.from_payload(
        {**payload, "correct_answer_key": ws.correct_answer_key(src)}
    )
    guards = run_guards(ws.source_question(src), draft, language)
    verdict = await judge.judge(ws.source_fields(src), payload, language)
    return {"guards": guards, "judge": verdict.as_verification_json()}


async def cmd_build(args: argparse.Namespace) -> int:
    from app.db.engine import build_engine

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    engine = build_engine(args.database_url)
    try:
        joined = await _pending_rows(engine, args.language, 100_000, status="approved")
    finally:
        await engine.dispose()
    sample = select_sample(joined, args.n, args.seed, args.controls)
    print(f"{len(joined)} approved {args.language} rows → sample {len(sample)}")

    model = tr.TRANSLATION_MODEL[args.language]
    transport, used = tr.resolve_transport(model)
    chat = factory.chat_openai(model, max_tokens=tr.MAX_TOKENS)
    judge = TranslationJudge()
    sem = asyncio.Semaphore(args.concurrency)
    arms: dict[str, list[dict[str, Any]]] = {"original": [], **{a: [] for a in ARMS}}
    gates: dict[str, dict[str, Any]] = {}
    meta = {
        "language": args.language,
        "seed": args.seed,
        "model": used,
        "transport": transport,
        "prompt_version": tr.PROMPT_VERSION,
        "built_at": datetime.now(UTC).isoformat(),
        "sample": {},
        "failures": [],
    }

    async def one(bucket: str, joined_row: dict[str, Any]) -> None:
        row, src = _split(joined_row)
        qid = src["id"]
        original = _draft_payload(row)
        meta["sample"][qid] = bucket
        async with sem:
            try:
                response = await chat.ainvoke(
                    [
                        SystemMessage(content=tr._SYSTEM),
                        HumanMessage(content=tr.build_prompt(src, args.language)),
                    ]
                )
                retranslated = tr.parse_payload(factory.message_text(response))
                rewritten = {
                    **original,
                    "question": await rewrite_question(
                        chat, src["question"], original, args.language
                    ),
                }
            except Exception as exc:  # call boundary: record, never fake an arm
                meta["failures"].append({"qid": qid, "error": str(exc)[:300]})
                print(f"  FAILED {qid}: {exc}", file=sys.stderr)
                return
            gates[qid] = {
                "retranslate": await gate(judge, src, retranslated, args.language),
                "rewrite": await gate(judge, src, rewritten, args.language),
            }
        arms["original"].append(arm_item(src, original))
        arms["retranslate"].append(arm_item(src, retranslated))
        arms["rewrite"].append(arm_item(src, rewritten))
        print(f"  done {qid} ({bucket})")

    await asyncio.gather(*(one(b, r) for b, r in sample))

    for name, items in arms.items():
        items.sort(key=lambda i: i["id"])
        (out / f"{name}-{args.language}.json").write_text(
            json.dumps(items, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    (out / f"gate-{args.language}.json").write_text(
        json.dumps(gates, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (out / f"meta-{args.language}.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        f"wrote {len(arms['original'])} questions × {len(arms)} versions to {out} "
        f"({len(meta['failures'])} failed) — model {used} via {transport}"
    )
    return 1 if meta["failures"] else 0


def _gate_line(g: dict[str, Any] | None) -> str:
    if not g:
        return "brána: nebežala"
    judge = g["judge"]
    findings = judge.get("findings") or []
    parts = []
    if g["guards"]:
        parts.append("guard: " + "; ".join(g["guards"]))
    if judge.get("held_for_review"):
        parts.append("judge: nedostupný")
    elif findings:
        parts.append(
            "judge: "
            + "; ".join(f"{f['severity']} {f['category']} — {f['note']}" for f in findings)
        )
    return "brána: " + (" | ".join(parts) if parts else "čistá")


def cmd_reveal(args: argparse.Namespace) -> int:
    out = Path(args.out_dir)
    lang = args.language
    versions = {
        name: {i["id"]: i for i in json.loads((out / f"{name}-{lang}.json").read_text())}
        for name in ("original", *ARMS)
    }
    gates = json.loads((out / f"gate-{lang}.json").read_text())
    meta = json.loads((out / f"meta-{lang}.json").read_text())
    mapping = json.loads(Path(args.mapping).read_text())
    ratings: dict[str, dict[str, Any]] = {}
    for line in Path(args.ratings).read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if args.batch_id and r.get("batch_id") != args.batch_id:
            continue
        ratings[r["blinded_qid"]] = r
    scored: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)  # qid -> arm -> rating
    for bid, m in mapping.items():
        if bid in ratings:
            scored[m["original_id"]][m["arm"]] = ratings[bid]

    lines = [
        f"# Slepý test štruktúry otázky — {lang.upper()} ({meta['built_at'][:10]})",
        "",
        f"Model {meta['model']} cez {meta['transport']}, prompt {meta['prompt_version']}, "
        f"seed {meta['seed']}. Hodnotenie 1–10 z rating webu.",
        "",
        "| Verzia | Hodnotených | Priemer | ≥ 8 | Kritické nálezy brány |",
        "|---|---|---|---|---|",
    ]
    for arm in ARMS:
        scores = [float(r["score"]) for q in scored.values() for a, r in q.items() if a == arm]
        crit = sum(
            1
            for g in gates.values()
            if g.get(arm)
            and (
                g[arm]["guards"]
                or any(f["severity"] == "critical" for f in g[arm]["judge"].get("findings", []))
            )
        )
        avg = f"{mean(scores):.1f}" if scores else "–"
        lines.append(
            f"| {arm} | {len(scores)} | {avg} | {sum(s >= 8 for s in scores)} | {crit} |"
        )
    lines.append("")
    for qid in sorted(versions["original"]):
        o = versions["original"][qid]
        bucket = meta["sample"].get(qid, "?")
        lines += [
            f"## {o['topic']} · {bucket} · `{qid[:8]}`",
            "",
            f"**Originál (v prode):** {o['question']}",
            f"Odpoveď: {o['correct_answer']}",
            "",
        ]
        for arm in ARMS:
            v = versions[arm].get(qid)
            if not v:
                lines.append(f"**{arm}:** (zlyhalo)")
                continue
            r = scored.get(qid, {}).get(arm)
            score = f"**{r['score']}/10**" if r else "nehodnotené"
            reason = f" — {r['reason']}" if r and r.get("reason") else ""
            flags = f" [{', '.join(r['flags'])}]" if r and r.get("flags") else ""
            lines += [
                f"**{arm}** ({score}{flags}){reason}",
                f"{v['question']}",
            ]
            if v["correct_answer"] != o["correct_answer"]:
                lines.append(f"Odpoveď zmenená: {v['correct_answer']}")
            lines += [f"_{_gate_line(gates.get(qid, {}).get(arm))}_", ""]
    target = out / f"reveal-{lang}.md"
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {target}")
    return 0


def main() -> int:
    load_dotenv_from_ancestors(Path(__file__).resolve())
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--language", choices=("sk", "cs"), required=True)
    b.add_argument("--n", type=int, default=20)
    b.add_argument("--controls", type=int, default=5, help="clean-source rows inside --n")
    b.add_argument("--seed", type=int, default=2026)
    b.add_argument("--out-dir", required=True)
    b.add_argument("--database-url", required=True)
    b.add_argument("--concurrency", type=int, default=4)
    r = sub.add_parser("reveal")
    r.add_argument("--language", choices=("sk", "cs"), required=True)
    r.add_argument("--out-dir", required=True)
    r.add_argument("--ratings", required=True, help="export_ratings.py JSONL")
    r.add_argument("--mapping", default=None, help="defaults to OUT_DIR/mapping-LANG.json")
    r.add_argument("--batch-id", default=None, help="keep only this batch's ratings")
    args = p.parse_args()
    if args.cmd == "build":
        return asyncio.run(cmd_build(args))
    args.mapping = args.mapping or str(Path(args.out_dir) / f"mapping-{args.language}.json")
    return cmd_reveal(args)


if __name__ == "__main__":
    raise SystemExit(main())
