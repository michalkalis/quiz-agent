# Issue #205 — Denná výzva: hráč proti davu

**Triage:** enhancement · ready-for-agent

**Created:** 2026-10-15 · **Founder:** Michal · **Source:** [rešerš](../research/gamification-social-comparison-2026-10-15.md) + [návrh s náhľadmi](https://claude.ai/artifact/ChuQmJBB3H4pQhGBhEp4Dq) (mockupy 1–6; pravidlá nižšie majú prednosť pred artefaktom)

## Goal

Make Trubbo competitive by comparing the player with other players. Start with a **daily challenge**: 5 questions, the same for everyone in a language on a given date. It works with a single player and the crowd numbers fill in live as more people play. Success = the founder can play today's challenge on the simulator/TF, sees "Dnes si prvý." and later sees the numbers update after a second player plays.

## Founder decisions (2026-10-15)

1. Only the founder plays today; beta adds a few. A 30-answer threshold is unrealistic → **daily challenge first**, shows crowd data from the first other player on, updates live as more play.
2. The crowd strip is **always in one place**: directly under the correct-answer sticker on the result card (correct and wrong alike; on a wrong answer it sits above the struck-through user answer).
3. **Short texts**, no filler words. Applies to screen copy and host lines.
4. Daily challenge does **not** count toward the free monthly quota.
5. Small crowds: **counts first, then percent**. Fewer than 20 players → "Vedeli 2 z 3."; from 20 → "Vedelo 14 %." First player of the day → "Dnes si prvý."
6. No streaks (#84 — drop streak/best score UI stays).
7. **Future, not in scope:** rewards for completing/winning a challenge (a few free questions or a free custom pack) and a small reward for the first player of the day. Monetization decision → founder later.

## Rules (from research, see the research doc for sources)

| Case | Strip on screen | Host says (sk example) |
|---|---|---|
| Correct, rare (≤ 30% of others knew) | yes | right after the verdict: "Vedelo to len 14 %." |
| Correct, common | yes, plain | nothing about the crowd |
| Wrong, hard (≤ 30% knew) | yes | after the explanation: "Väčšina to nevie." |
| Wrong, easy | **no strip** | nothing about the crowd |
| First player | "Dnes si prvý." | nothing |

- At most 3 crowd lines spoken per challenge; vary wording. One short sentence each, appended to the existing feedback utterance (no extra TTS call — ElevenLabs is 98% of spend).
- Round end order: score → comparison → **rarest correct answer last** (peak-end). Rank ("Lepší ako 64 % z 12 hráčov") only when the player is in the top half; otherwise "Ťažká výzva." + best hit. Never "horší ako…".
- Only real numbers, never seeded or estimated. Only aggregates are shown, never another player's answers.
- sk/cs/en together, short, no dashes as punctuation, copy-review CI applies.

## Sub-tasks

- [ ] **205.1 Backend: daily set.** One set per (language, date) where date = the player's local date sent by the app. 5 approved questions, mixed categories, ~1 MCQ (MCQ ratio rule), chosen once and **persisted** (new table) so everyone gets the same set even if stock changes. New endpoints only — the live 1.0 app must keep working. Behind a server switch (default ON in dev, founder flips prod).
- [ ] **205.2 Backend: play + record.** Start a daily-challenge session reusing the existing quiz flow and server-side judging. One attempt per subject per date (a second start returns the finished result). Record each first-attempt answer (question, result) and the final score in a dedicated table — not the analytics events (retention undecided, different purpose). Exempt from the monthly quota, but keep the one-per-day guard. Erase on account delete; merge with anon → account like other usage.
- [ ] **205.3 Backend: crowd stats.** For a (language, date): per question how many others answered and how many got it right; for the player: rank among today's players. Computed on request (volume is tiny); excludes the player's own answer from "others". Tests encode the rules (counts < 20, percent ≥ 20, first player, top-half-only rank).
- [ ] **205.4 iOS: Home card + flow.** Daily challenge card at the top of Home (mockup 6): not played → "Hraj dnešnú výzvu"; played → score + live crowd line, refreshed on appear. Play uses the existing quiz screens with 5 questions and the voice flow unchanged.
- [ ] **205.5 iOS: crowd strip + round end.** Strip under the correct-answer sticker per the rules table (mockups 1–2, position per decision 2). Daily round end (mockups 3–5 adapted): score, comparison, rarest hit last; numbers re-fetched when the screen or Home card reappears. Spoken lines per rules.
- [ ] **205.6 iOS: share.** Share button on the daily round end: "Trubbo · denná výzva 15. 10. / ✅✅❌✅✅ 4/5 / trubbo.app" (+ rank line only in top half). No answers in the text.
- [ ] **205.7 Privacy text.** Showing aggregates of other players' answers is a new use. Update the privacy policy on the website (apps/website) and note any App Privacy label change for the founder.
- [ ] **Later (not this run):** "X % hráčov" in regular rounds, reusing 205.3 per question, behind a switch, OFF until there is volume.

## Done when

- Backend tests green (targeted suites), deployed to prod with the switch per 205.1.
- iOS unit tests for the new view models green; simulator screenshots (iPhone 18 Pro, sk) of: Home card both states, result strip for correct-rare, wrong-hard, wrong-easy (no strip), "Dnes si prvý.", daily round end good + weak, share text. One page with these for the founder at the end.
- PRs merged through the normal review flow (main, not release/1.0). **No TestFlight build** unless the founder asks.
- TODO line and this file updated with PR numbers.
