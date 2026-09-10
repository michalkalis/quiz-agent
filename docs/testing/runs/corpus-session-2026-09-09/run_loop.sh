#!/usr/bin/env bash
# Corpus batch loop on the Claude Code subscription (#169), founder request 2026-09-09 ("100+ EN questions").
# Batches of $BATCH target via generate_pack.py --dry-run (JSON on disk), pgvector dedup against prod through the
# fly proxy tunnel (falls back to noop if the tunnel is down), quota exhaustion = sleep and retry (no clock assumptions).
# Stops when >= $GOAL questions accumulated, after $MAX_BATCHES batches, 3 consecutive non-quota failures, or $MAX_HOURS.
# finalize: near-dup merge across batches → all.json → import into prod as pending_review (founder approves in review UI).
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-09
API=$ROOT/apps/quiz-pack-api
BATCH=${BATCH:-15}; GOAL=${GOAL:-120}; MAX_BATCHES=${MAX_BATCHES:-16}; MAX_HOURS=${MAX_HOURS:-18}; QUOTA_SLEEP=${QUOTA_SLEEP:-900}
set -a; source $ROOT/.env; set +a
export LLM_GATEWAY=session
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a $RUN/loop.log; }
T0=$(date +%s)
count(){ python3 - "$RUN" <<'PY'
import json, sys, glob
n=0
for f in sorted(glob.glob(f"{sys.argv[1]}/batch-*.json")):
    if f.endswith(".usage.json") or f.endswith("-sourced.json"): continue
    n+=len(json.load(open(f)))
print(n)
PY
}
finalize(){
  log "finalize: merging batches"
  python3 - "$RUN" <<'PY'
import json, sys, glob, difflib
run = sys.argv[1]; allq = []
for f in sorted(glob.glob(f"{run}/batch-*.json")):
    if f.endswith(".usage.json") or f.endswith("-sourced.json"): continue
    if f.endswith("batch-01.json"): continue  # already imported to prod 2026-09-09 (see batch-01-sourced.json)
    allq += json.load(open(f))
def norm(t): return " ".join(str(t).lower().split())
kept, dupes, nosrc = [], [], []
for q in allq:
    if not q.get("source_url"):
        nosrc.append(q); continue
    hit = None
    for k in kept:
        r = difflib.SequenceMatcher(None, norm(q["question"]), norm(k["question"])).ratio()
        if r >= 0.6 or (r >= 0.4 and norm(q["correct_answer"]) == norm(k["correct_answer"])):
            hit = k; break
    (dupes if hit else kept).append({"q": q["question"], "of": hit["question"]} if hit else q)
json.dump(kept, open(f"{run}/all.json", "w"), indent=1)
json.dump(dupes, open(f"{run}/all-dupes.json", "w"), indent=1)
json.dump(nosrc, open(f"{run}/all-nosource.json", "w"), indent=1)
mcq = sum(1 for q in kept if q.get("question_type") == "multiple_choice" or q.get("options"))
print(f"merged {len(allq)}: kept {len(kept)} (mcq {mcq}), near-duplicates {len(dupes)}, no-source dropped {len(nosrc)}")
PY
  n=$(python3 -c "import json;print(len(json.load(open('$RUN/all.json'))))")
  if [ "$n" -gt 0 ] && nc -z localhost 15432 2>/dev/null; then
    log "import: $n questions → prod as pending_review"
    (cd $API && uv run --no-sync python scripts/import_questions_json.py --json-path $RUN/all.json \
      --database-url "$PROD_DATABASE_URL" --execute) 2>&1 | tee -a $RUN/loop.log | tee $RUN/import.out
  else
    log "import SKIPPED (n=$n, tunnel $(nc -z localhost 15432 2>/dev/null && echo up || echo DOWN)) — run import manually"
  fi
  log "DONE batches_ok=$ok batches_failed=$failed questions_import_candidates=$n stop_reason=$reason"
}
THEMES=("Space and astronomy" "Human body and medicine" "Oceans and marine life" "Ancient civilisations" "Inventions and everyday objects" "Food and drink origins" "Animals and their abilities" "Weather and climate" "Languages and words" "Borders, maps and flags" "Famous cities and landmarks" "Money, trade and economics" "Music history" "Film and television" "Video games and toys" "Cars, trains and aviation" "Chemistry and materials" "Physics in daily life" "Plants and fungi" "Art and architecture" "Literature and authors" "Mythology and folklore" "Exploration and expeditions" "Technology and the internet" "Famous mistakes and accidents" "Law, crime and forensics" "Insects and small creatures" "Deserts, mountains and volcanoes" "Time, calendars and measurement" "Medieval Europe" "Asian history and culture" "Africa and South America" "Royalty and empires" "Psychology and the brain" "Sports records and Olympics" "World wars and the Cold War" "Mathematics and logic puzzles" "Birds and flight" "Rivers, lakes and islands" "Everyday science myths busted")
ok=0; failed=0; reason=unknown; consec=0; i=1   # batch-01 exists (imported); loop starts at batch-02
trap 'reason=${reason:-killed}; finalize' EXIT
while :; do
  have=$(( $(count) - 13 ))   # exclude batch-01
  [ $have -ge $GOAL ] && { reason=goal_reached; break; }
  [ $ok -ge $MAX_BATCHES ] && { reason=max_batches; break; }
  [ $(( ($(date +%s) - T0) / 3600 )) -ge $MAX_HOURS ] && { reason=max_hours; break; }
  i=$((i+1)); tag=$(printf 'batch-%02d' $i); theme="${THEMES[$(( (i-2) % ${#THEMES[@]} ))]}"
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; log "WARN tunnel 15432 down → dedup noop for $tag"; fi
  log "start $tag ($dedup) theme=$theme have=$have"
  (cd $API && uv run --no-sync python scripts/generate_pack.py --dry-run \
      --target-count $BATCH --language en --theme "$theme" --per-topic-cap $BATCH $dedup --out $RUN/$tag.json) > $RUN/$tag.log 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    ok=$((ok+1)); consec=0
    log "finish $tag: $(grep -E '^questions:' $RUN/$tag.log) $(grep -E '^out:' $RUN/$tag.log | sed 's/.*wrote/wrote/')"
    continue
  fi
  if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|overloaded|too many requests|429|529" $RUN/$tag.log; then
    log "quota/rate limit on $tag → sleeping ${QUOTA_SLEEP}s then retry"
    rm -f $RUN/$tag.json; i=$((i-1)); sleep $QUOTA_SLEEP; continue
  fi
  failed=$((failed+1)); consec=$((consec+1))
  log "FAIL $tag rc=$rc: $(grep -E 'Error|Traceback' $RUN/$tag.log | tail -1)"
  [ $consec -ge 3 ] && { reason=repeated_failures; break; }
done
