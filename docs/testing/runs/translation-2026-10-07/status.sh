#!/usr/bin/env zsh
# Read-only (2026-10-07, founder-authorised): sk/cs translation plan in prod — rows still to translate.
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
APP=$ROOT/../quiz-agent-wt-tr1007/apps/quiz-pack-api
RUN=$ROOT/docs/testing/runs/translation-2026-10-07
set -a; source $ROOT/.env; set +a
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
DB="${PROD_DATABASE_URL%%\?*}"; DB="${DB/quiz-pack-db.flycast:5432/localhost:15432}"; DB="${DB/quiz-pack-db.internal:5432/localhost:15432}"; DB="$DB?sslmode=disable"
cd "$APP" || exit 1
export PYTHONPATH="$ROOT/packages/shared:$APP"
for L in sk cs; do
  echo "== plan $L"; $ROOT/.venv/bin/python scripts/translate_corpus.py --database-url "$DB" plan --language $L 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$" | tail -12
  echo "== structure-fix plan $L"; $ROOT/.venv/bin/python scripts/question_structure_fix.py plan --language $L --database-url "$DB" 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$" | tail -8
done
