#!/usr/bin/env zsh
# #231.4: import merged-uk.json into prod (Hetzner, via SSH tunnel). uk is not served yet.
set -u
RUN=${0:A:h}; WT=/Users/agent/code/qa-231-corpus; MAIN=/Users/agent/code/quiz-agent
set -a; source $MAIN/.env; set +a
export NATURALNESS_CHECK=1 PYTHONPATH=$WT/apps/quiz-pack-api:$WT/packages/shared
DB="$(echo "${PROD_DATABASE_URL%%\?*}" | sed -E 's#@[^/]+/#@localhost:15432/#')?sslmode=disable"
nc -z localhost 15432 2>/dev/null || { nohup ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L 15432:127.0.0.1:5432 trubbo-prod > $RUN/tunnel.log 2>&1 & sleep 6; }
cd $WT/apps/quiz-pack-api && $MAIN/.venv/bin/python scripts/import_questions_json.py \
  --json-path $RUN/merged-uk.json --database-url "$DB" $1 2>&1 | grep -v "Pydantic\|BaseModel"
