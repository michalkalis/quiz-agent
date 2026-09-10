#!/usr/bin/env bash
# Two batches of 15 target EN questions on the Claude Code subscription (#169), founder cap 2026-09-10: <= 35 % of the 5h window.
# --dry-run only: JSON on disk, NO database writes. Dedup against prod corpus via the fly proxy tunnel (falls back to noop).
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-09
API=$ROOT/apps/quiz-pack-api
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
for spec in "02|Inventions and everyday objects" "03|Animals and their abilities"; do
  i=${spec%%|*}; theme=${spec#*|}
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
  echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run.log
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 15 --language en \
     --theme "$theme" --per-topic-cap 15 $dedup --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
  rc=$?
  echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run.log
  if [ $rc -ne 0 ] && grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|429|529" $RUN/batch-$i.log; then
    echo "QUOTA on batch-$i → stop" >> $RUN/run.log; break
  fi
done
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run.log
