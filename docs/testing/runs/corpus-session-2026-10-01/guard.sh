#!/usr/bin/env zsh
# Quota guard (founder 2026-10-01: weekly limit must keep 15 % headroom): every 2 min read the subscription
# utilisation. Weekly ≥ 83 % → touch STOP (generation rounds halt for good). 5-hour ≥ 93 % → touch PAUSE
# (generation rounds wait before their next batch) and remove it once the 5-hour window drops below 40 %.
RUN=/Users/agent/code/quiz-agent/docs/testing/runs/corpus-session-2026-10-01
while true; do
  line=$($RUN/usage.sh); echo "$line" >> $RUN/usage.log
  h5=${${line#*5h=}%%%*}; d7=${${line#*7d=}%%%*}
  if [[ -n "$h5" && -n "$d7" ]]; then
    (( ${d7%.*} >= 83 )) && { echo "GUARD: 7d=$d7 → STOP $(date '+%F %T')" | tee -a $RUN/usage.log; touch $RUN/STOP; break; }
    if (( ${h5%.*} >= 93 )); then [[ -f $RUN/PAUSE ]] || { echo "GUARD: 5h=$h5 → PAUSE $(date '+%F %T')" >> $RUN/usage.log; touch $RUN/PAUSE; }
    elif (( ${h5%.*} < 40 )) && [[ -f $RUN/PAUSE ]]; then echo "GUARD: 5h=$h5 → RESUME $(date '+%F %T')" >> $RUN/usage.log; rm -f $RUN/PAUSE; fi
  fi
  sleep 120
done
