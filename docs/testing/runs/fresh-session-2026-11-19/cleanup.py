"""Session review of the fresh-entertainment rows imported today (en/sk/cs), prod via tunnel.
Rejects one row of two spoiler pairs and fixes a Czech verb form in two Slovak questions
(text change -> embeddings recomputed with the importer's own helpers).
Usage (cwd apps/quiz-pack-api, root .env loaded, DATABASE_URL at the tunnel):
    python cleanup.py [--apply]"""

import asyncio
import json
import os
import re
import sys
from datetime import UTC, datetime

import asyncpg

NOTE = "session review 2026-11-19: "
REJECT = {
    "d316212e": "same Patrick Stewart one-man Christmas Carol fact as dc589c2a and gives its answer away",
    "ota-jirak": "answer is a sentence and the row overlaps the ALF question about the same dubbing actor",
}
REPLACE = [("nazpieval", "naspieval")]  # also covers nazpievala


async def main(apply: bool) -> None:
    url = re.sub(r"^postgresql\+\w+://", "postgresql://", os.environ["DATABASE_URL"].split("?")[0])
    conn = await asyncpg.connect(url, ssl=False)
    try:
        jirak = await conn.fetchrow(
            "select id from questions where language='cs' and created_at::date = current_date "
            "and correct_answer::text like '%Ota Jirák%'"
        )
        rej = {
            "d316212e": await conn.fetchval("select id from questions where id::text like 'd316212e%'"),
            "ota-jirak": jirak["id"],
        }
        fix = await conn.fetch(
            "select id, question, correct_answer, possible_answers from questions "
            "where language='sk' and created_at::date = current_date and question like '%nazpieval%'"
        )
        print("reject:", {k: str(v) for k, v in rej.items()})
        new_text = {}
        for r in fix:
            q = r["question"]
            for a, b in REPLACE:
                q = q.replace(a, b)
            new_text[r["id"]] = q
            print("fix:", str(r["id"])[:8], "|", q[:140])
        assert all(rej.values()) and len(fix) == 2, "unexpected row set, nothing written"
        if not apply:
            return
        from app.corpus.importer import _embed_batch
        from openai import OpenAI
        from quiz_shared.utils.qa_text import qa_text

        texts = list(new_text.values()) + [
            qa_text(new_text[r["id"]], json.loads(r["correct_answer"]), json.loads(r["possible_answers"] or "null"))
            for r in fix
        ]
        vecs = _embed_batch(OpenAI(), texts)
        vec = lambda v: "[" + ",".join(repr(x) for x in v) + "]"  # noqa: E731
        async with conn.transaction():
            for key, rid in rej.items():
                await conn.execute(
                    "update questions set review_status='rejected', review_notes=$2, "
                    "reviewed_by='agent:session-review', reviewed_at=$3 where id=$1",
                    rid, NOTE + REJECT[key], datetime.now(UTC),
                )
            for i, r in enumerate(fix):
                await conn.execute(
                    "update questions set question=$2, embedding=$3::vector, embedding_qa=$4::vector where id=$1",
                    r["id"], new_text[r["id"]], vec(vecs[i]), vec(vecs[len(fix) + i]),
                )
        print("applied")
    finally:
        await conn.close()


asyncio.run(main("--apply" in sys.argv))
