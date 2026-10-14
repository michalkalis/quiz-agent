#!/usr/bin/env zsh
# #202 first live top-up (2026-10-14): founder "spusti ostrý beh, ale cez subscription".
# Local run on the Claude Code subscription (FRESH_TOPUP_SESSION=1), prod DB over a fly proxy tunnel.
# Seeds and the web fact-check still use the Anthropic API (server-side search tools).
set -u
RUN=${0:A:h}; WT=${RUN:h:h:h:h}
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"
export DATABASE_URL="$DB?sslmode=disable" FRESH_TOPUP_SESSION=1
nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 & sleep 8; }
cd $WT/apps/quiz-pack-api && $WT/.venv/bin/python -m app.corpus.run_fresh_topup --languages "${1:-en,sk,cs}" --count "${2:-15}" --max-usd 15 > $RUN/run.out 2> $RUN/run.log
echo "rc=$?" >> $RUN/run.log
