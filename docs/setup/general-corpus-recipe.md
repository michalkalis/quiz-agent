# General corpus recipe (non-entertainment)

The default way to generate questions for the general categories (history, science, geography, food, sports, movies-music). It comes from the #203 blind tests of 2026-10-14: `docs/issues/issue-203-stock-questions.md`. Entertainment has its own recipe: `fresh-entertainment-recipe.md`.

What the founder's ratings showed:
- The 2026-10-01 bulk batch (Fable 5, 15 questions per broad theme) scored about 2/10. Questions generated fresh on Opus 5.5 scored 7.3 to 8.4, whatever the prompt.
- The old `v2_cot` prompt and today's `direct_v1` tied (7.4 vs 7.3), so the prompt stays `direct_v1`.
- The founder-taste brief beat the 10-08 native Slovak recipe (8.1 vs 7.5): fewer years and school-textbook questions. In English it tied today's recipe (8.4 vs 8.3 for the anchor).
- Ratings drift between rounds (the same anchor recipe got 7.3, then 8.3). Always compare arms within one round.

## Settings

Start from `docs/testing/runs/general-corpus-2026-10-14/run_arm.sh`. Copy it to the new run directory with a new `themes_full.json`. It keeps every question that cleared all gates even when a 4-question batch comes out short (`--floor-fraction 0`; the default floor threw away whole batches), stops on a subscription-limit error, and skips finished themes when rerun.
- **Model:** Opus 5.5, pinned (`GENERATION_MODEL`, `GEN_ALT_SHARE=0`). With `GATEWAY=session` the subscription runs it through the `opus` alias.
- **Pipeline:** the prod-parity pins in the script (= `app/corpus/fresh_pins.py`), plus `--no-judges --direct --dry-run`. Dedup runs against prod through the `fly proxy` tunnel on :15432.
- **Brief:** `--prompt` = `docs/testing/runs/taste-2026-10-14/taste_brief.txt`, built from 507 founder-rated questions. For sk/cs the script appends the home-country paragraph: about 7 in 10 questions about that country or its everyday life.
- **Batch shape:** 2 questions per theme (`--target-count 2 --per-topic-cap 2`), many narrow themes. Never 15 per broad theme. The 2026-10-14 round at 2 per theme scored 8.0 to 8.7 ("a completely different level", founder), against 7.6 to 8.5 at 4 per theme in an earlier round.
- **Themes:** half hand-written, half model-brainstormed (founder 2026-10-14). Model themes: `docs/testing/runs/topics-pilot-2026-10-14/brainstorm_prompt.txt` through `claude -p --model opus` on the subscription, 150 per language, with the prod topic list to avoid; they bring scenes, hobbies and things people actually do (blind: model 8.0, hand-written 8.7, both above the gate). Never riddles ("what am I": 1/10, "childish cliché"). Hand-written themes are For example "kitchen science", "words we borrowed", "why things are named what they are", "hidden reasons behind everyday habits", "famous things with a twist", "maps and borders puzzles", "animals that break the rules". Avoid Russia, years and dates, award winners and obscure people (the brief says so too).
- **Pilot arms (task 203.8, themes from the model):** the pilot compares hand-written themes (H) with themes the model brainstorms itself (M: ~150 narrow everyday themes per language, minus topics already in the stock, 2 questions per theme). Blind sample per language = 10 H + 10 M in one round. The full run uses whichever wins.
- **Languages:** native en, sk and cs runs, each language generated directly. A native sk/cs row is served only to players of that language.

## Gate before anything goes live

1. A pilot of about 20 questions per language through the exact production path (the same gateway as the full run).
2. The founder blind-rates a sample of 20 on the rating page. Reuse `build_sample.py` and `rating_template.html` from `taste-2026-10-14`.
3. Run the full batch only when the pilot averages ≥ 7/10. The same rule holds for every bulk batch (founder 2026-10-14): a 20-question blind sample, and import only at ≥ 7.
4. Before import, remove same-fact duplicates inside the run. Generation dedups only against prod, so one fact can come out in several batches and languages (pilot 2026-10-14: 8 pairs in 58 questions). `run_dups.py <run-dir>` lists the questions; a Sonnet subagent names the same-fact pairs (same language, or en vs sk/cs, since en rows reach every player; never sk vs cs). Keep the en row, drop the sk/cs copy; within a language drop the later one. Embedding similarity alone missed most cross-language pairs.
5. Import with `scripts/import_questions_json.py`, following the pattern of `docs/testing/runs/native-sk-cs-2026-10-08/run_import.sh`.

## Cost

About 9 cents per question on the direct API with 4-question batches; verification is most of it. On the subscription the money cost is zero, but watch the 5-hour window and keep about 20 % in reserve.
