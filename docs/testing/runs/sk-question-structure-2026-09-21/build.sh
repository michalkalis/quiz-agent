#!/usr/bin/env zsh
# Blind test of the question-structure rule (founder 2026-09-21): sample 20 approved
# translations from prod (read-only), build arms retranslate / rewrite + hidden original.
# Usage: build.sh <sk|cs>
set -u
LANG_CODE="${1:-sk}"
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.claude/worktrees/sk-question-structure
RUN=$ROOT/docs/testing/runs/sk-question-structure-2026-09-21
APP=$ROOT/apps/quiz-pack-api
PY=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source $ROOT/.env; set +a
# Same transport as the 2026-09-17 corpus batch (Opus on the subscription, no API credit).
export LLM_GATEWAY=session
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
cd "$APP" || exit 1
"$PY" scripts/question_structure_arms.py build --language "$LANG_CODE" --n 20 --controls 5 --seed 2026 \
  --out-dir "$RUN" --database-url "$DB" 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$" | tee -a $RUN/build-$LANG_CODE.log
exit ${pipestatus[1]}
