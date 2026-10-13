#!/usr/bin/env zsh
# #201.4 blind comparison (2026-10-13): arm A = the 10-08/10-12 fresh recipe, arm B = fame-first seeds + brief v2 +
# casual-player check in shadow. Same day, pinned generator (Opus 5.5, no GEN_ALT), dry-run JSON only, no DB writes.
# Usage: run_arm.sh <A|B> <en|sk> <target-count>
set -u
arm=$1; lang=$2; n=$3
RUN=${0:A:h}; OUT=${0:A:h}; WT=${RUN:h:h:h:h}
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session PYTHONPATH=$WT/packages/shared GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0
map="claude-opus-5-5=claude-opus-5-5"
today=$(date +%Y-%m-%d)
anchor="Every question must stay true forever: anchor it in time with a year or event name (\"at the 2026 Emmys\", \"in her 2026 album\"), never \"currently\", \"this year\", \"last week\", \"the latest\", and never ask about rankings or records that can change. Avoid CURRENT politics and CURRENT wars or armed conflicts (including countries involved in one); historical events and dark themes inside films, series or games are fine. No gossip. Mostly open questions answered in a few words; at most 3 multiple-choice."
case $lang in
  en) aud="adults anywhere in the world"
      focus="Every question is about global entertainment (film, TV and streaming, music, video games, pop-culture moments) that a casual fan anywhere would recognise." ;;
  sk) aud="adults who live in Slovakia and play in Slovak"
      # Small-market pop culture: the blind proxy stands in with sonnet in both arms (10-08 recipe).
      map="$map,deepseek-v4-flash=sonnet"
      focus="About half the questions are about the Slovak entertainment scene (film, TV and streaming shows, music, celebrities, awards), the rest about global entertainment known in Slovakia. Only the BIGGEST things an ordinary viewer noticed. Do not ask about the Czech scene unless it is genuinely shared." ;;
esac
if [ $arm = A ]; then
  fresh="Freshness: ask about things that happened or came out recently, mostly between July and October 2026 (today is $today); older events only when they had a big recent twist."
  player=""
else
  [ $lang = sk ] && focus="Most questions (about 7 in 10) are about the Slovak entertainment scene: Slovak celebrities, reality and TV shows, domestic hits, films and moments people in Slovakia talked about; the rest are world mega-hits well known in Slovakia. Do not ask about the Czech scene unless it is genuinely shared."
  [ $lang = en ] && focus="Every question is about global entertainment (film, TV and streaming, music, video games, viral pop-culture moments) that a casual fan anywhere in the world, not only in the US, would recognise."
  fresh="Freshness: most questions are about things that happened or came out recently, mostly between July and October 2026 (today is $today); the rest may be surprising facts about mega-famous films, songs, shows or games."
  player="Who must be able to answer: an ordinary adult who follows film, TV, music and celebrities only loosely. Pick a famous thing first, then a surprising angle. Both the subject and the detail you ask for must be something such a player could have caught, half-remembers or can reason their way to. Do not build questions around awards (who won, what was won) or around people behind the camera (directors, producers, puppeteers and other crew; famous singers and songwriters are fine), not even by asking it the other way round, and skip topics only US audiences or fans would know. If a seed is about these, skip it. Never ask an open question whose answer is a number: make it a multiple-choice question with 3 clearly different options, or pick another fact. No giveaways: the wording must not name or uniquely describe the answer."
fi
export LLM_SESSION_MAP="$map"
brief="FRESH entertainment questions for $aud. $focus $player $fresh $anchor Seed facts (names may lack diacritics - write them correctly; from web research on $today, each with a source; verify independently, skip any you cannot confirm, and you may use other equally fresh facts):
$(cat $RUN/B-topics-$lang.md)

$(cat $RUN/covered.txt)"
out=$OUT/$arm-$lang.json
echo "start $arm-$lang $(date '+%H:%M:%S') n=$n" >> $OUT/run.log
(cd $WT/apps/quiz-pack-api && /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.venv/bin/python scripts/generate_pack.py --direct --dry-run --language $lang --category entertainment \
   --floor-fraction 0 --target-count $n --prompt "$brief" --dedup-store noop --out $out) > $OUT/$arm-$lang.log 2>&1
echo "rc=$? end $arm-$lang $(date '+%H:%M:%S') $(grep -E '^questions:' $OUT/$arm-$lang.log)" >> $OUT/run.log
