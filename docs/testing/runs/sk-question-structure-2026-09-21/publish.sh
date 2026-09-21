#!/usr/bin/env zsh
# Publish the two arms blind to the prod rating web (original is NOT published — the founder
# sees it only in reveal.sh after rating). Usage: publish.sh <sk|cs>
set -u
LANG_CODE="${1:-sk}"
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.claude/worktrees/sk-question-structure
RUN=$ROOT/docs/testing/runs/sk-question-structure-2026-09-21
APP=$ROOT/apps/quiz-pack-api
PY=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source $ROOT/.env; set +a
# prod admin key lives under QUIZ_PACK_ADMIN_API_KEY (lesson 2026-09-10)
export ADMIN_API_KEY="$QUIZ_PACK_ADMIN_API_KEY"
cd "$APP" || exit 1
"$PY" scripts/rating_page/publish_batch.py \
  --arm retranslate=$RUN/retranslate-$LANG_CODE.json \
  --arm rewrite=$RUN/rewrite-$LANG_CODE.json \
  --seed 2026 --title "Slovosled otázok ${LANG_CODE:u} — slepý test 2026-09-21" \
  --base-url https://quiz-pack-api.fly.dev --rater michal \
  --save-mapping $RUN/mapping-$LANG_CODE.json 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$" | tee -a $RUN/publish-$LANG_CODE.log
exit ${pipestatus[1]}
