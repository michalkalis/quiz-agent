"""Read-only dump of every entertainment row already in prod (all statuses except rejected,
en + native sk/cs): prod-entertainment.json for curation dedup, covered-fresh.txt for the brief."""

import argparse
import asyncio
import json
import re
from pathlib import Path

from quiz_shared.database.engine import normalize_async_url
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

SQL = text(
    "select id, language, review_status, question, correct_answer, boost_until, created_at "
    "from questions where category = 'entertainment' and pack_id is null "
    "and review_status <> 'rejected' order by language, created_at"
)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--database-url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", required=True)
    a = ap.parse_args()
    eng = create_async_engine(normalize_async_url(a.database_url))
    async with eng.connect() as c:
        rows = [dict(r._mapping) for r in await c.execute(SQL)]
    await eng.dispose()
    for r in rows:
        r["boost_until"] = r["boost_until"].isoformat() if r["boost_until"] else None
        r["created_at"] = r["created_at"].isoformat()
        r["id"] = str(r["id"])
    Path(a.json).write_text(json.dumps(rows, ensure_ascii=False, indent=1))
    # Brief input: every row whose stem names 2025/2026 (the fresh-type facts), all languages,
    # because EN rows also serve sk/cs sessions.
    lines = [
        "Already covered in the corpus - do NOT ask about these facts again, not even reworded or reversed:"
    ]
    lines += [
        f"- {r['question'][:140].strip()} -> {str(r['correct_answer'])[:40]}"
        for r in rows
        if re.search(r"202[56]", r["question"])
    ]
    Path(a.out).write_text("\n".join(lines) + "\n")
    print(len(rows), "rows,", len(lines) - 1, "covered fresh-type stems")


asyncio.run(main())
