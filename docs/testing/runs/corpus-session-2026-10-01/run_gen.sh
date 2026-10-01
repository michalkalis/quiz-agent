#!/usr/bin/env zsh
# Founder 2026-10-01: "Vygeneruj 100 nových anglických otázok a prelož 100 do češtiny a slovenčiny" — phase 1: generation.
# Eight batches of 15 EN questions on the Claude Code subscription (LLM_GATEWAY=session), --dry-run only
# (JSON on disk, NO database writes). Dedup against the prod corpus via the fly proxy tunnel on :15432
# (PROD_DATABASE_URL on mba is already the localhost:15432 form). Import + translation = run_import_translate.sh.
set -u
ROOT=/Users/agent/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-10-01
API=$ROOT/apps/quiz-pack-api
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
SPECS=(
  "01|History, empires and famous people"
  "02|Sports, games and Olympic records"
  "03|Geography, countries, cities and landmarks"
  "04|Human body, health and medicine"
  "05|Technology, computers and the internet"
  "06|Art, literature, books and architecture"
  "07|Food, drink and cooking around the world"
  "08|Science, chemistry and physics in everyday life"
)
for spec in $SPECS; do
  i=${spec%%|*}; theme=${spec#*|}
  [[ -s $RUN/batch-$i.json ]] && { echo "skip batch-$i (exists)" >> $RUN/run.log; continue; }
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
