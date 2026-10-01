#!/usr/bin/env zsh
# Round 3+ (founder 2026-10-01: scale generation + translation to the weekly subscription limit, keep 15 %
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
until grep -q "^DONE" $RUN/run2.log 2>/dev/null; do sleep 30; done
SPECS=(
  "17|Plants, trees and flowers"
  "18|Money, coins, banks and economics"
  "19|Famous inventors and accidental discoveries"
  "20|Television, series and famous TV moments"
  "21|Holidays, festivals and traditions around the world"
  "22|Buildings, bridges and engineering marvels"
  "23|Insects, spiders and tiny creatures"
  "24|Natural disasters and extreme weather"
  "25|Famous explorers and voyages of discovery"
  "26|Birds and flight"
  "27|Chemistry of the kitchen and household"
  "28|Ancient Egypt, Greece and Rome"
  "29|Medieval castles, knights and kings"
  "30|World wars and the 20th century"
  "31|Dinosaurs, fossils and prehistoric life"
  "32|The Olympic Games and the football World Cup"
  "33|Video games, consoles and arcades"
  "34|Comics, superheroes and animation"
  "35|Famous paintings, sculptors and museums"
  "36|Deserts, mountains and volcanoes"
  "37|Pets: dogs, cats and domestic animals"
  "38|Drinks: coffee, tea, wine and beer"
  "39|Sleep, dreams, the brain and the senses"
  "40|Flags, anthems, capitals and national symbols"
)
for spec in $SPECS; do
  i=${spec%%|*}; theme=${spec#*|}
  [[ -s $RUN/batch-$i.json ]] && { echo "skip batch-$i (exists)" >> $RUN/run3.log; continue; }
  [[ -f $RUN/STOP ]] && { echo "STOP file → halt before batch-$i" >> $RUN/run3.log; break; }
  [[ $(date '+%H%M') -ge $DEADLINE ]] && { echo "DEADLINE $DEADLINE → halt before batch-$i" >> $RUN/run3.log; break; }
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
  echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run3.log
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 15 --language en \
     --theme "$theme" --per-topic-cap 15 ${=dedup} --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
  rc=$?
  echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run3.log
  if [ $rc -ne 0 ] && grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|429|529" $RUN/batch-$i.log; then
    echo "QUOTA on batch-$i → stop" >> $RUN/run3.log; break
  fi
done
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run3.log
