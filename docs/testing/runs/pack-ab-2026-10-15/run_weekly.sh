#!/usr/bin/env zsh
# Usage: run_weekly.sh <old|new> <lang>   (old = FRESH_HOUSE_STYLE=0, new = 1); 8 questions, dry run, subscription
set -u
ARM=$1; LANG_=$2; RUN=${0:A:h}; MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}; API=$MAIN/apps/quiz-pack-api
set -a; source $MAIN/.env; set +a
export FRESH_TOPUP_SESSION=1 FRESH_HOUSE_STYLE=$([ $ARM = new ] && echo 1 || echo 0)
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#') PYTHONPATH=$API:$MAIN/packages/shared
cd $API && $MAIN/.venv/bin/python $RUN/weekly_arm.py $LANG_ 8 $RUN/weekly-$ARM-$LANG_.json > $RUN/weekly-$ARM-$LANG_.log 2>&1
echo "weekly-$ARM-$LANG_ rc=$? n=$(python3 -c "import json;print(len(json.load(open('$RUN/weekly-$ARM-$LANG_.json'))))" 2>/dev/null)" >> $RUN/run.log
