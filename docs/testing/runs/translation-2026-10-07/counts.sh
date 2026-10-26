#!/usr/bin/env zsh
# Read-only (2026-10-07): EN question counts and sk/cs translation counts, corpus vs pack.
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
    cols = {r["column_name"] for r in await c.fetch("select column_name from information_schema.columns where table_name='questions'")}
    pack = "pack_id" if "pack_id" in cols else None
    print("questions cols with pack/lang:", sorted(x for x in cols if "pack" in x or "lang" in x or "status" in x))
    grp = f"({pack} is not null)" if pack else "false"
    for r in await c.fetch(f"select coalesce(language,'?') lang, {grp} is_pack, review_status, count(*) n from questions group by 1,2,3 order by 1,2,3"):
        print("Q", r["lang"], "pack" if r["is_pack"] else "corpus", r["review_status"], r["n"])
    for r in await c.fetch(f"select t.language, {grp.replace(pack or 'x', 'q.'+(pack or 'x'))} is_pack, t.status, count(*) n from question_translations t join questions q on q.id=t.question_id group by 1,2,3 order by 1,2,3"):
        print("T", r["language"], "pack" if r["is_pack"] else "corpus", r["status"], r["n"])
    await c.close()
asyncio.run(main())
EOF
