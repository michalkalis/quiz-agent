#!/usr/bin/env zsh
# Founder 2026-10-08: native sk/cs corpus questions (not translated from EN), country-specific.
# Usage: run_gen.sh <sk|cs> <batch-id> <target-count> "<theme>"   — dry-run, JSON only, no DB writes.
set -u
lang=$1; id=$2; n=$3; theme=$4
WT=/Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent-wt-native
RUN=$WT/docs/testing/runs/native-sk-cs-2026-10-08
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
export LLM_GATEWAY=session
if [ $lang = sk ]; then country=Slovakia; people=Slovaks; other=Czech; else country="the Czech Republic"; people=Czechs; other=Slovak; fi
brief="Corpus questions for adults who live in $country and play in their own language. Every question must be specific to $country: something $people know from school, news, travel or everyday life, or would enjoy learning about their own country. Shared Czechoslovak history and culture is welcome, told from the perspective of $people. Do not ask about facts that are equally known worldwide, and do not ask obscure trivia that only specialists know. Do not ask about $other-only topics. Theme of this batch: $theme. Vary the subtopics within the theme."
echo "start $lang-$id $(date '+%H:%M:%S') n=$n theme=$theme" >> $RUN/run.log
(cd $WT/apps/quiz-pack-api && $WT/.venv/bin/python scripts/generate_pack.py --direct --dry-run --language $lang \
   --target-count $n --prompt "$brief" --dedup-store noop --out $RUN/$lang-$id.json) > $RUN/$lang-$id.log 2>&1
echo "rc=$? end $lang-$id $(date '+%H:%M:%S') $(grep -E '^questions:' $RUN/$lang-$id.log)" >> $RUN/run.log
