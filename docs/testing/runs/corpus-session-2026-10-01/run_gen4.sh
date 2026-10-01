#!/usr/bin/env zsh
# Round 4 (founder 2026-10-01: scale generation + translation to the weekly subscription limit, keep 15 %
# headroom). Same flow as run_gen.sh; chained after round 2 (run2.log DONE). Halts on a STOP file, on a quota
# error, or when the clock passes DEADLINE (local) so the sk/cs translation of the last round finishes before
# the weekly reset at 12:00 CEST — work after the reset would land on the fresh week's limit.
set -u
ROOT=/Users/agent/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-10-01
API=$ROOT/apps/quiz-pack-api
DEADLINE=1100
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
until grep -q "^DONE" $RUN/run3.log 2>/dev/null; do sleep 30; done
SPECS=(
  "41|Famous scientists and Nobel Prizes"
  "42|Rivers, bridges and famous cities of Europe"
  "43|Asia: countries, cultures and landmarks"
  "44|Africa: countries, wildlife and history"
  "45|The Americas: countries, history and landmarks"
  "46|Australia, Oceania and the Pacific"
  "47|Robots, AI and the future of technology"
  "48|Photography, cameras and cinema technology"
  "49|Dance, theatre and the performing arts"
  "50|Famous speeches, quotes and misquotes"
  "51|Shipwrecks, pirates and the high seas"
  "52|Trains, railways and famous journeys"
  "53|Chess, cards, board games and gambling"
  "54|Marine mammals, sharks and deep-sea life"
  "55|Reptiles, amphibians and strange animals"
  "56|The human mind: memory, illusions and psychology"
  "57|Measurements, units and calendars"
  "58|Supermarket science: packaging, labels and shopping"
  "59|Famous women in history and science"
  "60|Kings, queens and royal families"
  "61|Cold War, space race and spies"
  "62|Marathons, cycling and endurance sports"
  "63|Tennis, golf and racket sports"
  "64|Famous hoaxes, mistakes and accidents in history"
)
for spec in $SPECS; do
  i=${spec%%|*}; theme=${spec#*|}
  [[ -s $RUN/batch-$i.json ]] && { echo "skip batch-$i (exists)" >> $RUN/run4.log; continue; }
  [[ -f $RUN/STOP ]] && { echo "STOP file → halt before batch-$i" >> $RUN/run4.log; break; }
  while [[ -f $RUN/PAUSE ]]; do sleep 60; done   # 5-hour window exhausted → wait for its reset (guard.sh)
  [[ $(date '+%H%M') -ge $DEADLINE ]] && { echo "DEADLINE $DEADLINE → halt before batch-$i" >> $RUN/run4.log; break; }
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
  echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run4.log
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 15 --language en \
     --theme "$theme" --per-topic-cap 15 ${=dedup} --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
  rc=$?
  echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run4.log
  if [ $rc -ne 0 ] && grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|429|529" $RUN/batch-$i.log; then
    echo "QUOTA on batch-$i → stop" >> $RUN/run4.log; break
  fi
done
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run4.log
