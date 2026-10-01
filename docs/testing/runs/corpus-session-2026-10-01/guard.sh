#!/usr/bin/env zsh
# Quota guard (founder 2026-10-01: weekly limit must keep 15 % headroom): every 2 min read the subscription
# utilisation; touch STOP (halts the generation rounds before their next batch) when the weekly limit reaches
# 83 % or the 5-hour limit reaches 90 %. Translation jobs are short and finish on their own.
RUN=/Users/agent/code/quiz-agent/docs/testing/runs/corpus-session-2026-10-01
while true; do
  line=$($RUN/usage.sh)
  echo "$line" >> $RUN/usage.log
  h5=${${line#*5h=}%%%*}; d7=${${line#*7d=}%%%*}
  if [[ -n "$h5" && -n "$d7" ]] && (( ${h5%.*} >= 90 || ${d7%.*} >= 83 )); then
    echo "GUARD: 5h=$h5 7d=$d7 → STOP $(date '+%F %T')" | tee -a $RUN/usage.log; touch $RUN/STOP; break
  fi
  sleep 120
done
