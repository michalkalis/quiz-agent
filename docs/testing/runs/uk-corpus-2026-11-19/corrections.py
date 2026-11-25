"""#231 second independent review (2026-11-19) of the Ukrainian rows already in prod.

1. Applies the reviewer's corrections to 15 approved rows (SPECS).
2. Labels every non-rejected uk row again with the naturalness check, whose uk verdict
   now also carries `off_policy` and `gives_away` (PR #916), on the Claude subscription.
3. Decides the approved rows again with the gates on main: a row that no longer clears
   them drops to pending_review (TestFlight only). Pending rows are never promoted here
   (open founder decision); they only get the new verdict stored for the human reader.

Default is a dry run. --apply writes a JSON backup next to this script, then updates
everything in one transaction. Needs the prod tunnel on localhost:15432.

    cd apps/quiz-pack-api && LLM_GATEWAY=session NATURALNESS_CHECK=1 \
      PYTHONPATH=.:../../packages/shared python <this file> [--apply]
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Batch 1's script: DB connection and the row -> Question builder (one definition).
_spec = importlib.util.spec_from_file_location(
    "batch1", HERE.parent / "uk-corpus-2026-11-18" / "apply_corrections.py"
)
b1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(b1)

NOTE = "#231 review 2026-11-19: "
WIKI_SOFIYIVKA = b1.wiki("uk", "Національний дендрологічний парк «Софіївка»")

SPECS: list[dict] = [
    {
        "id": "03807026",
        "why": "the tunnel is the underground river Acheron (Styx is the popular name, still accepted); no longer names the park (answer of d8a9892b)",
        "fixes": [
            ("question", "У «Софіївці» можна", "В уманському дендропарку можна"),
            ("explanation", "підземним Стіксом", "підземною річкою Ахеронт"),
        ],
        "answer": "Ахеронт",
        "alts": ["річка Ахеронт", "підземна річка Ахеронт", "Стікс", "річка Стікс", "підземна річка Стікс"],
        "source": (WIKI_SOFIYIVKA, "Підземна річка Ахеронт була споруджена в перший період будівництва"),
    },
    {
        "id": "8859fcff",
        "why": "no longer gives away 94f572f8's answer (Конституція)",
        "fixes": [("question", "Конституція Орлика ділила владу", "Документ Пилипа Орлика 1710 року ділив владу")],
    },
    {
        "id": "f5be1f4c",
        "why": "no longer gives away 4e51335d's answer (Лісова пісня)",
        "fixes": [("question", "Авторку «Лісової пісні» більшість", "Авторку вірша «Contra spem spero» більшість")],
    },
    {
        "id": "f726efa7",
        "why": "no longer gives away 7635659f's answer (Лобановський)",
        "fixes": [
            (
                "question",
                "Пам'ятник Валерію Лобановському біля стадіону «Динамо» не показує",
                "Пам'ятник найвідомішому тренерові київського «Динамо» біля клубного стадіону не показує",
            )
        ],
    },
    {
        "id": "01665c33",
        "why": "no longer gives away aa7fd8c6's answer (Грай); Olympia is not a country",
        "fixes": [("question", "Око, Грай і Тур змагаються", "три козаки змагаються")],
        "drop_alts": ["Олімпія"],
    },
    {
        "id": "28860395",
        "why": "clumsy wording",
        "fixes": [
            ("question", "У фіналі Ролан Гаррос 1999 року", "У фіналі «Ролан Гаррос» 1999 року"),
            (
                "question",
                "вигравав два сети. Проте суперник відіграв три партії поспіль",
                "виграв два перші сети. Проте суперник узяв три наступні",
            ),
        ],
    },
    {
        "id": "80025f4c",
        "why": "current term is Центральна Азія",
        "fixes": [("question", "у Середній Азії", "у Центральній Азії")],
    },
    {"id": "e92ddafa", "why": "«ковиль» is the Russian form", "drop_alts": ["ковиль"]},
    {
        "id": "f8a12d0a",
        "why": "source was the Russia-locale edition of the page; same article, UK edition",
        "source_replace": ("/en-ru/", "/en-gb/"),
    },
    {"id": "e5568459", "why": "«Мельниченко» is a different surname", "drop_alts": ["Мельниченко"]},
    {"id": "1d0bd621", "why": "«козачок» is a different dance", "drop_alts": ["козачок"]},
    {
        "id": "50270941",
        "reject": True,
        "why": "«шуфляда» is one sound away from the answer «шухляда»: the question states its answer",
    },
    {
        "id": "a1d0235c",
        "why": "«досі тримає рекорд» would go stale",
        "fixes": [
            (
                "question",
                "досі тримає рекорд: це найбільший розгром у фіналах чемпіонатів Європи.",
                "став найбільшим розгромом в історії фіналів чемпіонатів Європи на той час.",
            ),
            ("explanation", "і ніхто більше не вигравав", "і до того ніхто не вигравав"),
        ],
    },
    {
        "id": "7d6d124f",
        "why": "common phrasings of the same answer were missing",
        "add_alts": ["очі чутливіші до синього", "ми краще бачимо синій", "око слабко сприймає фіолетовий"],
    },
]


def edit(spec: dict, row: dict) -> dict:
    """Changed plain columns for one row; raises when the text is not what the review saw."""
    ch: dict = {}
    for field, before, after in spec.get("fixes", []):
        cur = ch.get(field, row[field])
        assert before in cur, f"{spec['id']}: {before!r} not in {field}"
        ch[field] = cur.replace(before, after)
    alts = b1.jload(row["alternative_answers"]) or []
    new_alts = spec.get("alts")
    if new_alts is None and (spec.get("drop_alts") or spec.get("add_alts")):
        for a in spec.get("drop_alts", []):
            assert a in alts, f"{spec['id']}: alternative {a!r} not present"
        new_alts = [a for a in alts if a not in spec.get("drop_alts", [])]
        new_alts += [a for a in spec.get("add_alts", []) if a not in new_alts]
    if new_alts is not None:
        ch["alternative_answers"] = new_alts
    if spec.get("source"):
        ch["source_url"], ch["source_excerpt"] = spec["source"]
    if spec.get("source_replace"):
        old, new = spec["source_replace"]
        assert old in row["source_url"], f"{spec['id']}: {old} not in source_url"
        ch["source_url"] = row["source_url"].replace(old, new)
    return ch


async def main(apply: bool) -> int:
    from app.db.models.question import question_to_row
    from app.generation.naturalness_check import NaturalnessChecker
    from app.scoring.machine_approval import (
        GATE_VERSION,
        machine_approval_block_reason,
        tf_imbalance_excess_ids,
    )

    conn = await b1.connect()
    try:
        rows = [
            dict(r)
            for r in await conn.fetch(
                "select id, question, explanation, correct_answer, possible_answers, alternative_answers, "
                "source_url, source_excerpt, headline_answer, provenance, review_status, review_notes, "
                "reviewed_by, reviewed_at, answer_key from questions "
                "where language='uk' and review_status <> 'rejected' "
                "and id::text = any($1::text[])",
                list(b1.MERGED_BY_ID),
            )
        ]
        by8 = {str(r["id"])[:8]: r for r in rows}
        now = datetime.now(UTC)
        plans: dict[str, dict] = {str(r["id"]): {} for r in rows}
        answers: dict[str, str] = {}
        reembed: set[str] = set()
        for spec in SPECS:
            row = by8[spec["id"]]
            rid = str(row["id"])
            assert row["review_status"] == "approved", f"{spec['id']} is {row['review_status']}"
            if spec.get("reject"):
                plans[rid] = {
                    "review_status": "rejected",
                    "review_notes": NOTE + "rejected, " + spec["why"],
                    "reviewed_by": b1.AGENT_REVIEWER,
                    "reviewed_at": now,
                }
                continue
            ch = edit(spec, row)
            ch["review_notes"] = NOTE + spec["why"]
            if "question" in ch or "answer" in spec:
                reembed.add(rid)
            if "answer" in spec:
                answers[rid] = spec["answer"]
            plans[rid] = ch

        # Questions as they will be stored, old naturalness verdict removed so every row is read again.
        qs = {}
        for r in rows:
            rid = str(r["id"])
            if plans[rid].get("review_status") == "rejected":
                continue
            q = b1.build_question(r, plans[rid])
            if rid in answers:
                q.correct_answer = answers[rid]
            if q.generation_metadata is not None:
                extra = dict(q.generation_metadata.extra)
                extra.pop("naturalness", None)
                q.generation_metadata = q.generation_metadata.model_copy(update={"extra": extra})
            qs[rid] = q
        checked = await NaturalnessChecker().label(list(qs.values()))
        print(f"naturalness: {checked}/{len(qs)} rows labelled, gates {GATE_VERSION}")

        live = {rid: q for rid, q in qs.items() if next(r for r in rows if str(r["id"]) == rid)["review_status"] == "approved"}
        tf_excess = tf_imbalance_excess_ids(live.values())
        held: dict[str, str] = {}
        for rid, q in qs.items():
            stored = question_to_row(q)
            ch = plans[rid]
            ch["provenance"] = stored.provenance
            if rid in answers:
                ch["correct_answer"] = stored.correct_answer
            if rid in live:
                block = machine_approval_block_reason(q, tf_excess)
                if block is None:
                    ch.update(reviewed_by=GATE_VERSION, reviewed_at=now)
                else:
                    held[rid] = block
                    ch.update(
                        review_status="pending_review",
                        review_notes=NOTE + "gates hold: " + block,
                        reviewed_by=GATE_VERSION,
                        reviewed_at=now,
                    )
        reasons: dict[str, int] = {}
        for block in held.values():
            reasons[block.split(":")[0]] = reasons.get(block.split(":")[0], 0) + 1
        n_live = len(live)
        print(f"approved before: {n_live + sum(1 for p in plans.values() if p.get('review_status') == 'rejected')}"
              f" -> stay approved {n_live - len(held)}, held {len(held)}, rejected "
              f"{sum(1 for p in plans.values() if p.get('review_status') == 'rejected')}")
        print("hold reasons:", reasons)
        for rid, block in held.items():
            print(f"  hold {rid[:8]} {block[:90]} | {qs[rid].question[:90]}")
        (HERE / "corrections-plan.json").write_text(
            json.dumps({rid: {k: v for k, v in ch.items() if k != "provenance"} for rid, ch in plans.items() if ch},
                       ensure_ascii=False, indent=1, default=str)
        )
        if not apply:
            return 0

        (HERE / f"backup-{now:%Y%m%dT%H%M%SZ}.json").write_text(
            json.dumps(rows, ensure_ascii=False, indent=1, default=str)
        )
        vecs = b1.embed_new_qa(
            [(qs[rid].question, qs[rid].correct_answer, qs[rid].possible_answers, rid) for rid in sorted(reembed)]
        ) if reembed else {}
        jsonb = {"alternative_answers", "provenance", "correct_answer"}
        async with conn.transaction():
            for r in rows:
                rid, ch = str(r["id"]), plans[str(r["id"])]
                if not ch:
                    continue
                sets, params = [], [r["id"]]
                for f, v in ch.items():
                    params.append(json.dumps(v, ensure_ascii=False) if f in jsonb else v)
                    sets.append(f"{f} = ${len(params)}" + ("::jsonb" if f in jsonb else ""))
                if rid in vecs:
                    for f, vec in zip(("embedding", "embedding_qa"), vecs[rid]):
                        params.append("[" + ",".join(repr(x) for x in vec) + "]")
                        sets.append(f"{f} = ${len(params)}::vector")
                res = await conn.execute(f"update questions set {', '.join(sets)} where id = $1", *params)
                if res != "UPDATE 1":
                    raise RuntimeError(f"{rid}: {res}")
        print(f"applied {sum(1 for c in plans.values() if c)} row updates in one transaction")
        return 0
    finally:
        await conn.close()


def _embed_new_qa(items):
    """id -> (question embedding, question+answer embedding), importer helpers."""
    import os

    from app.corpus.importer import _embed_batch
    from openai import OpenAI
    from quiz_shared.utils.qa_text import qa_text

    os.environ["OPENAI_API_KEY"] = b1.env_value("OPENAI_API_KEY")
    texts = [q for q, _a, _p, _i in items] + [qa_text(q, a, p) for q, a, p, _i in items]
    vecs = _embed_batch(OpenAI(), texts)
    n = len(items)
    return {items[k][3]: (list(vecs[k]), list(vecs[n + k])) for k in range(n)}


b1.embed_new_qa = _embed_new_qa

if __name__ == "__main__":
    sys.exit(asyncio.run(main("--apply" in sys.argv)))
