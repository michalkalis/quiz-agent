#!/usr/bin/env zsh
# #195 — fresh entertainment batch (founder 2026-10-08): 50 en + 50 sk + 50 cs, dry-run JSON only, no DB writes.
# Usage: run_gen.sh <en|sk|cs> <batch-id> <target-count> <scope: world|domestic> "<extra brief>"
set -u
lang=$1; id=$2; n=$3; scope=$4; extra=$5
RUN=${0:A:h}; WT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent-wt-fresh-code  # has --floor-fraction (#195 PR #285)
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session
case $lang in
  en) aud="adults anywhere in the world"; topics=$RUN/topics-world.md ;;
  sk) aud="adults who live in Slovakia and play in Slovak"; [ $scope = domestic ] && topics=$RUN/topics-sk.md || topics=$RUN/topics-world.md ;;
  cs) aud="adults who live in the Czech Republic and play in Czech"; [ $scope = domestic ] && topics=$RUN/topics-cz.md || topics=$RUN/topics-world.md ;;
esac
if [ $scope = domestic ]; then
  # The blind answerability proxy (haiku in session mode) barely knows small-market pop culture,
  # so for domestic batches it stands in with sonnet: still blind (no web), closer to a local fan.
  export LLM_SESSION_MAP="deepseek-v4-flash=sonnet"
  focus="Every question is about the entertainment scene of the players' own country (film, TV and streaming shows, music, celebrities, awards). Only the BIGGEST things an ordinary viewer noticed: winners of the most-watched TV shows, the most-seen films, main categories of the national film and music awards, the biggest hits and stars. Skip festival side-awards, premieres abroad, niche documentaries and anything only industry insiders follow. Do not ask about the neighbouring Czech/Slovak scene unless it is genuinely shared."
else
  focus="Every question is about global entertainment (film, TV and streaming, music, video games, pop-culture moments) that a casual fan anywhere would recognise."
fi
brief="FRESH entertainment questions for $aud. $focus Freshness: ask about things that happened or came out recently, mostly in 2026 and late 2025 (today is $(date +%Y-%m-%d)); older events only when they had a big recent twist. Every question must stay true forever: anchor it in time with a year or event name (\"at the 2026 Oscars\", \"in her 2025 album\"), never \"currently\", \"this year\", \"last week\", \"the latest\", and never ask about rankings or records that can change. Avoid CURRENT politics and CURRENT wars or armed conflicts (including countries involved in one); historical events and dark themes inside films, series or games are fine. No gossip. Mostly open questions answered in a few words; at most 3 multiple-choice. Seed facts (names may lack diacritics - write them correctly; from web research, each with a source; verify independently, skip any you cannot confirm, and you may use other equally fresh facts):
$(cat $topics)
$extra"
echo "start $lang-$id $(date '+%H:%M:%S') n=$n scope=$scope" >> $RUN/run.log
(cd $WT/apps/quiz-pack-api && $WT/.venv/bin/python scripts/generate_pack.py --direct --dry-run --language $lang --category entertainment \
   --floor-fraction 0 --target-count $n --prompt "$brief" --dedup-store noop --out $RUN/$lang-$id.json) > $RUN/$lang-$id.log 2>&1
echo "rc=$? end $lang-$id $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/$lang-$id.log)" >> $RUN/run.log
