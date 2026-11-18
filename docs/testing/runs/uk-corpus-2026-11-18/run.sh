#!/usr/bin/env zsh
# #231.4 first Ukrainian batch: 100 themes x 2 native uk questions, dry run (no DB writes).
# Route per batch: Anthropic API plan credit first, then the subscription (scripts/llm_route.sh).
set -u
RUN=${0:A:h}; REPO=${REPO:?}; API=$REPO/apps/quiz-pack-api; MAIN=/Users/agent/code/quiz-agent
set -a; source $MAIN/.env; set +a
export ANTHROPIC_CREDIT_START=2026-11-06 ANTHROPIC_CREDIT_EXPIRES=2026-12-06
export LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0 \
  GEN_HOUSE_STYLE=1 GEN_HOUSE_STYLE_V2=1 NATURALNESS_CHECK=1
export PYTHONPATH=$API:$API/../../packages/shared PY=$MAIN/.venv/bin/python
THEMES=("${(@f)$($PY -c "import json; print('\n'.join(json.load(open('$RUN/themes.json'))['themes']))")}")
i=0; waits=0
for theme in $THEMES; do
  i=$((i+1)); [ -s $RUN/t$i.json ] && continue
  while true; do
    (cd $API && source $REPO/scripts/llm_route.sh >> $RUN/route.log && $PY scripts/generate_pack.py --direct --dry-run --target-count 2 --language uk \
       --theme "$theme" --prompt "$theme" --per-topic-cap 2 --no-judges --floor-fraction 0 --dedup-store noop --out $RUN/t$i.json) > $RUN/t$i.log 2>&1
    rc=$?
    if grep -q -i -E "session limit|hit your|limit reached|usage limit|credit balance|quota|rate.?limit| 429| 529" $RUN/t$i.log; then
      rm -f $RUN/t$i.json; waits=$((waits+1))
      [ $waits -gt 24 ] && { echo "QUOTA t$i gave up" >> $RUN/run.log; exit 1; }
      echo "QUOTA t$i wait 30 min ($waits) $(date '+%H:%M')" >> $RUN/run.log; sleep 1800; continue
    fi
    echo "t$i rc=$rc $(grep -E '^questions:' $RUN/t$i.log) $(tail -1 $RUN/route.log)" >> $RUN/run.log; break
  done
done
echo DONE >> $RUN/run.log
