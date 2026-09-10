#!/usr/bin/env zsh
# #168 — founder review round after the Sonnet re-verify:
#   1. gate the rows left `pending` by the re-verify (judge/answerability leg unavailable),
#   2. review-export per language (critical + flagged, no random sample),
#   3. keep ONLY the critical bucket (founder 2026-09-10: "daj kritické"),
#   4. publish one blind batch per language on the prod rating web.
# Usage: review-round.sh <worktree-root> <out-dir>
set -u
ROOT="$1"; OUT="$2"; mkdir -p "$OUT"
APP="$ROOT/apps/quiz-pack-api"
PY="/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python"
export PYTHONPATH="$ROOT/packages/shared:$APP"
set -a; source "/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env"; set +a
export LLM_GATEWAY=session
BASE_URL="https://quiz-pack-api.fly.dev"
cd "$APP" || exit 1

run() { "$PY" scripts/translate_corpus.py --database-url "$PROD_DATABASE_URL" "$@" 2>&1 | grep -v "Pydantic\|BaseModel\|postgres\|^\s*$"; return ${pipestatus[1]}; }

for L in sk cs; do
  echo "=== $(date '+%F %T') $L verify pending (Sonnet) ===" | tee -a "$OUT/review-$L.log"
  run verify --language $L --limit 10 --confirm --concurrency 2 --answerability-model claude-sonnet-5 | tee -a "$OUT/review-$L.log"
  echo "=== $(date '+%F %T') $L review-export ===" | tee -a "$OUT/review-$L.log"
  run review-export --language $L --sample 0 --out "$OUT/$L-review.json" | tee -a "$OUT/review-$L.log"
  "$PY" - "$OUT" "$L" <<'EOF' | tee -a "$OUT/review-$L.log"
import json, sys
out, lang = sys.argv[1], sys.argv[2]
rows = json.load(open(f"{out}/{lang}-review.json"))
reasons = json.load(open(f"{out}/{lang}-review.reasons.json"))
critical = {r["question_id"] for r in reasons if r.get("bucket") == "critical"}
kept = [r for r in rows if r["id"] in critical]
json.dump(kept, open(f"{out}/{lang}-critical.json", "w"), ensure_ascii=False, indent=1)
print(f"{lang}: export {len(rows)} rows → critical {len(kept)}")
EOF
  echo "=== $(date '+%F %T') $L publish critical ===" | tee -a "$OUT/review-$L.log"
  "$PY" scripts/rating_page/publish_batch.py --arm "$L=$OUT/$L-critical.json" --seed 168 \
    --title "Preklad $L — kritické po Sonnet re-verify (2026-09-10)" --base-url "$BASE_URL" \
    --admin-key "$QUIZ_PACK_ADMIN_API_KEY" --rater michal --save-mapping "$OUT/$L-critical.mapping.json" 2>&1 | tee -a "$OUT/review-$L.log"
done
echo ALL-DONE
