#!/usr/bin/env zsh
# After the founder has rated: export ratings from the prod rating web and write
# reveal-<lang>.md (original vs retranslate vs rewrite, with scores and gate findings).
# Usage: reveal.sh <sk|cs> [batch_id]
set -u
LANG_CODE="${1:-sk}"
BATCH="${2:-}"
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.claude/worktrees/sk-question-structure
RUN=$ROOT/docs/testing/runs/sk-question-structure-2026-09-21
APP=$ROOT/apps/quiz-pack-api
PY=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python
export PYTHONPATH="$ROOT/packages/shared:$APP"
# worktrees have no .env of their own — read the main checkout's
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
# prod admin key lives under QUIZ_PACK_ADMIN_API_KEY (lesson 2026-09-10)
export ADMIN_API_KEY="$QUIZ_PACK_ADMIN_API_KEY"
cd "$APP" || exit 1
"$PY" scripts/rating_page/export_ratings.py --base-url https://quiz-pack-api.fly.dev --out $RUN/ratings.jsonl 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$"
"$PY" scripts/question_structure_arms.py reveal --language "$LANG_CODE" --out-dir "$RUN" \
  --ratings $RUN/ratings.jsonl ${=BATCH:+--batch-id $BATCH} 2>&1 | grep -v "Pydantic\|BaseModel\|^\s*$"
