#!/usr/bin/env zsh
# Founder 2026-10-08 round 2: Fable 5.1 vs Opus 5.5, duplicates against the prod corpus removed post-hoc
# (replay_dedup_json.py) so the dup rate per model is measured too. Dry-run JSON only, no DB writes.
set -u
arm=$1; n=$2
W=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent-wt-genmix
RUN=$W/docs/testing/runs/model-compare-2026-10-08b
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session PYTHONPATH=$W/packages/shared
case $arm in
  fable51) export GENERATION_MODEL=claude-fable-5-1 LLM_SESSION_MAP=claude-fable-5-1=claude-fable-5-1 ;;
  opus55)  export GENERATION_MODEL=claude-opus-5-5 LLM_SESSION_MAP=claude-opus-5-5=claude-opus-5-5 ;;
esac
theme="General knowledge mix: history, geography, science, nature, food, sport and pop culture"
echo "start $arm $(date '+%H:%M:%S') n=$n" >> $RUN/run.log
(cd $W/apps/quiz-pack-api && /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python \
   scripts/generate_pack.py --dry-run --language en --target-count $n --theme "$theme" --per-topic-cap $n \
   --dedup-store noop --out $RUN/$arm.json) > $RUN/$arm.log 2>&1
echo "rc=$? end $arm $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/$arm.log)" >> $RUN/run.log
