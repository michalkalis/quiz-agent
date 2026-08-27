# #131 — TF feedback 2026-07-29: voice-screen layout v2, timer, submit OOPS, result skip state

**Triage:** Approved (founder feedback batch, TestFlight staging build with the 2026-07-28 redesign)
**Source:** founder on-device test 2026-07-29 ~10:34–10:44 (4 screenshots in session)

Founder feedback partially **supersedes the 2026-07-28 ListenBar addendum** (docs/design/ui-variants-2026-07-28-decisions.md): the docked bar stays, but the think-chip removal + answer-mode bar swap did not survive contact with real use.

## Tracks

### A — Submit/skip "OOPS" failure (bug, P0)
Symptom: "Couldn't submit your answer" after voice submit AND after Skip (10:40).
Root cause (Sentry-confirmed, 5× HTTP error 08:39–08:40 UTC same trace): staging
`auto_stop_machines` cold wake + **no retry on the submit path**; quiz-start already has
`isTransientStartError` retry (QuizViewModel.swift:963-979) but submit/skip does not.
Contributors: `RecordingCoordinator+Submission.swift:115-123` swallows the error object
(always generic OOPS); backend `/sessions/{id}/input` (quiz.py:185-220) + `UsageTracker.check_limit`
(tracker.py:96) have no exception wrapping → raw 500.
Fix: reuse transient-retry on submit/skip (iOS), pass the real error to `setError`,
wrap backend input route + quota check with a distinguishable error response.

### B — Think-timer must never stop early + countdown moves into Record button
Founder rule: **after the question is read, the countdown never stops until the answer
is submitted or time expires.** The 2026-07-28 "think-timer gone in Recording state" call
is reversed.
- Remove the `THINK Xs` chip (QuestionView.swift:364, audioStrip 287-291).
- Record button becomes a `HangsPrimaryButton` with countdown fill + remaining seconds
  (same treatment as Confirm/Next question — HangsButton.swift:39-91). Stop state keeps
  the fill running.
- Audit cancel paths (QuizTimersController.swift:140-143 callers): Record tap / voice
  "start" must NOT kill the visible countdown; recording continues the same window.
  On expiry mid-recording: auto-stop + submit transcript (preserve existing expiry
  consequence otherwise). Tick guard `quizState() == .askingQuestion` (118-121) must not
  zero the timer during recording states.

### C — Question-screen footer relayout (explicit founder spec)
- Bottom row order: **Record · Type · Skip** — "Type answer instead" shrinks to icon +
  "Type" (SK "Písať"), moves from its floating spot (QuestionView.swift:782-803) into the
  footer row (voiceActionRow 723-778).
- **ListenBar (command mode):** show concrete commands, not just "POČÚVAM PRÍKAZY" —
  contextual sub-line like the result screen's `Povedz „ďalej"` (e.g. `Povedz „štart" ·
  „preskoč"`). No-match (amber) state must be actionable: swap sub-line to a corrective
  hint, not colour alone.
- **Remove the mute button from ListenBar** (ListenBar.swift:161-175). Mute stays
  available in the question audio strip (QuestionView.swift:343-359, #85 heritage) —
  the bar copy was a duplicate. Verify the strip remains reachable in all states the
  bar shows.
- **Recording state:** hide the pink "LISTENING — SAY YOUR ANSWER" bar (QuestionView.swift:683-693)
  — the transcript card is the recording surface. Restyle `transcriptCard`
  (QuestionView.swift:381-394) to carry the live-listening affordance (waveform icon +
  pink accent, ListenBar-like header) so the state is still obvious.

### D — Result screen: skip state + button order (+ design-gated hierarchy pass)
- **Skip must not render "MISSED IT / not quite"** — `Evaluation.skipped` currently falls
  through `isCorrect == false` into `.incorrect` (ResultView.swift:102-108,
  ResultScreenSections.swift:36). Add a distinct `.skipped` verdict: neutral palette,
  "SKIPPED." (SK "PRESKOČENÉ."), no strikethrough "you said · skipped" row duplication.
  Check timeout path for the same conflation.
- **RESUME/STAY pill moves to the RIGHT of "Next question"** (ResultFooter,
  ResultScreenSections.swift:332-409).
- Broader hierarchy/consistency pass (make primary elements dominant, unify texts) is
  **design-gated**: HTML variants → founder pick → Pencil → code. Ride with Track F.

### E — Volume "changes by itself" (diagnosis, likely no code fix)
No code writes hardware volume (no MPVolumeView/outputVolume anywhere). Mechanisms that
*read* as volume change: `.playAndRecord`↔`.playback` category swap for TTS
(AudioService.swift:303-389, ±6 dB gain) and Bluetooth route/mode swaps using a different
iOS volume table (call vs media volume — #104 territory). Do NOT churn audio-session
code casually (car-audio #104 fixes live there). Action: explain to founder; if the
hardware slider provably moves, capture route+category telemetry on the next drive.

### F — Component/style library (design debt)
Founder: every screen feels like it has its own components. Reality: `ListenBar` (question
screen) vs `CmdListenBar` (Home/Result/Confirmation) both exist by design; transcript
card, chips, pills are per-screen. Plan: consolidate on ONE listening-bar component
app-wide + tokenised chips/cards in `design/quiz-agent.pen` (V1 rule already exists),
then mirror in SwiftUI. Needs its own design session; not part of this fix run.

## Order of work
1. Track A backend (deployable alone) → staging.
2. Tracks A-iOS + B + C in one iOS batch (same files), then D.
3. `xcstringstool sync` + Slovak strings for all new copy (xcstrings gotcha).
4. Targeted tests + snapshot re-record; TF staging build.
5. Track D hierarchy pass + Track F → separate design round (HTML variants).

## Acceptance
- Skip and voice submit survive a staging cold wake (retry, no OOPS on first hiccup).
- Countdown visibly runs from TTS-end to submit/expiry in every path (record, replay,
  command, barge-in); lives in the Record/Stop button with seconds.
- Footer = Record · Type · Skip; no mute on the bar; recording shows transcript card
  with listening affordance and no duplicate answer bar.
- Command bar shows concrete commands; no-match shows a corrective hint.
- Skipped result shows neutral "SKIPPED." verdict; RESUME sits right of Next question.
- All new strings localized (EN+SK), tests green, TF build uploaded.

## TODO detail (migrované z TODO.md 2026-08-26)

> - [~] #131 TF feedback 2026-07-29 — voice-screen layout v2 + timer + submit OOPS + result skip state — [plan](../issues/issue-131-tf-feedback-2026-07-29.md) — founder test of the 2026-07-28 redesign build. Tracks: A submit/skip OOPS (P0, staging cold-wake + no retry, Sentry-confirmed) · B think-timer never stops early, countdown moves into Record button (reverses part of the ListenBar addendum) · C footer Record·Type·Skip + concrete command hints + mute off the bar + transcript replaces answer-mode bar while recording · D result skip state ("SKIPPED." verdict) + RESUME right of Next question · E volume self-change = category/route gain, not a hardware write (explain, don't churn #104 audio code) · F one listening-bar component app-wide + .pen component library (design session, later). **Tracks A–D SHIPPED 2026-07-29** (`99d79a8d` backend · `cea285ec`+`0cb680b0` question screen · `9690abe0` result; backend deployed PROD, **staging deploy blocked — `.env` FLY_API_TOKEN is app-scoped to `quiz-agent-api`, founder must mint a staging token**; **TF staging build run 30443085038 SUCCESS + uploaded**). **Same-day round 2:** founder confirmed the fixes on device; staging deploy DROPPED (founder: staging parked, prod backend in use); hardware-volume self-change CONFIRMED → observe-only Sentry telemetry shipped (`c3d63099`); D+F variants built → founder picked **D = Variant A "Verdikt vládne"**, **F = Option B full/slim ListenBar** ([decisions](../../docs/design/ui-variants-2026-07-29-decisions.md)) → Pencil synced (question X6eJY/yLAW3/YDJ7L · result ylNB9/VIiJt/rVk10 · component lib Sj5Xb; CmdListenBar archived; **founder ⌘S pending**) → implemented `df81af78`+`c009be92` (verdict band + one-line meta row, chip deleted, `CmdListenBar.swift` deleted → one ListenBar `.full/.slim`; **supersedes #84's "no streak on result" — streak lives only in the meta row**, tests rewritten); 858 HangsTests green; also deployed the out-of-band repeat-questions backend fix `07dcbbf9` to prod (472 green). Remaining: founder ⌘S + on-device look at the new result screen · volume-telemetry field repro · watch: long-explanation fade-clip at card bottom (pre-existing #127 scroll, band now taller) · 3 stale canonical .pen frames still on archived CmdListenBar.

