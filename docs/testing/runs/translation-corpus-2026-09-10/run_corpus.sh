#!/usr/bin/env zsh
# #168 Session M+N — translate + verify the whole eligible EN corpus into sk and
# cs on the Claude Code subscription (LLM_GATEWAY=session), resumable.
#
# Loop per language until `plan` reports 0 rows left and `verify` finds no
# pending rows. A failed step (quota exhausted, provider hiccup) sleeps and
# retries: submit resumes from the job JSONL, verify re-selects pending rows.
#
# Usage: run_corpus.sh <worktree-root> <log-dir>
set -u
ROOT="$1"; LOG="$2"; mkdir -p "$LOG"
APP="$ROOT/apps/quiz-pack-api"
PY="/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python"
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source "$ROOT/.env"; set +a
export LLM_GATEWAY=session
cd "$APP" || exit 1

run() { "$PY" scripts/translate_corpus.py --database-url "$PROD_DATABASE_URL" "$@" 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$"; return ${pipestatus[1]}; }

for LANG_CODE in sk cs; do
  JOB="$LANG_CODE-full-20260910"
  for attempt in $(seq 1 12); do
    echo "=== $(date '+%F %T') $LANG_CODE attempt $attempt: submit ===" | tee -a "$LOG/$LANG_CODE.log"
    run submit --language $LANG_CODE --limit 400 --confirm --job-id "$JOB" --concurrency 4 >> "$LOG/$LANG_CODE.log" 2>&1
    rc=$?
    run ingest --job-id "$JOB" >> "$LOG/$LANG_CODE.log" 2>&1
    left=$(run plan --language $LANG_CODE | grep -o '[0-9]* row(s) to translate' | grep -o '^[0-9]*')
    echo "$(date '+%F %T') $LANG_CODE submit rc=$rc, rows left to translate: ${left:-?}" | tee -a "$LOG/$LANG_CODE.log"
    echo "=== $(date '+%F %T') $LANG_CODE attempt $attempt: verify ===" | tee -a "$LOG/$LANG_CODE.log"
    run verify --language $LANG_CODE --limit 500 --confirm --concurrency 4 >> "$LOG/$LANG_CODE.log" 2>&1
    vrc=$?
    pending=$(run verify --language $LANG_CODE --limit 1 --confirm 2>/dev/null | grep -c "no pending rows")
    if [[ "${left:-1}" == "0" && "$pending" == "1" && $vrc -eq 0 ]]; then
      echo "$(date '+%F %T') $LANG_CODE DONE" | tee -a "$LOG/$LANG_CODE.log"
      break
    fi
    echo "$(date '+%F %T') $LANG_CODE not finished (left=${left:-?}, verify rc=$vrc) — sleeping 15 min" | tee -a "$LOG/$LANG_CODE.log"
    sleep 900
  done
  run report --coverage --language $LANG_CODE > "$LOG/$LANG_CODE.coverage.txt" 2>&1
  run reconcile --language $LANG_CODE > "$LOG/$LANG_CODE.reconcile.txt" 2>&1
  run review-export --language $LANG_CODE --out "$LOG/$LANG_CODE-review.json" >> "$LOG/$LANG_CODE.log" 2>&1
done
echo "=== $(date '+%F %T') ALL DONE ===" | tee -a "$LOG/run.log"
