#!/usr/bin/env zsh
# #203 203.9 blind test: one custom pack (10 questions) through the worker-like walk, dry run, subscription.
# old = today's prod-worker defaults · new = GEN_HOUSE_STYLE + PACK_SUBTHEMES + Opus 5.5 pinned.
# Usage: GATEWAY=session|direct|openrouter run_pack.sh <old|new> <en|sk|cs> <slug> "<order text>" [target=10]
set -u
ARM=$1; LANG_=$2; SLUG=$3; ORDER=$4; TARGET=${5:-10}
RUN=${0:A:h}; MAIN=${QUIZ_MAIN:-${RUN:h:h:h:h}}; API=$MAIN/apps/quiz-pack-api
set -a; source $MAIN/.env; set +a
export LLM_GATEWAY=${GATEWAY:-session} JUDGE_GATE=0
if [ $ARM = new ]; then export GEN_HOUSE_STYLE=1 PACK_SUBTHEMES=1 GENERATION_MODEL=claude-opus-5-5
else export GEN_HOUSE_STYLE=0 PACK_SUBTHEMES=0; unset GENERATION_MODEL; fi
export DATABASE_URL=$(echo "$PROD_DATABASE_URL" | sed -E 's#@[^/]+/#@localhost:15432/#')
export PYTHONPATH=$API:$MAIN/packages/shared
nc -z localhost 15432 2>/dev/null || { env -u FLY_API_TOKEN nohup fly proxy 15432:5432 -a quiz-pack-db >> $RUN/tunnel.log 2>&1 & sleep 10; }
cd $API && $MAIN/.venv/bin/python scripts/generate_pack.py --customer-order --dry-run --target-count $TARGET --language $LANG_ \
  --prompt "$ORDER" --no-judges --dedup-store pgvector --out $RUN/$ARM-$SLUG.json > $RUN/$ARM-$SLUG.log 2>&1
echo "$ARM-$SLUG rc=$? $(grep -E '^questions:' $RUN/$ARM-$SLUG.log)" >> $RUN/run.log
