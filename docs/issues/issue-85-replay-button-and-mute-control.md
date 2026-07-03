# Issue #85 — Replay as a full-size button + restore an on-screen mute control (quiz screen)

**Triage:** enhancement · needs-triage (founder-approved 2026-07-03 from UI/UX review)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (P1 design decision, founder-approved)

**Severity:** medium — driving-first: audio controls (repeat / mute) must be large, visible, and on a fixed spot. Today replay is a tiny link and mute has no on-screen affordance at all.

## Decision (founder-approved)

- **Mute:** a visible mute control **on the quiz screen** (founder: "mute určite na obrazovke kvízu").
- **Replay:** a proper **button** (not the current tiny text link).
- The **voice-command** side of replay ("Zopakuj") is handled separately in **#77** (ready-for-agent) — out of scope here; this issue is the on-screen visual controls only.

## Current state (code-verified)

- **Replay** — small text link "▶ replay question" (`play.fill` icon + `Text("replay question")`), **only in the open/voice body** (`QuestionView.swift:292-314`); MCQ questions have **no** replay control. Action: `viewModel.replayQuestionAudio()` (`QuizViewModel+Audio.swift:123-129`), gated on `canReplayAudio` (`:113-115`). A separate "read aloud" variant exists on ResultView (`ResultView.swift:95-115`).
- **Mute** — **no control on the quiz screen.** Only a Settings toggle "Speak scores aloud" bound to `settings.isMuted` (inverted) at `SettingsView.swift:153-164`. Mute *logic* already exists and is wired: guards in `QuizViewModel+Audio.swift:69-80`, `:113-114`, `:124`; persisted `QuizSettings.isMuted` (`QuizSettings.swift:58-59,…`). No `toggleMute()` / `speaker.slash` affordance exists anywhere (removed in the #52 redesign — mute originally shipped in **#13**, done, then lost).

## Recommendation

1. **Replay button:** replace the text link with a full-size secondary button, ≥44pt target, present in **both** MCQ and open/voice modes; large speaker/replay iconography (Duolingo speaker precedent). Keep `accessibilityIdentifier("question.replay")` and the existing `replayQuestionAudio()` action. Disabled state driven by existing `canReplayAudio`.
2. **Mute control:** add a visible toggle on the quiz screen (speaker / `speaker.slash`) bound to the existing `settings.isMuted` — no new state, just an affordance over the logic that already exists. Keep the Settings toggle in sync.

Cross-refs: **#83** (top-bar unify — also edits `QuestionView` chrome; **sequence these two, don't run in parallel**), **#77** (voice "Zopakuj"/hands-free — the spoken equivalent), #13 (original mute, done — lost in #52 redesign), #68 (driving audio/earcon defaults).

## Acceptance

- [ ] Replay is a full-size button (≥44pt), present on **both** MCQ and open/voice questions, calling the existing replay action; disabled when `canReplayAudio` is false
- [ ] A mute toggle is visible on the quiz screen, bound to `settings.isMuted`; toggling it silences/enables TTS and stays in sync with the Settings toggle
- [ ] Mute state persists across questions/sessions (existing `QuizSettings` persistence)
- [ ] Screenshot-verify: quiz screen (MCQ + open) showing replay button + mute control, muted and unmuted
- [ ] ViewInspector/snapshot baselines updated; RS scenarios still green
