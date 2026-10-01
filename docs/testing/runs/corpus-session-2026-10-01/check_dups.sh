#!/usr/bin/env zsh
# Keyword check of the 2026-10-01 batches against the live prod corpus (read-only) via the fly proxy tunnel.
set -u
ROOT=/Users/agent/code/quiz-agent
set -a; source $ROOT/.env; set +a
$ROOT/.venv/bin/python - "$@" <<'EOF'
import asyncio, os, sys, re
import asyncpg
url = os.environ["PROD_DATABASE_URL"]
url = re.sub(r"^postgresql\+asyncpg", "postgresql", url)
async def main():
    c = await asyncpg.connect(url.split("?")[0], ssl=False)
    for kw in sys.argv[1:]:
        rows = await c.fetch("select review_status, left(question,120) q, correct_answer from questions where question::text ilike $1 or correct_answer::text ilike $1 order by review_status", f"%{kw}%")
        print(f"== {kw}: {len(rows)}")
        for r in rows: print("  ", r["review_status"], "|", r["q"], "→", r["correct_answer"])
    await c.close()
asyncio.run(main())
EOF
