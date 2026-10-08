#!/usr/bin/env zsh
# Import merged native sk/cs JSON into prod (founder approved prod read+write 2026-10-08).
# Usage: run_import.sh --dry-run|--execute
set -u
WT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent-wt-native
RUN=$WT/docs/testing/runs/native-sk-cs-2026-10-08
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 & sleep 8; }
cd $WT/apps/quiz-pack-api && $WT/.venv/bin/python scripts/import_questions_json.py \
  --json-path $RUN/merged-sk.json --json-path $RUN/merged-cs.json --database-url "$DB" $1 2>&1 | grep -v "Pydantic\|BaseModel"
