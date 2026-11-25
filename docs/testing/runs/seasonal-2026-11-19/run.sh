#!/usr/bin/env zsh
# Seasonal questions 2026-11-19 (same recipe as docs/testing/runs/christmas-2026-11-18/run.sh):
# themes.json x 3 questions per theme, native per language, dry run, JSON only, no DB writes.
# Always on the Claude subscription (LLM_GATEWAY=session). Usage: run.sh [langs...]  (default: uk sk cs en)
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
RULES="Winter holiday season quiz questions about history and traditions that do not change from year to year, never news or results. No politics, no wars. Present religion culturally and factually. Vary the subtopics within the theme."
for lang in ${@:-uk sk cs en}; do
  case $lang in
    uk) AUD="Adults who live in Ukraine and play in Ukrainian. Ask about the winter holidays as Ukrainians know them (Sviatyi Mykolai, Sviatvechir, koliadky), told from the Ukrainian side; nothing about Russia or Russian customs.";;
    sk) AUD="Adults who live in Slovakia and play in Slovak. Ask about the turn of the year as Slovaks know it, shared Czechoslovak culture told from the Slovak side; no Czech-only customs.";;
    cs) AUD="Adults who live in the Czech Republic and play in Czech. Ask about the turn of the year as Czechs know it, shared Czechoslovak culture told from the Czech side; no Slovak-only customs.";;
    *)  AUD="Adults in English-speaking countries and international players who play in English.";;
  esac
  THEMES=("${(@f)$($PY -c "import json; print('\n'.join(json.load(open('$RUN/themes.json'))['$lang']))")}")
  i=0; waits=0
  for theme in $THEMES; do
    i=$((i+1)); out=$RUN/$lang-$i.json; [ -s $out ] && continue
    while true; do
      (cd $API && $PY scripts/generate_pack.py --direct --dry-run --target-count 3 --language $lang \
         --theme "$theme" --prompt "$AUD $RULES Theme: $theme" --per-topic-cap 3 --no-judges --floor-fraction 0 \
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
echo "DONE ${@:-all}" >> $RUN/run.log
