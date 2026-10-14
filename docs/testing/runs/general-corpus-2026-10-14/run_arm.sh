#!/usr/bin/env zsh
# #203 full run (founder 2026-10-14): half hand-written themes (H), half model-brainstormed themes (M), 2 questions per theme.
# 37 + 37 themes per language = ~148 new questions; with the pilot questions (general-pilot + topics-pilot) ~200 per language.
# Usage: GATEWAY=session run_arm.sh <arm> <en|sk|cs> <key in themes_full.json>. Same prod-parity pins as general-pilot-2026-10-14.
# Stops on a subscription-limit error; rerun with the same args to resume (finished themes are skipped). Needs `fly proxy 15432:5432 -a quiz-pack-db`.
set -u
ARM=$1; LANG_=$2; KEY=$3
RUN=${0:A:h}; API=$RUN/../../../../apps/quiz-pack-api
MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}  # repo with .env and .venv (laptop worktrees: QUIZ_MAIN=<main checkout>)
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=${GATEWAY:-direct} LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$API/../../packages/shared
if [ $LANG_ = sk ] || [ $LANG_ = cs ]; then
  if [ $LANG_ = sk ]; then country=Slovakia; people=Slovaks; tongue=Slovak; else country=Czechia; people=Czechs; tongue=Czech; fi
  brief="$(cat $RUN/taste_brief.txt)

The players live in $country and play in $tongue. At least 7 of every 10 questions must be about $country or things $people meet in everyday life (food, places, language, customs, shops, school, history told from their perspective); the rest may be world topics that would delight them."
else brief="$(cat $RUN/taste_brief.txt)"; fi
THEMES=("${(@f)$(python3 -c "import json,sys; print('\n'.join(json.load(open('$RUN/themes_full.json'))['$KEY']))")}")
i=0
for theme in $THEMES; do
  i=$((i+1)); [ -s $RUN/$ARM-$i.json ] && continue
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --direct --dry-run --target-count 2 --language $LANG_ \
     --theme "$theme" --prompt "$brief" --per-topic-cap 2 --no-judges --floor-fraction 0 --dedup-store pgvector --out $RUN/$ARM-$i.json) > $RUN/$ARM-$i.log 2>&1
  echo "$ARM-$i rc=$? $(grep -E '^questions:' $RUN/$ARM-$i.log)" >> $RUN/run.log
  if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit| 429| 529" $RUN/$ARM-$i.log; then
    echo "QUOTA on $ARM-$i → stop" >> $RUN/run.log; rm -f $RUN/$ARM-$i.json; break
  fi
done
echo "$ARM DONE" >> $RUN/run.log
