#!/usr/bin/env zsh
# #203.5 blind A/B: old v2_cot prompt (9.15 founder batch, 09-03) vs direct_v1 (10-01 bulk, ~2/10).
# Same model (Opus 5.5 pinned, no GEN_ALT mix), same themes from the 10-01 run, --dry-run (no DB writes),
# dedup against prod via the fly proxy on :15432. Usage: run_arm.sh <arm> <GEN_PROMPT_VERSION>
set -u
ARM=$1; PV=$2
RUN=${0:A:h}; API=$RUN/../../../../apps/quiz-pack-api
MAIN=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=direct GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 GEN_PROMPT_VERSION=$PV
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$API/../../packages/shared
THEMES=(
  "History, empires and famous people"
  "Science, chemistry and physics in everyday life"
  "Geography, countries, cities and landmarks"
  "Food, drink and cooking around the world"
)
i=0
for theme in $THEMES; do
  i=$((i+1))
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --dry-run --target-count 6 --language en \
     --theme "$theme" --per-topic-cap 6 --dedup-store pgvector --out $RUN/$ARM-$i.json) > $RUN/$ARM-$i.log 2>&1
  echo "$ARM-$i rc=$? $(grep -E '^questions:' $RUN/$ARM-$i.log)" >> $RUN/run.log
done
echo "$ARM DONE" >> $RUN/run.log
