#!/usr/bin/env zsh
# #203.6 blind test: founder-taste brief (en / native sk) vs the 10-08 native sk brief.
# Usage: run_arm.sh <arm> <lang> <brief-file|native>. Same prod-parity pins as prompt-ab-2026-10-14.
set -u
ARM=$1; LANG_=$2; BRIEF=$3
RUN=${0:A:h}; API=$RUN/../../../../apps/quiz-pack-api
MAIN=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=direct LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$API/../../packages/shared
# 10-08 native recipe (docs/testing/runs/native-sk-cs-2026-10-08/run_gen.sh), sk only.
NATIVE="Corpus questions for adults who live in Slovakia and play in their own language. Every question must be specific to Slovakia: something Slovaks know from school, news, travel or everyday life, or would enjoy learning about their own country. Shared Czechoslovak history and culture is welcome, told from the perspective of Slovaks. Do not ask about facts that are equally known worldwide, and do not ask obscure trivia that only specialists know. Do not ask about Czech-only topics."
if [ $BRIEF = native ]; then brief=$NATIVE
elif [ $LANG_ = sk ]; then brief="$(cat $RUN/$BRIEF)

The players live in Slovakia and play in Slovak. At least 7 of every 10 questions must be about Slovakia or things Slovaks meet in everyday life (food, places, language, customs, shops, school, history told from their perspective); the rest may be world topics that would delight them."
else brief="$(cat $RUN/$BRIEF)"; fi
THEMES=(
  "History, empires and famous people"
  "Science, chemistry and physics in everyday life"
  "Geography, countries, cities and landmarks"
  "Food, drink and cooking around the world"
)
i=0
for theme in $THEMES; do
  i=$((i+1))
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --direct --dry-run --target-count 4 --language $LANG_ \
     --theme "$theme" --prompt "$brief" --per-topic-cap 4 --no-judges --dedup-store pgvector --out $RUN/$ARM-$i.json) > $RUN/$ARM-$i.log 2>&1
  echo "$ARM-$i rc=$? $(grep -E '^questions:' $RUN/$ARM-$i.log)" >> $RUN/run.log
done
echo "$ARM DONE" >> $RUN/run.log
