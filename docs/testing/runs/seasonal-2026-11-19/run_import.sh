#!/usr/bin/env zsh
# Import the reviewed seasonal questions into prod (Hetzner, via SSH tunnel).
# sk/cs/en go in as approved after the independent review, like the Christmas set (#241).
# Usage: run_import.sh --dry-run | --execute
set -u
RUN=${0:A:h}; WT=${RUN:h:h:h:h}; MAIN=/Users/agent/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=session NATURALNESS_CHECK=1 PYTHONPATH=$WT/apps/quiz-pack-api:$WT/packages/shared
DB="$(echo "${PROD_DATABASE_URL%%\?*}" | sed -E 's#@[^/]+/#@localhost:15432/#')?sslmode=disable"
nc -z localhost 15432 2>/dev/null || { nohup ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L 15432:127.0.0.1:5432 trubbo-prod > $RUN/tunnel.log 2>&1 & sleep 6; }
cd $WT/apps/quiz-pack-api && $MAIN/.venv/bin/python scripts/import_questions_json.py \
  --json-path $RUN/merged-sk.json --json-path $RUN/merged-cs.json --json-path $RUN/merged-en.json \
  --review-status approved --database-url "$DB" $1 2>&1 | grep -v "Pydantic\|BaseModel"
