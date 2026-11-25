#!/usr/bin/env zsh
# Trend questions (founder 2026-11-19): topics people looked up this week (most-read Wikipedia), 4 questions per theme (sk, cs native; en),
# dry run, JSON only, no DB writes. Always on the Claude subscription (LLM_GATEWAY=session).
set -u
RUN=${0:A:h}; REPO=${RUN:h:h:h:h}; API=$REPO/apps/quiz-pack-api; MAIN=/Users/agent/code/quiz-agent
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=session
export LLM_ROLE_GEN=claude-opus-5-5 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 \
  LLM_ROLE_CRITIQUE=claude-opus-5-5 CRITIQUE_MODEL=claude-opus-5-5 LLM_ROLE_FACTCHECK=claude-sonnet-5-5 \
  LLM_ROLE_DEDUP_JUDGE=claude-sonnet-5-5 VERIFY_MODEL=claude-opus-5-5 ANSWERABILITY_CHECK=1 \
  TOPICALITY_CLASSIFICATION=0 EXPIRY_CLASSIFICATION=0 CASUAL_PLAYER_GATE=off JUDGE_GATE=0 BEST_OF_N=0 \
  GEN_HOUSE_STYLE=1 GEN_HOUSE_STYLE_V2=1 NATURALNESS_CHECK=1
export PYTHONPATH=$API:$REPO/packages/shared PY=$MAIN/.venv/bin/python
RULES="Quiz questions tied to a topic people are talking about this week. Ask about lasting, checkable facts around the topic (history, works, records, places, people), never about news, results or anything that can change. No current politics, no crime, no wars. Vary the subtopics within the theme."
for lang in sk cs en; do
  if [ $lang = sk ]; then
    AUD="Adults who live in Slovakia and play in Slovak. Tell shared Czechoslovak culture from the Slovak side."
  elif [ $lang = cs ]; then
    AUD="Adults who live in the Czech Republic and play in Czech. Tell shared Czechoslovak culture from the Czech side."
  else
    AUD="Adults in English-speaking countries and international players who play in English."
  fi
  THEMES=("${(@f)$($PY -c "import json; print('\n'.join(json.load(open('$RUN/themes.json'))['$lang']))")}")
  i=0; waits=0
  for theme in $THEMES; do
    i=$((i+1)); out=$RUN/$lang-$i.json; [ -s $out ] && continue
    while true; do
      (cd $API && $PY scripts/generate_pack.py --direct --dry-run --target-count 4 --language $lang \
         --theme "$theme" --prompt "$AUD $RULES Theme: $theme" --per-topic-cap 4 --no-judges --floor-fraction 0 \
         --dedup-store noop --out $out) > $RUN/$lang-$i.log 2>&1
      rc=$?
      if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit| 429| 529" $RUN/$lang-$i.log; then
        rm -f $out; waits=$((waits+1))
        [ $waits -gt 24 ] && { echo "QUOTA $lang-$i gave up" >> $RUN/run.log; exit 1; }
        echo "QUOTA $lang-$i wait 30 min ($waits) $(date '+%H:%M')" >> $RUN/run.log; sleep 1800; continue
      fi
      echo "$lang-$i rc=$rc $(grep -E '^questions:' $RUN/$lang-$i.log) $(date '+%H:%M')" >> $RUN/run.log; break
    done
  done
done
echo DONE >> $RUN/run.log
