#!/usr/bin/env zsh
# #211 pilot (founder 2026-10-22): current house style (A) vs house style v2 (B), same 6 themes, 2 questions each.
# Usage: GATEWAY=session run_arm.sh <A|B> <en|sk|cs>. Prod-parity pins as general-corpus-2026-10-14/run_arm.sh,
# house style from the pipeline (GEN_HOUSE_STYLE=1, no --prompt). Needs `fly proxy 15432:5432 -a quiz-pack-db` (dedup).
set -u
ARM=$1; LANG_=$2
RUN=${0:A:h}; API=$RUN/../../../../apps/quiz-pack-api
MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=${GATEWAY:-direct} LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0 GEN_HOUSE_STYLE=1
[ $ARM = B ] && export GEN_HOUSE_STYLE_V2=1 || export GEN_HOUSE_STYLE_V2=0
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$API/../../packages/shared
THEMES=("${(@f)$(python3 -c "import json; print('\n'.join(json.load(open('$RUN/themes.json'))))")}")
i=0
for theme in $THEMES; do
  i=$((i+1)); out=$RUN/$ARM-$LANG_-$i.json; [ -s $out ] && continue
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --direct --dry-run --target-count 2 --language $LANG_ \
     --theme "$theme" --per-topic-cap 2 --no-judges --floor-fraction 0 --dedup-store pgvector --out $out) > ${out%.json}.log 2>&1
  echo "$ARM-$LANG_-$i rc=$? $(grep -E '^questions:' ${out%.json}.log)" >> $RUN/run.log
done
echo "$ARM $LANG_ DONE" >> $RUN/run.log
