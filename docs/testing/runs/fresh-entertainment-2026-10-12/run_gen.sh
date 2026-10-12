#!/usr/bin/env zsh
# #199 top-up (2026-10-12): fresh EN entertainment, dry-run JSON only, no DB writes.
# Same pipeline, gateway (subscription session) and brief as the 2026-10-08 run (tone text from PR #299),
# plus the list of facts already in prod. One batch per seed file so batches do not repeat each other.
# Usage: run_gen.sh <batch-id> <target-count> <topics-file> "<extra brief>"
set -u
id=$1; n=$2; topics=$3; extra=$4
RUN=${0:A:h}; WT=${RUN:h:h:h:h}
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session
brief="FRESH entertainment questions for adults anywhere in the world. Every question is about global entertainment (film, TV and streaming, music, video games, pop-culture moments) that a casual fan anywhere would recognise. Freshness: ask about things that happened or came out recently, mostly between July and October 2026 (today is $(date +%Y-%m-%d)); older events only when they had a big recent twist. Every question must stay true forever: anchor it in time with a year or event name (\"at the 2026 Emmys\", \"in her 2026 album\"), never \"currently\", \"this year\", \"last week\", \"the latest\", and never ask about rankings or records that can change. Avoid CURRENT politics and CURRENT wars or armed conflicts (including countries involved in one); historical events and dark themes inside films, series or games are fine. No gossip. Mostly open questions answered in a few words; at most 3 multiple-choice. Seed facts (from web research on $(date +%Y-%m-%d), each with a source; verify independently, skip any you cannot confirm, and you may use other equally fresh facts):
$(cat $RUN/$topics)

$(cat $RUN/covered-fresh.txt)
$extra"
echo "start en-$id $(date '+%H:%M:%S') n=$n topics=$topics" >> $RUN/run.log
(cd $WT/apps/quiz-pack-api && $WT/.venv/bin/python scripts/generate_pack.py --direct --dry-run --language en --category entertainment \
   --floor-fraction 0 --target-count $n --prompt "$brief" --dedup-store noop --out $RUN/en-$id.json) > $RUN/en-$id.log 2>&1
echo "rc=$? end en-$id $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/en-$id.log)" >> $RUN/run.log
