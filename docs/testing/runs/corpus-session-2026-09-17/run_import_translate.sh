#!/usr/bin/env zsh
# Phase 2 (founder 2026-09-17): import the merged batch into prod (auto review status, #177) and translate
# the new EN rows into sk + cs on the subscription (#168 runner, answerability = Sonnet per founder 09-10).
# Usage: run_import_translate.sh <merged.json>
set -u
MERGED="$1"
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-17
APP=$ROOT/apps/quiz-pack-api
PY=$ROOT/.venv/bin/python
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
# Laptop path: prod URL points at the Fly-private host; go through the proxy tunnel without TLS (the proxy is plain TCP).
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
cd "$APP" || exit 1
log() { echo "$(date '+%F %T') $*" | tee -a $RUN/phase2.log; }
run() { "$PY" scripts/translate_corpus.py --database-url "$DB" "$@" 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$"; return ${pipestatus[1]}; }

if [[ -n "${SKIP_IMPORT:-}" ]]; then log "import skipped (SKIP_IMPORT)"; else
log "import start $MERGED"
"$PY" scripts/import_questions_json.py --json-path "$MERGED" --database-url "$DB" --execute 2>&1 | grep -v "Pydantic\|BaseModel" | tee -a $RUN/import.log
log "import rc=${pipestatus[1]}"
fi

for L in sk cs; do
  JOB="$L-20260917"
  log "$L plan: $(run plan --language $L | grep -o '[0-9]* row(s) to translate')"
  for attempt in 1 2 3; do
    run submit --language $L --limit 200 --confirm --job-id "$JOB" --concurrency 4 >> $RUN/translate-$L.log 2>&1
    log "$L submit attempt $attempt rc=$?"
    run ingest --job-id "$JOB" >> $RUN/translate-$L.log 2>&1
    left=$(run plan --language $L | grep -o '[0-9]* row(s) to translate' | grep -o '^[0-9]*')
    run verify --language $L --limit 200 --confirm --concurrency 4 --answerability-model claude-sonnet-5 >> $RUN/translate-$L.log 2>&1
    vrc=$?
    pending=$(run verify --language $L --limit 1 --confirm --answerability-model claude-sonnet-5 2>/dev/null | grep -c "no pending rows")
    log "$L left=${left:-?} verify rc=$vrc pending_clear=$pending"
    if [[ "${left:-1}" == "0" && "$pending" == "1" && $vrc -eq 0 ]]; then log "$L DONE"; break; fi
    log "$L not finished — sleeping 2 min"; sleep 120
  done
  run reconcile --language $L > $RUN/$L.reconcile.txt 2>&1
  run review-export --language $L --sample 0 --out $RUN/$L-review.json >> $RUN/translate-$L.log 2>&1
done
log "ALL DONE"
