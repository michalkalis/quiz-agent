#!/usr/bin/env zsh
# Top-up batch (2026-09-17): 7 rows dropped as prod/intra duplicates → one more batch of 10 to reach ≥ 40.
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-17
API=$ROOT/apps/quiz-pack-api
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
if ! nc -z localhost 15432 2>/dev/null; then
  env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db > $RUN/tunnel.log 2>&1 &
  sleep 8
fi
i=04; theme="Money, brands, business and famous companies"
if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; fi
echo "start batch-$i $(date '+%H:%M:%S') theme=$theme $dedup" >> $RUN/run.log
(cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run --target-count 10 --language en \
   --theme "$theme" --per-topic-cap 10 ${=dedup} --out $RUN/batch-$i.json) > $RUN/batch-$i.log 2>&1
rc=$?
echo "rc=$rc end batch-$i $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/batch-$i.log)" >> $RUN/run.log
echo "DONE $(date '+%H:%M:%S')" >> $RUN/run.log
