#!/usr/bin/env zsh
# #203 full run pre-flight: run FIRST on the machine that will generate (mba), inside the gui-domain tmux.
# Checks everything the run needs that git and the sync gist cannot carry. Prints OK/FAIL per item; fix all FAILs
# with the founder in one go before starting, so the run does not stop halfway. Secrets are never printed.
set -u
RUN=${0:A:h}; MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}; API=$MAIN/apps/quiz-pack-api
ok() { echo "OK   $1"; }; bad() { echo "FAIL $1"; }
cd $MAIN
git fetch -q && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && ok "repo = origin/main" || bad "repo not at origin/main (git pull --ff-only)"
for k in PROD_DATABASE_URL OPENAI_API_KEY TAVILY_API_KEY; do grep -q "^$k=." .env && ok ".env has $k" || bad ".env missing $k"; done
[ -f $API/.env ] && { grep -q '^PROD_DATABASE_URL=.' $API/.env && ok "apps/quiz-pack-api/.env has PROD_DATABASE_URL (it shadows the root .env)" || bad "apps/quiz-pack-api/.env lacks PROD_DATABASE_URL"; }
[ -x .venv/bin/python ] && .venv/bin/python -c "import quiz_shared, asyncpg, langchain_core" 2>/dev/null && ok "venv imports" || bad "venv (uv pip install -e apps/quiz-agent -e apps/quiz-pack-api -e packages/shared)"
r=$(echo "Reply with the single word READY" | env -u ANTHROPIC_API_KEY claude -p --model opus --max-turns 1 --no-session-persistence --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools "" 2>&1 | tail -1)
[[ $r == *READY* ]] && ok "claude subscription login + Opus" || bad "claude -p on the subscription: $r"
gh auth status >/dev/null 2>&1 && ok "gh auth" || bad "gh auth (run inside tmux; gh auth login)"
nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 & sleep 10; }
nc -z localhost 15432 2>/dev/null && ok "fly proxy :15432" || bad "fly proxy (fly auth login; see $RUN/tunnel.log)"
set -a; source .env; set +a
.venv/bin/python - <<'PY' && ok "prod DB read" || bad "prod DB read via tunnel"
import os, re, asyncio, asyncpg
db = re.sub(r'@[^/]+/', '@localhost:15432/', os.environ['PROD_DATABASE_URL']).split('?')[0].replace('+asyncpg', '')
async def m():
    c = await asyncpg.connect(db, ssl=False)
    n = await c.fetchval("select count(*) from questions where review_status='approved'")
    assert n > 0
asyncio.run(m())
PY
PYTHONPATH=$MAIN/packages/shared .venv/bin/python -c "
import asyncio; from quiz_shared.utils.embeddings import generate_embedding_async
assert len(asyncio.run(generate_embedding_async('ping'))) > 100" 2>/dev/null && ok "OpenAI embeddings (dedup)" || bad "OpenAI embeddings: OPENAI_API_KEY invalid?"
pmset -g 2>/dev/null | grep -E '^ *sleep ' | grep -q ' 0' && ok "system sleep off" || echo "WARN system sleep may be on (pmset -g)"
