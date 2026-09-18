#!/usr/bin/env zsh
# Read-only: status of sk/cs translation rows written today (2026-09-17) via the proxy tunnel.
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
set -a; source $ROOT/.env; set +a
$ROOT/.venv/bin/python - <<'EOF'
import asyncio, os, re
import asyncpg
url = os.environ["PROD_DATABASE_URL"].split("?")[0]
url = re.sub(r"^postgresql\+asyncpg", "postgresql", url).replace("quiz-pack-db.flycast:5432", "localhost:15432").replace("quiz-pack-db.internal:5432", "localhost:15432")
async def main():
    c = await asyncpg.connect(url, ssl=False)
    cols = [r["column_name"] for r in await c.fetch("select column_name from information_schema.columns where table_name='question_translations'")]
    print("cols:", cols)
    rows = await c.fetch("select language, status, count(*) n from question_translations where created_at::date = current_date group by 1,2 order by 1,2")
    for r in rows: print(r["language"], r["status"], r["n"])
    rows = await c.fetch("select language, left(headline_answer,40) a, left(question,90) q from question_translations where created_at::date = current_date and status='rejected' order by language")
    for r in rows: print("REJ", r["language"], "|", r["q"], "→", r["a"])
    rows = await c.fetch("select review_status, count(*) from questions where created_at::date = current_date group by 1")
    for r in rows: print("questions today", r["review_status"], r["count"])
    await c.close()
asyncio.run(main())
EOF
