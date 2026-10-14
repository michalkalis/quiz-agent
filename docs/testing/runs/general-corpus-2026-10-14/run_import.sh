#!/usr/bin/env zsh
# #203: import merged-{en,sk,cs}.json into prod (founder-authorized prod writes for this flow, 2026-10-14).
# Usage: run_import.sh --dry-run|--execute   (default --review-status auto)
set -u
RUN=${0:A:h}; MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}
set -a; source $MAIN/.env; set +a
DB="$(echo "${PROD_DATABASE_URL%%\?*}" | sed -E 's#@[^/]+/#@localhost:15432/#')?sslmode=disable"  # via the fly tunnel
nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 & sleep 8; }
cd $MAIN/apps/quiz-pack-api && $MAIN/.venv/bin/python scripts/import_questions_json.py \
  --json-path $RUN/merged-en.json --json-path $RUN/merged-sk.json --json-path $RUN/merged-cs.json --database-url "$DB" $1 2>&1 | grep -v "Pydantic\|BaseModel"
