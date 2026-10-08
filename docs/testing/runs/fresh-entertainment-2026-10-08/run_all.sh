#!/usr/bin/env zsh
# Stream of batches for one language; stops on a subscription-limit error.
# Usage: run_all.sh <lang> "<id>|<n>|<world|domestic>|<extra brief>" ...
set -u
RUN=${0:A:h}; lang=$1; shift
for spec in "$@"; do
  id=${spec%%|*}; rest=${spec#*|}; n=${rest%%|*}; rest=${rest#*|}; scope=${rest%%|*}; extra=${rest#*|}
  $RUN/run_gen.sh $lang $id $n $scope "$extra"
  if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit| 429| 529" $RUN/$lang-$id.log; then
    echo "QUOTA on $lang-$id → stop" >> $RUN/run.log; break
  fi
done
echo "DONE $lang $(date '+%H:%M:%S')" >> $RUN/run.log
