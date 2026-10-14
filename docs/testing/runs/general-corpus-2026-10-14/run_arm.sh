#!/usr/bin/env zsh
# #203 general corpus full run: founder-taste brief, 45 narrow everyday themes x 4 = 180 per language (+ the 20 pilot questions = 200).
# Stops on a subscription-limit error; rerun with the same args to resume (finished themes are skipped).
# Usage: [GATEWAY=session] run_arm.sh <arm> <en|sk|cs> <brief-file|native> [theme-index]. A theme index reruns that one theme. Same prod-parity pins as prompt-ab-2026-10-14.
# GATEWAY=session runs on the Claude Code subscription (Opus 5.5 via the opus alias); default = direct Anthropic API.
set -u
ARM=$1; LANG_=$2; BRIEF=$3; ONLY=${4:-}
RUN=${0:A:h}; API=$RUN/../../../../apps/quiz-pack-api
MAIN=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=${GATEWAY:-direct} LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$API/../../packages/shared
# 10-08 native recipe (docs/testing/runs/native-sk-cs-2026-10-08/run_gen.sh), sk only.
NATIVE="Corpus questions for adults who live in Slovakia and play in their own language. Every question must be specific to Slovakia: something Slovaks know from school, news, travel or everyday life, or would enjoy learning about their own country. Shared Czechoslovak history and culture is welcome, told from the perspective of Slovaks. Do not ask about facts that are equally known worldwide, and do not ask obscure trivia that only specialists know. Do not ask about Czech-only topics."
if [ $BRIEF = native ]; then brief=$NATIVE
elif [ $LANG_ = sk ] || [ $LANG_ = cs ]; then
  if [ $LANG_ = sk ]; then country=Slovakia; people=Slovaks; tongue=Slovak; else country=Czechia; people=Czechs; tongue=Czech; fi
  brief="$(cat $RUN/$BRIEF)

The players live in $country and play in $tongue. At least 7 of every 10 questions must be about $country or things $people meet in everyday life (food, places, language, customs, shops, school, history told from their perspective); the rest may be world topics that would delight them."
else brief="$(cat $RUN/$BRIEF)"; fi
THEMES=(
  "Why food goes off, keeps or ripens"
  "Baking and bread puzzles"
  "Spices and herbs and where they came from"
  "Coffee, tea and soft drink surprises"
  "Fruit and vegetables that are not what they seem"
  "Sweets and chocolate secrets"
  "Words borrowed from other languages"
  "Brand and product names with a story"
  "Place names with a surprising meaning"
  "Everyday sayings and where they come from"
  "First names and surnames and what they mean"
  "Hidden design details in everyday objects"
  "Why clothes and fashion items look the way they do"
  "Inventions that started out as something else"
  "Accidental discoveries"
  "Famous landmarks with a twist"
  "Famous paintings and statues with a twist"
  "Famous songs and films with a surprising backstory"
  "Musical instruments and sounds"
  "Things everybody believes that are wrong"
  "Weather and sky puzzles"
  "Odd things the human body does"
  "Senses and illusions"
  "Pets: cats and dogs surprises"
  "Birds that do surprising things"
  "Insects and tiny creatures"
  "Sea creatures"
  "Farm animal surprises"
  "Plants and trees that break the rules"
  "Record breakers in nature"
  "Rivers, lakes and mountains puzzles"
  "Islands and odd geography"
  "Cities and capitals you can reason out"
  "Flags and national symbols"
  "Money, coins and banknotes"
  "Trains, cars and roads"
  "Planes and travel habits"
  "Sport rules and why they exist"
  "Olympic Games surprises"
  "Games and toys with a story"
  "Holidays and customs through the year"
  "School and childhood things"
  "Everyday life in the past: what people really did"
  "Castles, knights and kings with a twist"
  "The night sky anyone can see"
)
i=0
for theme in $THEMES; do
  i=$((i+1)); [ -n "$ONLY" ] && [ $i != $ONLY ] && continue
  [ -z "$ONLY" ] && [ -s $RUN/$ARM-$i.json ] && continue
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --direct --dry-run --target-count 4 --language $LANG_ \
     --theme "$theme" --prompt "$brief" --per-topic-cap 4 --no-judges --floor-fraction 0 --dedup-store pgvector --out $RUN/$ARM-$i.json) > $RUN/$ARM-$i.log 2>&1
  echo "$ARM-$i rc=$? $(grep -E '^questions:' $RUN/$ARM-$i.log)" >> $RUN/run.log
  if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit| 429| 529" $RUN/$ARM-$i.log; then
    echo "QUOTA on $ARM-$i → stop" >> $RUN/run.log; rm -f $RUN/$ARM-$i.json; break
  fi
done
echo "$ARM DONE" >> $RUN/run.log
