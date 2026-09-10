#!/usr/bin/env zsh
# #168 — re-gate rejected answerability flips with Sonnet via subscription.
# Mirrors docs/testing/runs/translation-corpus-2026-09-10/run_corpus.sh (env + transport).
set -u
ROOT="$1"; LOG="$2"; mkdir -p "$LOG"
APP="$ROOT/apps/quiz-pack-api"
PY="/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python"
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source "/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env"; set +a
export LLM_GATEWAY=session
cd "$APP" || exit 1
for L in sk cs; do
  echo "=== $(date '+%F %T') $L reverify ===" | tee -a "$LOG/reverify-$L.log"
  "$PY" scripts/translate_corpus.py --database-url "$PROD_DATABASE_URL" verify --language $L \
    --status rejected --only-answerability-flips --answerability-model claude-sonnet-5 \
    --limit 60 --confirm --concurrency 4 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$" | tee -a "$LOG/reverify-$L.log"
  echo "rc=${pipestatus[1]}" | tee -a "$LOG/reverify-$L.log"
done
echo ALL-DONE
