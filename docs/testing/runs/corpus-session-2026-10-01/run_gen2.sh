#!/usr/bin/env zsh
# Round 2 (founder 2026-10-01: "generuj a prekladaj toľko otázok, aby týždenný limit ostal 15 %"): eight more
# batches of 15, same flow as run_gen.sh; starts once round 1 logs DONE so only one generation job runs at a time.
set -u
ROOT=/Users/agent/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-10-01
API=$ROOT/apps/quiz-pack-api
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
until grep -q "^DONE" $RUN/run.log 2>/dev/null; do sleep 30; done
SPECS=(
  "09|Music, instruments and famous musicians"
  "10|Oceans, rivers, lakes and the water world"
  "11|Mathematics, numbers and puzzles"
  "12|Languages, alphabets and writing systems"
  "13|Transport: cars, trains, ships and planes"
  "14|Myths, legends, religion and folklore"
  "15|Fashion, clothing and design through history"
  "16|Toys, games, hobbies and childhood"
)
for spec in $SPECS; do
  i=${spec%%|*}; theme=${spec#*|}
  [[ -s $RUN/batch-$i.json ]] && { echo "skip batch-$i (exists)" >> $RUN/run2.log; continue; }
  [[ -f $RUN/STOP ]] && { echo "STOP file → halt before batch-$i" >> $RUN/run2.log; break; }
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
  echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run2.log
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 15 --language en \
     --theme "$theme" --per-topic-cap 15 ${=dedup} --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
  rc=$?
  echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run2.log
  if [ $rc -ne 0 ] && grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|429|529" $RUN/batch-$i.log; then
    echo "QUOTA on batch-$i → stop" >> $RUN/run2.log; break
  fi
done
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run2.log
