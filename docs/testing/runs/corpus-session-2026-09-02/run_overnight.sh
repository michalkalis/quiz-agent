#!/usr/bin/env bash
# Overnight corpus generation on the Claude Code subscription (#169), founder go 2026-09-02 22:05.
# Loop: batches of $BATCH via generate_pack.py --dry-run (JSON on disk), dedup against prod corpus
# through the fly proxy tunnel when it is up, publish everything as ONE blind rating batch at the end.
# Stops on: quota exhausted after the 00:10 window reset, 3 consecutive non-quota failures, or the
# 04:20 no-new-batch cutoff (hard kill 04:50). Never writes to the DB.
set -u
ROOT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
RUN=$ROOT/docs/testing/runs/corpus-session-2026-09-02
API=$ROOT/apps/quiz-pack-api
BATCH=${BATCH:-10}
NO_NEW_AFTER="04:20"; HARD_STOP="04:50"; RESET_AT="00:12"
set -a; source $ROOT/.env; set +a
[ -f $RUN/factcheck.env ] && { set -a; source $RUN/factcheck.env; set +a; }
export LLM_GATEWAY=session
log(){ echo "$(date '+%H:%M:%S') $*" | tee -a $RUN/overnight.log; }
now(){ date +%H:%M; }
before(){ [ "$(now)" \< "$1" ]; }   # lexical HH:MM compare, valid within one calendar day
past_midnight(){ [ "$(now)" \< "12:00" ]; }
finalize(){
  log "finalize: publishing accumulated batches"
  python3 - "$RUN" <<'PY'
import json, sys, glob
run = sys.argv[1]; allq = []
PUBLISHED_UPTO = 9  # night-01..09 = batch 353c88ca (23:14); reference only
for f in sorted(glob.glob(f"{run}/night-*.json")):
    if f.endswith(".usage.json") or "night-all" in f or "night-dupes" in f: continue
    idx = int(f.rsplit("night-",1)[1][:2])
    for q in json.load(open(f)):
        q["_published"] = idx <= PUBLISHED_UPTO
        allq.append(q)
import difflib
def norm(t): return " ".join(t.lower().split())
kept, dupes = [], []
for q in allq:
    hit = None
    for k in kept:
        r = difflib.SequenceMatcher(None, norm(q["question"]), norm(k["question"])).ratio()
        if r >= 0.6 or (r >= 0.4 and norm(str(q["correct_answer"])) == norm(str(k["correct_answer"]))):
            hit = k; break
    (dupes if hit else kept).append({"q": q["question"], "of": hit["question"]} if hit else q)
new = [dict((k, v) for k, v in q.items() if k != "_published") for q in kept if not q["_published"]]
json.dump(new, open(f"{run}/night-all.json", "w"), indent=1)
print(f"new (unpublished) questions to publish: {len(new)}")
json.dump(dupes, open(f"{run}/night-dupes.json", "w"), indent=1)
print(f"merged {len(allq)} questions, kept {len(kept)}, near-duplicates removed {len(dupes)}")
PY
  n=$(python3 -c "import json;print(len(json.load(open('$RUN/night-all.json'))))")
  if [ "$n" -gt 0 ]; then
    (cd $API && uv run --no-sync python scripts/rating_page/publish_batch.py \
      --arm night=$RUN/night-all.json --seed 904 \
      --title "Korpus — nočná dávka 2026-09-03 (2)" \
      --base-url https://quiz-pack-api.fly.dev --admin-key "$QUIZ_PACK_ADMIN_API_KEY" \
      --rater michal --save-mapping $RUN/night-mapping.json) 2>&1 | tee -a $RUN/overnight.log | tee $RUN/publish.out
  else
    log "nothing to publish"
  fi
  log "DONE batches_ok=$ok batches_failed=$failed questions=$n stop_reason=$reason"
}
THEMES=("Space and astronomy" "Human body and medicine" "Oceans and marine life" "Ancient civilisations" "Inventions and everyday objects" "Food and drink origins" "Animals and their abilities" "Weather and climate" "Languages and words" "Borders, maps and flags" "Famous cities and landmarks" "Money, trade and economics" "Music history" "Film and television" "Video games and toys" "Cars, trains and aviation" "Chemistry and materials" "Physics in daily life" "Plants and fungi" "Art and architecture" "Literature and authors" "Mythology and folklore" "Exploration and expeditions" "Technology and the internet" "Famous mistakes and accidents" "Law, crime and forensics" "Insects and small creatures" "Deserts, mountains and volcanoes" "Time, calendars and measurement" "Medieval Europe" "Asian history and culture" "Africa and South America" "Royalty and empires" "Psychology and the brain" "Sports records and Olympics" "World wars and the Cold War" "Mathematics and logic puzzles" "Birds and flight" "Rivers, lakes and islands" "Everyday science myths busted")
ok=0; failed=0; reason=unknown; consec=0; i=$(ls $RUN/night-??.json 2>/dev/null | wc -l | tr -d ' ')
trap 'reason=${reason:-killed}; finalize' EXIT
while :; do
  if past_midnight && ! before "$NO_NEW_AFTER"; then reason=cutoff; break; fi
  i=$((i+1)); tag=$(printf 'night-%02d' $i); theme="${THEMES[$(( (i-1) % ${#THEMES[@]} ))]}"
  if nc -z localhost 15432 2>/dev/null; then dedup="--dedup-store pgvector"; export DATABASE_URL="$PROD_DATABASE_URL"; else dedup="--dedup-store noop"; log "WARN tunnel 15432 down → dedup noop for $tag"; fi
  log "start $tag ($dedup) theme=$theme"
  target=$(date -j -f '%H:%M' "$HARD_STOP" +%s); [ $target -lt $(date +%s) ] && target=$((target+86400))
  secs=$((target - $(date +%s))); [ $secs -lt 60 ] && secs=60
  (cd $API && perl -e 'alarm shift @ARGV; exec @ARGV' $secs uv run --no-sync python scripts/generate_pack.py --dry-run \
      --target-count $BATCH --language en --theme "$theme" --per-topic-cap $BATCH $dedup --out $RUN/$tag.json) > $RUN/$tag.log 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    ok=$((ok+1)); consec=0
    log "finish $tag: $(grep -E '^questions:' $RUN/$tag.log)"
    continue
  fi
  if grep -q -i -E "session limit|hit your|limit reached|usage limit|quota|rate.?limit|overloaded|too many requests|429|529" $RUN/$tag.log; then
    if past_midnight; then reason=quota_exhausted_after_reset; log "quota exhausted after reset → stop"; break; fi
    log "quota exhausted before reset → sleeping until $RESET_AT"
    while before "$RESET_AT" || ! past_midnight; do sleep 60; done
    continue
  fi
  failed=$((failed+1)); consec=$((consec+1))
  log "FAIL $tag rc=$rc: $(grep -E 'Error|Traceback' $RUN/$tag.log | tail -1)"
  [ $consec -ge 3 ] && { reason=repeated_failures; break; }
done
