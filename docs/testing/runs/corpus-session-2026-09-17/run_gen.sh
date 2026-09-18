#!/usr/bin/env zsh
# Founder 2026-09-17: "vygeneruj 40 novych otazok a preloz co najviac do cz aj sk" — phase 1: generation.
# Three batches of 15 EN questions on the Claude Code subscription (LLM_GATEWAY=session), --dry-run only
# (JSON on disk, NO database writes). Dedup against the prod corpus via the fly proxy tunnel (started here
# if down; falls back to noop). Import + translation = run_import_translate.sh (phase 2).
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-17
API=$ROOT/apps/quiz-pack-api
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
if ! nc -z localhost 15432 2>/dev/null; then
  # .env FLY_API_TOKEN is app-scoped (quiz-agent-api) and cannot see quiz-pack-db → use the founder login.
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
for spec in "01|Movies, music and pop culture" "02|Nature, weather and planet Earth" "03|Everyday objects, words and language"; do
  i=${spec%%|*}; theme=${spec#*|}
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
  echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run.log
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 15 --language en \
     --theme "$theme" --per-topic-cap 15 ${=dedup} --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
  rc=$?
  echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run.log
  if [ $rc -ne 0 ] && grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|429|529" $RUN/batch-$i.log; then
    echo "QUOTA on batch-$i → stop" >> $RUN/run.log; break
  fi
done
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run.log
