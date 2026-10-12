#!/usr/bin/env zsh
# #199 top-up — covered answers from prod, classify topicality, import the curated fresh EN batch, translate to sk/cs.
# Usage: run_import.sh covered | classify | import --dry-run|--execute | translate <plan|submit|ingest|verify> <sk|cs> [job-id]
set -u
RUN=${0:A:h}; WT=${RUN:h:h:h:h}
PY=$WT/.venv/bin/python; APP=$WT/apps/quiz-pack-api
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
tunnel() { nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 & sleep 8; }; }
cd $APP
case $1 in
  covered)  # read-only: entertainment rows already in prod (en + native sk/cs) → prod-entertainment.json + covered-fresh.txt
    tunnel; $PY $RUN/covered.py --database-url "$DB" --out $RUN/covered-fresh.txt --json $RUN/prod-entertainment.json ;;
  classify)  # subscription only, no DB
    $PY scripts/classify_topicality.py --json-path $RUN/merged-en.json --out $RUN/boosted.json ;;
  import)
    tunnel; $PY scripts/import_questions_json.py --json-path $RUN/boosted.json --database-url "$DB" $2 2>&1 | grep -v "Pydantic\|BaseModel" ;;
  translate)
    tunnel; step=$2; lang=$3
    case $step in
      plan)   $PY scripts/translate_corpus.py --database-url "$DB" plan --language $lang ;;
      submit) $PY scripts/translate_corpus.py --database-url "$DB" submit --language $lang --limit 50 --confirm ;;
      ingest) $PY scripts/translate_corpus.py --database-url "$DB" ingest --job-id $4 ;;
      verify) $PY scripts/translate_corpus.py --database-url "$DB" verify --language $lang --limit 50 --confirm ;;
    esac ;;
esac
