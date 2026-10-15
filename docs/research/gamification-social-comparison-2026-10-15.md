# Gamification: comparing players with other players (2026-10-15)

**Ask (founder, 2026-10-15):** how to make Trubbo more competitive, especially by comparing a player's results with other players ("you answered like X% of players", "only X% of players knew this"). Follows the TODO item "Hra: túto otázku trafilo X % hráčov" and idea 2 of [quiz-game-fun-2026-10-14](quiz-game-fun-2026-10-14.md).

Evidence labels: **data** (experiment, peer-reviewed, first-party numbers) · **postmortem** (company or secondary write-up) · **anecdote** · **gap** (searched, nothing found).

## TL;DR

- **Per-question "X% of players knew this" can be built now with no new data collection.** The server already judges every answer and logs it with the question id (#51 — product analytics). A small aggregate per question is all that's missing.
- **Nobody has measured the effect of the "X% knew" line itself** (gap). Sporcle shows it as a stats column; The 1% Club built a whole show on it with *pre-polled* percentages. Ship it behind a switch and measure.
- **The real risk is thin data, not psychology.** With today's small player base most questions have a handful of answers. Show a percentage only above a minimum sample; never invent crowd numbers.
- **Frame comparison positively.** Rank feedback hurts people who overestimated themselves; positive normative feedback helps (data). Celebrate "you beat the crowd", console on hard misses, stay silent on easy misses.
- **Comparison works best in small groups** (N-effect, data). A global leaderboard is the weakest option; a shared daily challenge or a family/friends table is stronger.
- **Fair round comparison needs the same questions.** Rounds are random per player, so "better than 70% of rounds" compares different tests. Either compare against the *expected* score on the player's own questions, or add a daily challenge everyone plays.

## What the app already has (code recon, origin/main d40f3580)

- Every answer is judged on the server and logged as `answer_evaluated` with question id, result (correct / incorrect / partial / skip), category, question type (open vs MCQ), difficulty label. Language is only on the quiz-start event (joinable via session id). The chosen MCQ option is not stored.
- Round end is logged as `quiz_completed` with score and questions asked.
- No per-question aggregates exist; the old `usage_count` field is unused.
- Identity: anonymous device id, optional Sign in with Apple. No display names, friends or groups.
- Each round is a random pick per player. No daily or shared question set.
- Round end screen shows score + "out of N". Streak and best score were removed from all screens in #84 (drop streak/best score UI, founder 2026-07-03: "unnecessary info") — the calculation still runs silently.
- Events live in prod since 2026-10-07 (~8 days). Raw-event retention is undecided, so aggregates should be stored separately before any pruning.

## Evidence

### How others do it
- **Sporcle**: each quiz shows an average score and a per-question "% Correct" column, answers hidden until you play. A stats page, not a moment after the answer. [data: first-party UI](https://www.sporcle.com/games/Cheesewind64/random-trivia/results)
- **The 1% Club**: each question carries the % of the public who solved it; the percentages are *pre-polled* (~1,000 respondents UK), not live. Biggest UK game show of 2023. [postmortem](https://en.wikipedia.org/wiki/The_1%25_Club_(American_game_show))
- **Wordle / Wordlebot**: same puzzle for everyone each day, spoiler-free share grid; Wordlebot scores skill and luck against that day's average. Growth credited to the grid + one shared daily puzzle; no controlled test. [anecdote](https://en.wikipedia.org/wiki/Wordle), [postmortem](https://arxiv.org/pdf/2309.02110)
- **Question of the Day (Alexa)**: daily ritual, streaks, city/state leaderboard; bought by Volley. [postmortem](https://developer.amazon.com/en-US/blogs/alexa/alexa-skills-kit/2022/03/Alexa-innovators-matchbox-question-of-the-day)
- **Duolingo leagues**: weekly groups of 30 random users ranked by XP. Effect figures circulating online have no primary source. [anecdote](https://duolingo.deconstructoroffun.com/mechanics/leagues)

### Psychology
- **N-effect**: competitive motivation falls as the number of competitors rises; rivalry is strongest with few rivals or near a meaningful rank. [data](https://public.websites.umich.edu/~smgarcia/pubs/ranksandrivals.pdf)
- **Rank feedback can backfire**: showing students their rank lowered grades; harm concentrated in those who had overestimated their standing. [data, working paper](https://www.eco.uc3m.es/~acabrales/research/field_experiment.pdf)
- **Positive normative feedback helps**: improved later performance only when the feedback was positive. [data, working paper](https://repec.iza.org/dp9853.pdf)
- **Overjustification**: tangible/expected rewards undermine intrinsic motivation; positive verbal feedback raises it (d ≈ 0.3). Stats should feel informational ("you knew something rare"), not like a prize. [data, meta-analysis of 128 experiments](https://home.ubalt.edu/ntygmitc/642/Articles%20syllabus/Deci%20Koestner%20Ryan%20meta%20IM%20psy%20bull%2099.pdf)
- **Gamification overall**: positive but highly context-dependent (review of 273 studies). [data](https://www.lescahiersdelinnovation.com/wp-content/uploads/2019/06/2014-hamari_et_al-does_gamification_work.pdf)
- Rarity framing ("only 5% knew") and percentile framing ("better than X%"): no direct experiments found. [gap]

### Streaks (only lever with first-party A/B numbers)
- Duolingo: streak freeze +0.38% DAU; streak milestone animation +1.7% 7-day return; decoupling streak from daily goal +3.3% D14 retention. Duolingo itself says a broken streak demotivates and fear of losing one deters starting. [data](https://blog.duolingo.com/how-duolingo-streak-builds-habit/), [data](https://blog.duolingo.com/improving-the-streak/)

### Thin data (cold start)
- **Shrinkage**: a weighted estimate pulls low-sample items toward the overall mean: `v/(v+m)·R + m/(v+m)·C` (IMDb-style). [postmortem](https://neurobiology.substack.com/p/how-imdb-determines-top-250_27)
- **Elo for players and questions**: estimates player skill and item difficulty on the fly (Pelánek 2016); item-difficulty stability r = 0.72–0.92 in one study, biased with context-dependent variance — don't present as precise. [data](https://www.fi.muni.cz/~xpelanek/publications/CAE-elo.pdf), [data](https://pmc.ncbi.nlm.nih.gov/articles/PMC12784335)

### App Store / privacy
- Aggregated percentages from other users are fine; never expose or re-identify individual answers (guideline 5.1.2(iii)). [Apple](https://developer.apple.com/app-store/review/guidelines/)
- Data collected for one purpose can't be repurposed without consent (5.1.2(ii)). #51 chose server-side events with no consent UI for measurement; showing aggregates back as a game feature is a new use — **check the privacy policy and App Privacy labels wording before shipping** (not verified here).
- Leaderboards with user-chosen names bring user-generated-content duties (1.2: filtering, reporting, blocking). Game Center avoids that but restricts how player ids may be shown (4.5.3). [Apple](https://developer.apple.com/app-store/review/guidelines/)

## Options for Trubbo

| # | Lever | What the player gets | Evidence | Fit (car / voice) | Size |
|---|---|---|---|---|---|
| 1 | **"X% of players knew this"** after each answer | Host line + one line on the result screen | 1% Club, Sporcle (postmortem); effect itself untested | **High** — one short spoken sentence | **Small** |
| 2 | **Round vs the crowd** at round end | "On your questions the average player gets 5 of 10, you got 7" + the rarest question you got right | Positive framing (data); fair because it uses your own questions | **High** | **Small** after #1 |
| 3 | **Daily challenge** — same 5 questions for everyone | Real ranking for the day, spoiler-free text to share with friends | Wordle, Question of the Day (anecdote/postmortem); small-group comparison (data) | **Medium-high** — fits a daily drive; sharing happens after parking | **Medium** |
| 4 | **Family / friends table** | Compare with people you know, not strangers | N-effect (data) | **Medium** — needs invites, names, privacy | **Large** |
| 5 | **Streak with freeze** | Days in a row with a quiz | Duolingo A/B (data) | **Low-medium** — drives are irregular; founder removed streak UI in #84 | **Small** (logic exists) |
| 6 | **Player rating** (Elo-like "Trubbo level") | A number that rises as you beat harder questions | Elo research (data), noisy | **Medium** | **Medium**, needs data volume |

Not recommended: a global leaderboard (weakest per N-effect, UGC duties), speed scoring (unsafe while driving), prizes or coins (overjustification), percentile shown to low performers ("worse than 80%").

## How #1 and #2 would behave

**Phrasing rules (all three languages, copy-review applies):**
- Correct + rare (≤ 30% knew): celebrate the rarity — "Only 18% of players knew this."
- Correct + common: short and neutral, or silent — avoid "like 90% of players" deflating the win.
- Wrong + hard (≤ 30% knew): console — "Only 22% of players knew this one."
- Wrong + easy: silent. No "80% knew this and you didn't".
- Round end: compare actual score with the expected score on the same questions; highlight the rarest correct answer; never show a percentile below the middle.

**Thin data:**
- Show a percentage only when a question has at least ~30 real answers (tune once volume is known); below that, say nothing.
- Count only first attempts and real answers (skip regrades, non-answers, the founder's and testers' devices if identifiable).
- Separate rates per language if the same question is played in several languages (crowds differ).
- Never seed with invented numbers. If an early number is wanted, the honest option is the 1% Club method: poll real people (testers) and say so.
- **First step before building: measure how many questions in prod already have ≥ 30 answers.** If very few, #1 stays mostly silent for a while — that decides whether #3 (concentrates answers on 5 shared questions a day) should come first.

**Data:** aggregates computed from the existing answer events into a small per-question table on a schedule (e.g. hourly), delivered with the result. No change to what the app collects.

## Recommendation

1. **Build #1 + #2 together** as one small change behind a switch, with the phrasing rules above. Cheapest, voice-native, no new data collection.
2. **Then #3 (daily challenge)** — gives the first fair, real ranking, concentrates answers so percentages fill up faster, and gives a reason to share.
3. **Defer #4–#6.** Family table only with multiplayer/family mode; streaks only if the founder reverses #84.

## Open decisions for the founder

- Phrasing tone and when the host stays silent (rules above are a proposal).
- Minimum sample before showing a number (proposal: 30).
- Whether the daily challenge should follow right after, and how it relates to regular rounds (counts toward the monthly quota or not).
- Whether to revisit #84 (streaks) at all.
