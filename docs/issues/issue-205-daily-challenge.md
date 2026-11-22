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

- [x] **205.1 Backend: daily set.** (PR #442, deployed v156) One set per (language, date) where date = the player's local date sent by the app. 5 approved questions, mixed categories, ~1 MCQ (MCQ ratio rule), chosen once and **persisted** (new table) so everyone gets the same set even if stock changes. New endpoints only — the live 1.0 app must keep working. Behind a server switch (default ON in dev, founder flips prod).
- [x] **205.2 Backend: play + record.** (PR #442) Start a daily-challenge session reusing the existing quiz flow and server-side judging. One attempt per subject per date (a second start returns the finished result). Record each first-attempt answer (question, result) and the final score in a dedicated table — not the analytics events (retention undecided, different purpose). Exempt from the monthly quota, but keep the one-per-day guard. Erase on account delete; merge with anon → account like other usage.
- [x] **205.3 Backend: crowd stats.** (PR #442; copy review of crowd lines PR #443) For a (language, date): per question how many others answered and how many got it right; for the player: rank among today's players. Computed on request (volume is tiny); excludes the player's own answer from "others". Tests encode the rules (counts < 20, percent ≥ 20, first player, top-half-only rank).
- [x] **205.4 iOS: Home card + flow.** (PR #444) Daily challenge card at the top of Home (mockup 6): not played → "Hraj dnešnú výzvu"; played → score + live crowd line, refreshed on appear. Play uses the existing quiz screens with 5 questions and the voice flow unchanged.
- [x] **205.5 iOS: crowd strip + round end.** (PR #444) Strip under the correct-answer sticker per the rules table (mockups 1–2, position per decision 2). Daily round end (mockups 3–5 adapted): score, comparison, rarest hit last; numbers re-fetched when the screen or Home card reappears. Spoken lines per rules.
- [x] **205.6 iOS: share.** (PR #444) Share button on the daily round end: "Trubbo · denná výzva 15. 10. / ✅✅❌✅✅ 4/5 / trubbo.app" (+ rank line only in top half). No answers in the text.
- [x] **205.7 Privacy text.** (PR #849, 2026-11-18) Proposed wording ready (run report 2026-10-15); not yet on the website, needs the founder's go. Showing aggregates of other players' answers is a new use. Update the privacy policy on the website (apps/website) and note any App Privacy label change for the founder.
- [ ] **Later (not this run):** "X % hráčov" in regular rounds, reusing 205.3 per question, behind a switch, OFF until there is volume.

## Status (2026-10-15)

Backend live on prod with the switch OFF (`DAILY_CHALLENGE_ENABLED = "false"` in `apps/quiz-agent/fly.toml`; turn on = set `"true"` + deploy). Implementation notes: crowd lines are built on the server (`apps/quiz-agent/app/daily_challenge/copy.py`, copy-reviewed), the app shows them verbatim; a resumed challenge continues with the unanswered questions; an edited transcript re-grades the recorded verdict; the one-per-day guard and "others" cover every linked identity (sign-in / sign-out). Open: 205.7, the founder's call on sk "Dnes si prvý." (masculine) vs a neutral wording.

## Status (2026-11-18)

Founder: beta first, then everyone. DB switch `daily_challenge_beta_min_build` (PR #848) turns the challenge on for app builds at or above that number (CFNetwork User-Agent) while `DAILY_CHALLENGE_ENABLED` stays off; store builds are ≤ 86, Trubbo Beta is 89. Raise or clear the switch before a store build at or above it ships; for everyone set the env switch to true. First-player line is now "Prvý výsledok dňa." (founder). Next ideas: friend leagues ([návrhy A/B/C](https://claude.ai/artifact/RkMrXQ8LhGmcvQdHdBJDzp), [rešerš](../research/seasonal-themes-and-competition-2026-11-18.md)).

## Status (2026-11-22): on for everyone

Founder decided on the page "Dôvod vracať sa každý deň" ([research](../research/daily-return-rewards-2026-11-22.md)): the challenge is on for all players. `DAILY_CHALLENGE_ENABLED=true` in the server's `env/quiz-agent.env` on Hetzner (the value `fly.toml` carries is only the record; prod no longer reads it), service restarted, smoke test green, store builds get `daily_challenge_enabled: true`. Before the switch only two players had played, one day, in Slovak; a dry run on prod built a set in en, sk and cs.

Supply of questions never used in a daily set (dry run 2026-11-22): sk about 200, cs about 225, en 300 or more. At 5 a day that is roughly 40 days in sk before sets start repeating old questions; the weekly top-up adds about 15 per language, the challenge uses 35. Needs a larger batch before early January 2027.

Founder decisions for what comes next:

- **205.8 Reward (next):** finishing the day's challenge gives extra questions for that day, outside the monthly limit. Nothing else for now (no stamps, weekly pack or fact of the day). Open with the founder: how the player is told, and whether a quiet "days played" number is shown now.
- **Day count:** founder picked "days played, never resets" with the note not to burden players with another feature now. No streak that can be lost.
- **Reminders:** none, no push notifications.
- **Parked, founder liked them:** a widget with a new question every day (needs more thought); answering while the question is still read (after voice commands improve); a spoken hint (later, would complicate the app now).

## Done when

- Backend tests green (targeted suites), deployed to prod with the switch per 205.1.
- iOS unit tests for the new view models green; simulator screenshots (iPhone 18 Pro, sk) of: Home card both states, result strip for correct-rare, wrong-hard, wrong-easy (no strip), "Dnes si prvý.", daily round end good + weak, share text. One page with these for the founder at the end.
- PRs merged through the normal review flow (main, not release/1.0). **No TestFlight build** unless the founder asks.
- TODO line and this file updated with PR numbers.
