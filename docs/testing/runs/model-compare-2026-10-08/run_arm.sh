#!/usr/bin/env zsh
# Founder 2026-10-08: blind generation comparison Fable 5 vs Fable 5.1 vs Opus 5.5 on the subscription.
# Usage: run_arm.sh <arm> <count>   arm = fable51 | opus55 | fable5. Dry-run JSON only, no DB writes.
# Same theme + prompt for every arm; only the generator model differs (verifiers stay identical).
set -u
arm=$1; n=$2
W=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent-wt-models
RUN=$W/docs/testing/runs/model-compare-2026-10-08
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session PYTHONPATH=$W/packages/shared
case $arm in
  fable51) export GENERATION_MODEL=claude-fable-5 ;;   # alias "fable" = Fable 5.1
  opus55)  export GENERATION_MODEL=claude-opus-5 ;;    # alias "opus"  = Opus 5.5
  fable5)  export GENERATION_MODEL=claude-fable-5 LLM_SESSION_MAP=claude-fable-5=claude-fable-5 ;;  # pinned old
esac
theme="General knowledge mix: history, geography, science, nature, food, sport and pop culture"
echo "start $arm $(date '+%H:%M:%S') n=$n" >> $RUN/run.log
(cd $W/apps/quiz-pack-api && /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python \
   scripts/generate_pack.py --dry-run --language en --target-count $n --theme "$theme" --per-topic-cap $n \
   --dedup-store noop --out $RUN/$arm.json) > $RUN/$arm.log 2>&1
echo "rc=$? end $arm $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/$arm.log)" >> $RUN/run.log
