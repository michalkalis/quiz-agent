#!/usr/bin/env zsh
# #231.4 Ukrainian batch 2 (founder 2026-11-19: "priamo pomocou subscription"):
# 100 themes x 2 native uk questions, dry run (no DB writes), always LLM_GATEWAY=session.
# Usage: run.sh <shard> <shards>   e.g. three terminals: run.sh 0 3 / run.sh 1 3 / run.sh 2 3
set -u
RUN=${0:A:h}; REPO=${RUN:h:h:h:h}; API=$REPO/apps/quiz-pack-api; MAIN=/Users/agent/code/quiz-agent
SHARD=${1:-0}; SHARDS=${2:-1}
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=session
export LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0 \
  GEN_HOUSE_STYLE=1 GEN_HOUSE_STYLE_V2=1 NATURALNESS_CHECK=1
export PYTHONPATH=$API:$REPO/packages/shared PY=$MAIN/.venv/bin/python
THEMES=("${(@f)$($PY -c "import json; print('\n'.join(json.load(open('$RUN/themes.json'))['themes']))")}")
i=0; waits=0
for theme in $THEMES; do
  i=$((i+1)); [ $(( (i-1) % SHARDS )) -ne $SHARD ] && continue
  [ -s $RUN/t$i.json ] && continue
  while true; do
    (cd $API && $PY scripts/generate_pack.py --direct --dry-run --target-count 2 --language uk \
       --theme "$theme" --prompt "$theme" --per-topic-cap 2 --no-judges --floor-fraction 0 --dedup-store noop --out $RUN/t$i.json) > $RUN/t$i.log 2>&1
    rc=$?
    if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit| 429| 529" $RUN/t$i.log; then
      rm -f $RUN/t$i.json; waits=$((waits+1))
      [ $waits -gt 24 ] && { echo "QUOTA t$i gave up" >> $RUN/run.log; exit 1; }
      echo "QUOTA t$i wait 30 min ($waits) $(date '+%H:%M')" >> $RUN/run.log; sleep 1800; continue
    fi
    echo "t$i rc=$rc $(grep -E '^questions:' $RUN/t$i.log) $(date '+%H:%M')" >> $RUN/run.log; break
  done
done
echo "DONE shard $SHARD" >> $RUN/run.log
