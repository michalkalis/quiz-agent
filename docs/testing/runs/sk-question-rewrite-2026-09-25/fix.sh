#!/usr/bin/env zsh
# Question-structure fix (arm B) on stored translations, founder 2026-09-25.
# Usage: fix.sh plan|mark <sk|cs>   ·   fix.sh rewrite <sk|cs> <N>
set -u
CMD="$1"; LANG_CODE="${2:-sk}"; N="${3:-50}"
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.claude/worktrees/sk-question-structure
RUN=$ROOT/docs/testing/runs/sk-question-rewrite-2026-09-25
APP=$ROOT/apps/quiz-pack-api
PY=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
cd "$APP" || exit 1
EXTRA=()
if [[ "$CMD" == rewrite ]]; then
  EXTRA=(--n "$N" --out "$RUN/rewrite-$LANG_CODE.json" --usage-out "$RUN/usage-$LANG_CODE.json")
fi
"$PY" -u scripts/question_structure_fix.py "$CMD" --language "$LANG_CODE" --database-url "$DB" "${EXTRA[@]}" 2>&1 \
  | grep -v "Pydantic\|BaseModel\|^\s*$" | tee -a $RUN/$CMD-$LANG_CODE.log
exit ${pipestatus[1]}
