"""Read-only: dump serveable prod questions whose category is outside the taxonomy.

Run on a quiz-agent-api machine (DATABASE_URL in env). Prints JSON lines.
"""
import asyncio
import json
import os

import asyncpg

TAXONOMY = ["science-nature", "history", "geography-world", "movies-music",
            "sports", "food-everyday", "entertainment"]


async def main():
    url = os.environ["DATABASE_URL"].replace("postgresql+asyncpg://", "postgresql://")
    conn = await asyncpg.connect(url)
    summary = await conn.fetch(
        "SELECT category, review_status, coalesce(language,'-') lang, count(*) n FROM questions "
        "WHERE review_status IN ('approved','pending_review') AND NOT (category = ANY($1)) "
        "GROUP BY 1,2,3 ORDER BY 1,2,3", TAXONOMY)
    for r in summary:
        print("#", dict(r))
    rows = await conn.fetch(
        "SELECT id::text, category, review_status, language, topic, pack_id::text pack, question, correct_answer::text ca "
        "FROM questions WHERE review_status IN ('approved','pending_review') AND NOT (category = ANY($1)) "
        "ORDER BY language NULLS FIRST, topic, id", TAXONOMY)
    for r in rows:
        print(json.dumps(dict(r), ensure_ascii=False))
    await conn.close()

asyncio.run(main())
