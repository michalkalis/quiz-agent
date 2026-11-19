#!/usr/bin/env python3
"""#231 batch 1: corrections to 186 Ukrainian questions already in prod.

Default is --dry-run (read-only). --apply writes a JSON backup of the original
rows next to this script, then updates everything in ONE transaction.

Needs the prod tunnel on localhost:15432 (never opened/closed here):
    ssh -N -L 15432:127.0.0.1:5432 trubbo-prod

Run (repo code is only imported, never edited):
    R=/Users/agent/code/quiz-agent
    PYTHONPATH=$R/apps/quiz-pack-api:$R/packages/shared \
        $R/.venv/bin/python apply_corrections.py [--dry-run | --apply]

How an edit stays consistent in this codebase (see report):
  * question text change  -> embedding AND embedding_qa recomputed with the importer's own
    helpers (app.corpus.importer._embed_batch + quiz_shared qa_text), model/dim re-stamped.
  * explanation / alternative_answers / source_* -> not embedded, plain columns.
  * answer_key is untouched (derived from correct_answer, which no decision changes).
  * a row that stays approved must still clear the machine gate predicate
    (app.scoring.machine_approval, incl. uk_policy) on the NEW text; if it does not,
    it drops to pending_review (TestFlight-only) instead of staying approved.
  * rejected / held rows: review_status + review_notes (+ reviewed_by/at) only; embeddings kept.
No Chroma: ChromaDB is retired (#41); Postgres+pgvector is the only store.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

import asyncpg

HERE = Path(__file__).resolve().parent
REPO = Path("/Users/agent/code/quiz-agent")
ENV_FILE = REPO / ".env"
MERGED = REPO / "docs/testing/runs/uk-corpus-2026-11-18/merged-uk.json"
TUNNEL_PORT = 15432
DATE = "2026-11-18"
AGENT_REVIEWER = (
    "agent:231-review"  # no agent name exists in the corpus yet; humans use "michal"
)
MACHINE = "machine:gates-v2"  # == app.scoring.machine_approval.GATE_VERSION on branch fix/231-uk-question-gates (PR #901); asserted below

sys.path += [str(REPO / "apps/quiz-pack-api"), str(REPO / "packages/shared")]
sys.dont_write_bytecode = True


def wiki(lang: str, title: str) -> str:
    return f"https://{lang}.wikipedia.org/wiki/" + quote(
        title.replace(" ", "_"), safe="/:_(),"
    )


# ── decisions (batch1-corrections.md) ───────────────────────────────────────
# kind: reject | hold | edit.  fixes: (field, before, after) substring replacements.
# drop_alts: exact alternative_answers entries to remove. source: (url, excerpt).
SPECS: list[dict] = [
    {
        "id": "651bb3fd",
        "kind": "reject",
        "why": "same Лісова пісня/Kutaisi fact as 4e51335d; each question gives away the other's answer; keep 4e51335d",
    },
    {
        "id": "1cd26d88",
        "kind": "reject",
        "why": "Baiul 1994 gold duplicates 816408eb, which states it; keep 816408eb",
    },
    {
        "id": "43dd5026",
        "kind": "reject",
        "why": "Paton bridge welded: 6bf36e1f says the Paton institute is known for welding; keep 6bf36e1f",
    },
    {
        "id": "2830029d",
        "kind": "reject",
        "why": "Orlyk constitution in Bendery duplicates 94f572f8, mutual spoilers; keep 94f572f8",
    },
    {
        "id": "d06550b7",
        "kind": "hold",
        "why": "answer is the bare letter «Ї», fragile for speech recognition; a native speaker tries it",
    },
    # 52b2184c: already pending_review ("already held"), decision = leave. Resolved + checked, not changed.
    {"id": "52b2184c", "kind": "leave", "expect_status": "pending_review"},
    {
        "id": "aa7fd8c6",
        "kind": "edit",
        "why": "question no longer gives away 79b7b17a's answer (Куліш)",
        "fixes": [
            (
                "question",
                "що варили куліш і грали у футбол",
                "що грали у футбол і рятували наречених",
            )
        ],
    },
    {
        "id": "ce82ec2f",
        "kind": "edit",
        "why": "explanation: drop unsupported Moscow/Stockholm comparison",
        "fixes": [
            (
                "explanation",
                "часто ставлять їх поруч зі станціями Москви та Стокгольма",
                "часто згадують їх серед найкрасивіших станцій метро у світі",
            )
        ],
    },
    {
        "id": "700051b8",
        "kind": "edit",
        "why": "explanation typo (Russian spelling)",
        "fixes": [("explanation", "мумифікувалися", "муміфікувалися")],
    },
    {
        "id": "80025f4c",
        "kind": "edit",
        "why": "explanation wording",
        "fixes": [
            (
                "explanation",
                "Каспійське море тут не рахується",
                "Каспійське море тут не враховують",
            )
        ],
    },
    {
        "id": "9eeff437",
        "kind": "edit",
        "why": "question: name the court exactly",
        "fixes": [
            (
                "question",
                "у третьому найвищий суд",
                "у третьому Верховний апеляційний суд",
            )
        ],
    },
    {
        "id": "19534368",
        "kind": "edit",
        "why": "spear length as on the cited Pfeilstorch page (75 cm spear); excerpt updated to the sentence that states it",
        "fixes": [
            (
                "question",
                "стирчала стріла завдовжки майже метр",
                "стирчав спис завдовжки сімдесят п'ять сантиметрів",
            ),
            ("question", "приніс цю стрілу?", "приніс цей спис?"),
            (
                "explanation",
                "Стріла була африканської роботи",
                "Спис був африканської роботи",
            ),
        ],
        "source": (
            wiki("en", "Pfeilstorch"),
            "It was carrying a 75-centimetre (30 in) spear from central Africa in its neck.",
        ),
    },
    {
        "id": "410481cf",
        "kind": "edit",
        "why": "question: «єдиним коронованим» is not supported",
        "fixes": [
            (
                "question",
                "першим і єдиним коронованим королем Русі",
                "першим королем Русі",
            )
        ],
    },
    # alternative answers: remove Russian forms / ambiguous bare «Буг»
    {
        "id": "b415b52b",
        "kind": "edit",
        "why": "drop Russian form",
        "drop_alts": ["Вена"],
    },
    {
        "id": "0ff64b23",
        "kind": "edit",
        "why": "drop Russian form",
        "drop_alts": ["Борщев"],
    },
    {
        "id": "dbbb2343",
        "kind": "edit",
        "why": "drop Russian form",
        "drop_alts": ["Запорожжя"],
    },
    {
        "id": "53682a03",
        "kind": "edit",
        "why": "drop Russian form",
        "drop_alts": ["Меланин"],
    },
    {
        "id": "483aa3e0",
        "kind": "edit",
        "why": "bare «Буг» also matches the Western Bug",
        "drop_alts": ["Буг"],
    },
    # source replacements (excerpts verified verbatim against the live page text, accents stripped)
    {
        "id": "b1d9c38d",
        "kind": "edit",
        "why": "source: Russian state promo site -> uk.wikipedia",
        "drop_alts": ["папоротник"],
        "source": (
            wiki("uk", "Папоротеподібні"),
            "У слов'янській міфології квітка папороті наділялася магічними властивостями, хоча папороті не квітнуть, а розмножуються спорами.",
        ),
    },
    {
        "id": "cec42442",
        "kind": "edit",
        "why": "source: kino.mail.ru -> uk.wikipedia (page confirms raindrop + wolf cub; it does not state 1980/Kyiv)",
        "source": (
            wiki("uk", "Капітошка"),
            "Але потім він зустрічає краплинку дощу Капітошку, завдяки якому розуміє, що зовсім не обов'язково бути страшним.",
        ),
    },
    {
        "id": "7631de88",
        "kind": "edit",
        "why": "source: Vasmer (Russian dictionary) -> uk.wikipedia Базар",
        "source": (
            wiki("uk", "Базар"),
            "Базар (з перс. بازار — бозор ← пехл. wāzār ← д.-перс. vāčar ← протоіндоіран *wahā-čarana, що приблизно означає «ринок»)",
        ),
    },
    {
        "id": "d7dc05e7",
        "kind": "edit",
        "why": "source: Artemis page -> Kondratyuk article",
        "source": (
            wiki("uk", "Кондратюк Юрій Васильович"),
            "На його честь названа «траса Кондратюка», якою подорожували на Місяць космічні кораблі «Аполлон».",
        ),
    },
    {
        "id": "2dd29bde",
        "kind": "edit",
        "why": "source: Bruce Vilanch page -> Jack Palance article (en; uk page says age 72, question says 73)",
        "source": (
            wiki("en", "Jack Palance"),
            "He then dropped to the floor and demonstrated his ability, at the age of 73, to perform one-armed push-ups.",
        ),
    },
    {
        "id": "5b9c2c17",
        "kind": "edit",
        "why": "source: IMDb -> Bubka article (en; uk page does not say 'only')",
        "source": (
            wiki("en", "Sergey Bubka"),
            "In 1988 Bubka competed in the Seoul Olympics and won his only Olympic gold medal clearing 5.90 meters.",
        ),
    },
]
# Merge specs that target the same row (none do today, kept explicit)
assert len({s["id"] for s in SPECS}) == len(SPECS)


def env_value(key: str) -> str:
    val = None
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            val = (
                line.split("=", 1)[1].strip().strip('"').strip("'")
            )  # last one wins, like `source`
    if not val:
        sys.exit(f"{key} missing in {ENV_FILE}")
    return val


async def connect() -> asyncpg.Connection:
    u = urlsplit(env_value("PROD_DATABASE_URL").split("?")[0])
    try:
        return await asyncpg.connect(
            host="localhost",
            port=TUNNEL_PORT,
            user=unquote(u.username or ""),
            password=unquote(u.password or ""),
            database=u.path.lstrip("/"),
            ssl=False,
            timeout=15,
        )
    except OSError as exc:
        sys.exit(f"cannot reach localhost:{TUNNEL_PORT} (is the SSH tunnel up?): {exc}")


def jload(v):
    return json.loads(v) if isinstance(v, str) else v


def short(s, n=110):
    s = "" if s is None else str(s).replace("\n", " ")
    return s if len(s) <= n else s[: n - 1] + "…"


def plan_row(spec: dict, row: dict) -> dict:
    """Pure: compute the new values for one row. Fails loudly on a stale 'before'."""
    new: dict = {}
    reasons: list[str] = []
    if spec["kind"] == "leave":
        if row["review_status"] != spec["expect_status"]:
            raise SystemExit(
                f"{spec['id']}: expected {spec['expect_status']}, found {row['review_status']}"
            )
        return {"changes": {}, "note": None}
    for field, before, after in spec.get("fixes", []):
        cur = new.get(field, row[field])
        if cur is None or cur.count(before) != 1:
            raise SystemExit(
                f"{spec['id']}: {field} no longer contains exactly one {before!r}"
            )
        new[field] = cur.replace(before, after)
    if spec.get("drop_alts"):
        alts = jload(row["alternative_answers"]) or []
        for a in spec["drop_alts"]:
            if a not in alts:
                raise SystemExit(
                    f"{spec['id']}: alternative_answers lacks {a!r}: {alts}"
                )
        new["alternative_answers"] = [a for a in alts if a not in spec["drop_alts"]]
    if spec.get("source"):
        url, exc = spec["source"]
        new["source_url"], new["source_excerpt"] = url, exc
    reasons.append(spec["why"])
    return {"changes": new, "note": f"#231 review {DATE}: " + "; ".join(reasons)}


def build_question(row: dict, ch: dict):
    """Question as it will be stored: merged-uk.json shell + the NEW text from the row/changes.
    generation_metadata comes from the production `provenance` column, which is where the
    importer stored the naturalness verdict (extra["naturalness"])."""
    from quiz_shared.models.question import Question

    merged = MERGED_BY_ID[str(row["id"])]
    payload = {**merged, "review_status": "pending_review"}
    for f in (
        "question",
        "explanation",
        "source_url",
        "source_excerpt",
        "headline_answer",
    ):
        payload[f] = ch.get(f, row[f])
    payload["alternative_answers"] = ch.get(
        "alternative_answers", jload(row["alternative_answers"])
    )
    payload["correct_answer"] = jload(row["correct_answer"])
    payload["possible_answers"] = jload(row["possible_answers"])
    payload["generation_metadata"] = jload(row["provenance"])
    return Question.model_validate(payload)


MERGED_BY_ID = {q["id"]: q for q in json.loads(MERGED.read_text())}


def embed_new(
    rows_changes: list[tuple[dict, dict]],
) -> dict[str, tuple[list[float], list[float]]]:
    """Existing importer helper; cents for a handful of rows. Returns id -> (emb, emb_qa)."""
    from app.corpus.importer import EMBEDDING_MODEL, _embed_batch
    from openai import OpenAI
    from quiz_shared.utils.qa_text import qa_text

    assert EMBEDDING_MODEL == "text-embedding-3-small"
    import os

    os.environ["OPENAI_API_KEY"] = env_value("OPENAI_API_KEY")
    texts, ids = [], []
    for row, ch in rows_changes:
        ids.append(str(row["id"]))
        texts.append(ch["question"])
    for row, ch in rows_changes:
        texts.append(
            qa_text(
                ch["question"],
                jload(row["correct_answer"]),
                jload(row["possible_answers"]),
            )
        )
    vecs = _embed_batch(OpenAI(), texts)
    n = len(ids)
    return {i: (list(vecs[k]), list(vecs[n + k])) for k, i in enumerate(ids)}


async def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--dry-run", action="store_true", help="default: read-only, print the plan"
    )
    mode.add_argument(
        "--apply",
        action="store_true",
        help="backup, then write everything in one transaction",
    )
    args = ap.parse_args()
    apply = args.apply

    conn = await connect()
    try:
        cols = [
            r["column_name"]
            for r in await conn.fetch(
                "select column_name from information_schema.columns where table_name='questions' order by ordinal_position"
            )
        ]
        sel = ", ".join(
            f"{c}::text AS {c}" if c in ("embedding", "embedding_qa") else c
            for c in cols
        )
        plans = []
        for spec in SPECS:
            rows = await conn.fetch(
                f"select {sel} from questions where id::text like $1", spec["id"] + "%"
            )
            if len(rows) != 1:
                sys.exit(f"{spec['id']}: expected exactly 1 row, found {len(rows)}")
            row = dict(rows[0])
            if row["language"] != "uk":
                sys.exit(f"{spec['id']}: language is {row['language']!r}, not uk")
            p = plan_row(spec, row)
            ch = dict(p["changes"])
            note = p["note"]
            if spec["kind"] == "reject":
                ch.update(
                    review_status="rejected",
                    reviewed_by=AGENT_REVIEWER,
                    reviewed_at=datetime.now(UTC),
                )
                note = f"#231 review {DATE}: rejected, {spec['why']}"
            elif spec["kind"] == "hold":
                ch.update(
                    review_status="pending_review", reviewed_by=None, reviewed_at=None
                )
                note = f"#231 review {DATE}: held for a human, {spec['why']}"
            if note:
                ch["review_notes"] = " | ".join(
                    x for x in (row["review_notes"], note) if x
                )
            plans.append((spec, row, ch))

        # ── phase 2: gates-v2 on every uk row that is approved after phase 1 ────
        from app.scoring.machine_approval import (
            GATE_VERSION,
            machine_approval_block_reason,
            tf_imbalance_excess_ids,
        )

        assert GATE_VERSION == MACHINE, (
            f"run with PYTHONPATH on the gates-v2 worktree (got {GATE_VERSION})"
        )
        touched = {str(r["id"]): (spec, r, ch) for spec, r, ch in plans}
        for r in await conn.fetch(
            f"select {sel} from questions where language='uk' and review_status='approved'"
        ):
            if str(r["id"]) not in touched:
                touched[str(r["id"])] = (
                    {"kind": "gates2", "id": str(r["id"])[:8]},
                    dict(r),
                    {},
                )
        live = [
            (sid, spec, r, ch)
            for sid, (spec, r, ch) in touched.items()
            if ch.get("review_status", r["review_status"]) == "approved"
        ]
        qs = {sid: build_question(r, ch) for sid, _s, r, ch in live}
        tf_excess = tf_imbalance_excess_ids(qs.values())
        verdicts = {"ok": 0, "not_ok": 0, "missing": 0}
        now = datetime.now(UTC)
        pending_list = []
        for sid, spec, r, ch in live:
            nat = (jload(r["provenance"]) or {}).get("extra", {}).get("naturalness")
            verdicts[
                "missing"
                if not isinstance(nat, dict)
                else "ok"
                if nat.get("ok") is True
                else "not_ok"
            ] += 1
            block = machine_approval_block_reason(qs[sid], tf_excess)
            if block is None:
                ch.update(reviewed_by=MACHINE, reviewed_at=now)
            else:
                note = f"#231 review {DATE}: gates-v2 hold: {block}"
                ch.update(
                    review_status="pending_review",
                    reviewed_by=None,
                    reviewed_at=None,
                    review_notes=" | ".join(
                        x
                        for x in (ch.get("review_notes", r["review_notes"]), note)
                        if x
                    ),
                )
                pending_list.append((sid, r, block))
            touched[sid] = (spec, r, ch)
        plans = [(s_, r_, c_) for s_, r_, c_ in touched.values() if c_]
        print(
            f"gates-v2 phase: {len(live)} approved rows checked; naturalness verdicts {verdicts}; "
            f"{len(pending_list)} held, {len(live) - len(pending_list)} stay approved (reviewed_by={MACHINE})\n"
        )

        # ── report ─────────────────────────────────────────────────────────
        embed_rows = [(row, ch) for _s, row, ch in plans if "question" in ch]
        print(
            f"{'APPLY' if apply else 'DRY-RUN'}: {len(SPECS)} specs, all resolved to exactly 1 uk row; {len(plans)} rows change; "
            f"{len(embed_rows)} need embedding recompute (question text changed)\n"
        )
        for spec, row, ch in plans:
            if spec["kind"] == "gates2" and set(ch) == {"reviewed_by", "reviewed_at"}:
                continue  # compact: passing untouched rows only get the gates-v2 stamp (counted below)
            print(
                f"[{str(row['id'])[:8]}] {spec['kind']:6} status={row['review_status']} | {short(row['question'], 60)}"
            )
            if not ch:
                print("    (no change: already as decided)")
            for f, v in ch.items():
                old = row.get(f)
                if f == "alternative_answers":
                    o = jload(old) or []
                    print(
                        f"    alternative_answers: removed {[a for a in o if a not in v]}"
                    )
                elif f in ("question", "explanation"):
                    for fld, before, after in spec.get("fixes", []):
                        if fld == f:
                            print(f"    {f}: «{before}» → «{after}»")
                elif f == "review_notes":
                    print(f"    review_notes: … → {short(v.split(' | ')[-1], 200)}")
                elif f == "reviewed_at":
                    print("    reviewed_at: " + ("now" if v else "NULL"))
                else:
                    print(f"    {f}: {short(old)} → {short(v)}")
            if "question" in ch:
                print(
                    "    embedding, embedding_qa: recompute (text-embedding-3-small, 1536)"
                )
        stamp_only = sum(
            1
            for sp, _r, c in plans
            if sp["kind"] == "gates2" and set(c) == {"reviewed_by", "reviewed_at"}
        )
        print(
            f"\n{stamp_only} untouched approved rows only get reviewed_by={MACHINE}, reviewed_at=now (not listed)"
        )
        allrows = await conn.fetch(
            "select id::text id, category, review_status, left(question,60) q from questions where language='uk'"
        )
        final = {}
        for r in allrows:
            c = touched.get(r["id"], (None, None, {}))[2]
            final[r["id"]] = (
                r["category"],
                c.get("review_status", r["review_status"]),
                r["q"],
            )
        print("\n=== SUMMARY: final uk rows by status ===")
        for st in ("approved", "pending_review", "rejected"):
            print(f"  {st:15} {sum(1 for v in final.values() if v[1] == st)}")
        print("final approved by category:")
        cats: dict = {}
        for v in final.values():
            if v[1] == "approved":
                cats[v[0]] = cats.get(v[0], 0) + 1
        for k, n in sorted(cats.items(), key=lambda kv: -kv[1]):
            print(f"  {k:18} {n}")
        print("rows ending pending_review:")
        for sid, (cat, st, q) in sorted(final.items()):
            if st == "pending_review":
                sp, r, c = touched.get(sid, (None, None, {}))
                reason = (
                    (c.get("review_notes") or "")
                    .split(" | ")[-1]
                    .replace(f"#231 review {DATE}: ", "")
                    if c
                    else "already pending, unchanged (earlier hold)"
                )
                print(f"  {sid[:8]} | {cat} | {reason} | {q}")

        if not apply:
            print("\nDry run only, nothing written.")
            return 0

        backup = HERE / f"backup-{datetime.now(UTC):%Y%m%dT%H%M%SZ}.json"
        backup.write_text(
            json.dumps(
                [row for _s, row, _c in plans],
                ensure_ascii=False,
                indent=1,
                default=str,
            )
        )
        print(f"backup: {backup}")
        vecs = embed_new(embed_rows) if embed_rows else {}
        async with conn.transaction():
            for _s, row, ch in plans:
                if not ch:
                    continue
                sets, params = [], [row["id"]]
                for f, v in ch.items():
                    params.append(
                        json.dumps(v, ensure_ascii=False)
                        if f == "alternative_answers"
                        else v
                    )
                    sets.append(
                        f"{f} = ${len(params)}"
                        + ("::jsonb" if f == "alternative_answers" else "")
                    )
                rid = str(row["id"])
                if rid in vecs:
                    for f, vec in zip(("embedding", "embedding_qa"), vecs[rid]):
                        params.append("[" + ",".join(repr(x) for x in vec) + "]")
                        sets.append(f"{f} = ${len(params)}::vector")
                    sets += [
                        "embedding_model = 'text-embedding-3-small'",
                        "embedding_dim = 1536",
                        "embedding_qa_model = 'text-embedding-3-small'",
                    ]
                res = await conn.execute(
                    f"update questions set {', '.join(sets)} where id = $1", *params
                )
                if res != "UPDATE 1":
                    raise RuntimeError(
                        f"{rid}: {res}"
                    )  # rolls the whole transaction back
        print(
            f"applied {sum(1 for _s, _r, c in plans if c)} row updates in one transaction"
        )
        return 0
    finally:
        await conn.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
