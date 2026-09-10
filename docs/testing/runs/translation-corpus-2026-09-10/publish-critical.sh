#!/usr/bin/env zsh
# #168 — publish the critical-bucket exports (review/{sk,cs}-critical.json) as two
# blind batches on the prod rating web. Mirrors corpus-session-2026-09-02/run_overnight.sh.
# Usage: publish-critical.sh <worktree-root> <review-dir>
set -u
ROOT="$1"; OUT="$2"
APP="$ROOT/apps/quiz-pack-api"
PY="/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python"
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source "/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env"; set +a
cd "$APP" || exit 1
for L in sk cs; do
  echo "=== $(date '+%F %T') $L publish critical ===" | tee -a "$OUT/publish-$L.log"
  "$PY" scripts/rating_page/publish_batch.py --arm "$L=$OUT/$L-critical.json" --seed 168 \
    --title "Preklad $L — kritické po Sonnet re-verify (2026-09-10)" \
    --base-url https://quiz-pack-api.fly.dev --admin-key "$QUIZ_PACK_ADMIN_API_KEY" \
    --rater michal --save-mapping "$OUT/$L-critical.mapping.json" 2>&1 | tee -a "$OUT/publish-$L.log"
done
echo ALL-DONE
