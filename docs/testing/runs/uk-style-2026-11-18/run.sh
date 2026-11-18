#!/usr/bin/env zsh
# #231 style check: 5 themes x 2 native uk questions, dry run, subscription (free).
set -u
RUN=${0:A:h}; API=/Users/agent/code/quiz-agent-231/apps/quiz-pack-api; MAIN=/Users/agent/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=session LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0 \
  GEN_HOUSE_STYLE=1 GEN_HOUSE_STYLE_V2=1 NATURALNESS_CHECK=1
export PYTHONPATH=$API:$API/../../packages/shared
themes=("Ukrainian cuisine: borscht, varenyky, salo and festive dishes" "The Carpathians, Hutsul traditions and mountain life" "Ukrainian music from folk songs to modern bands" "Kyiv, Lviv and Odesa: sights, legends and everyday city life" "Everyday science: surprising reasons behind things at home and in the car" "Ukrainian sport legends and records before 2014")
i=0
for theme in $themes; do
  i=$((i+1)); [ -s $RUN/t$i.json ] && continue
  (cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --direct --dry-run --target-count 2 --language uk \
     --theme "$theme" --prompt "$theme" --per-topic-cap 2 --no-judges --floor-fraction 0 --dedup-store noop --out $RUN/t$i.json) > $RUN/t$i.log 2>&1
  echo "t$i rc=$? $(grep -E '^questions:' $RUN/t$i.log)" >> $RUN/run.log
done
echo DONE >> $RUN/run.log
