# Issue 45: iOS MCQ voice + design-port redesign

**Triage:** enhancement · ready-for-agent (partial)
**Status:** Decomposed from handoff `docs/handoffs/handoff-2026-06-03-0859.md` (design iteration `b368bc1`→`62c6435`). **Supersedes #42 Track E (42.14–42.18)** — same MCQ-voice work, never started, folded in here with its richer detail. **Fresh-session verified against the codebase at HEAD `62c6435` on 2026-06-03** (laptop host) — line numbers, guards, helpers, test scaffolding and acceptance commands corrected; see Changelog.
**Created:** 2026-06-03
**Parent / related:** #42 (Track E moved here). Design source `design/quiz-agent.pen`; reference `docs/reference/question-types.md`.

---

## Motivation

A design iteration (Pencil) landed new question screens — tinted page bg, white cards, a reusable 4-state `AnswerOption`, MultiChoice + TrueFalse layouts, a slim "listening" pill replacing the big mic. **None of it has reached the iOS app.** Separately, the **MCQ voice path is dead**: `mcqBody` is tap-only, the recording path is guarded off for multiple-choice (`isMultipleChoice != true` guards), so a multiple-choice question cannot be answered by voice — the core functional gap for a hands-free driving app. Backend already accepts spoken MCQ answers (`_evaluate_mcq` matches key *or* value), so this is iOS-only.

### Reality check (codebase, 2026-06-03)
- **Tokens are light-only.** `Theme.Hangs.Colors` (`Utilities/Theme+Hangs.swift`) is hardcoded hex, no dark mode; page bg is still cream `#F5F1E8`. Adaptive `Color(light:dark:)` helper exists in `Utilities/Color+Theme.swift:44-64` but is unused by the Hangs layer.
- **MCQ voice blocked in 3 places:** `QuizViewModel.startRecordingOrTimer()` (`QuizViewModel.swift:773`), `QuizViewModel+Audio.swift:73` and `:101` — all `guard currentQuestion?.isMultipleChoice != true else { return }`.
- **`MCQOptionPicker`** (`Views/Components/MCQOptionPicker.swift`) uses the **old** `Theme.Colors` layer (purple `#8B5CF6`), only default+selected states, tap-only, 500ms auto-submit.
- **`mcqBody`** (`QuestionView.swift:475-502`) has no mic / no listening indicator. Voice lives entirely in `voiceBody` (`:145-172`); big mic is `floatingMicRow` (`:284-291`) → `HangsMicBlock`. Slim `waveformStrip` (`:266-280`) + `statusPill` (`:294-`) already exist.
- **No `true_false` enum case** — it's a 2-option `text_multichoice` (visual variant only, no model change). Confirmed against backend routing.

---

## Decisions / constraints

- **D1 — True/False is NOT a new type.** 2-option `text_multichoice`, visual variant of MCQ. No `QuestionType` enum case, no Codable change.
- **D2 — No backend change for voice.** `_evaluate_mcq` matches key or value; a recognized phrase submits as-is via `submitTextInput`.
- **D3 — Port dark into the `Theme.Hangs.Colors` layer**, do not revive the old `Theme.Colors` layer. Flag the two-layer duplication for later consolidation; don't fork silently (CLAUDE.md rule 7).
- **D4 — Reveal-on-result UX is an OPEN product decision** (in-place correct/incorrect reveal vs. keep jump-to-`ResultView`). Ralph must NOT guess it — built `AnswerOption` exposes the 4 states; wiring the reveal is a human task (45.7).
- **D5 — Ralph/human split by *verifiability*, not "is it iOS".** Pure logic + standalone components with unit/inspector/`.dump` tests → Ralph. QuestionView integration, layout pinning, visual fidelity vs `.pen`, simulator-driven regression → human. (Refines #42's blanket "iOS = human".)

---

## Ralph pre-flight (READ before launch) — host: agent Mac (mba)

**Host = mba.** Its Xcode is being upgraded to a 26.x toolchain (in progress 2026-06-07) to get the iOS 26 SDK that `SpeechAnalyzer` / `AnalyzerInput` need. **Launch only after that finishes** — the launcher fail-loud refuses until the toolchain is ready.

- **Launch from the laptop:**
  ```bash
  ssh mba bash code/quiz-agent/scripts/ralph/launch-issue45.sh
  ```
  `launch-issue45.sh` (mba) **fail-loud pre-flights both the iOS 26 SDK and the Xcode license** and refuses to start if either is missing — a premature launch surfaces the blocker instead of burning iterations. It **auto-selects** an iOS-26 Xcode: caller's `DEVELOPER_DIR` → system Xcode if it is already 26.x → the no-admin staged `~/Applications/Xcode-26.3.0.app`. It runs `git pull --ff-only` first, so **the prep commits below must be on `origin`** before launching. The loop picks the first unchecked `- [ ]` task each iteration (`- [HUMAN]` lines are skipped — the harness only matches `- [ ]`), commits per task on `main`, and never pushes.
- **Toolchain prerequisite (one-time, admin):** if mba ends up on the no-admin staged Xcode 26.3, an admin (`michalkalis`) must once run `sudo DEVELOPER_DIR=/Users/agent/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild -license accept`. If the upgrade instead installs a system Xcode 26.x in `/Applications` and `xcode-select`s it (license accepted during install), no override or extra step is needed. The launcher prints the exact unblock command if still license-gated.
- **Simulator / destination:** mba historically carries the **iPhone 16 family** (no iPhone 17 Pro). Acceptance commands below use `name=iPhone 16 Pro`. ⚠️ **Confirm after the upgrade**: `ssh mba 'xcrun simctl list devices available | grep iPhone'`; if more than one iOS runtime is installed, pin the 26.x one (`…,name=iPhone 16 Pro,OS=26.x`) so the name doesn't resolve to an older device.

> **Laptop fallback.** The laptop also builds on iOS 26 (verified 2026-06-03: Xcode 26.5, SDK 26.5, iPhone 17 Pro booted). To run there instead, call `scripts/ralph/ralph.sh docs/issues/issue-45-ios-mcq-voice-and-redesign.md 10` directly (no `DEVELOPER_DIR`) and substitute `name=iPhone 17 Pro` in the acceptance commands. The mba Xcode-26.3 no-admin runbook lives in `docs/handoffs/handoff-2026-06-03-1648.md`.

---

## Token values to mirror (light / dark)

`bg` `#F6F7F9`/`#161616` · `bgCard` `#FFFFFF`/`#1F1F22` · `ink` (text-primary) `#0E1A2B`/`#F4F4F4` · `muted` (text-secondary) `#6B7280`/`#9CA3AF` · `pink` `#FF3D8F` (both) · accent-primary `#8B5CF6` (both) · `greenCheck` `#22C55E` (both) · border-standard `#0E1A2B1F`/`#FFFFFF24` · border-subtle `#0E1A2B14`/`#FFFFFF14`. **Decorative translucent fills stay hardcoded** (pill bg `#FF3D8F14`, pill stroke `#FF3D8F33`, badge soft `#8B5CF620`) — they read in both modes.

---

## Tasks (atomic, Ralph-ordered)

> `- [ ]` = Ralph-suitable (machine-verifiable: compiles + a real test passes). `- [HUMAN]` = simulator / visual fidelity / product decision — Ralph harness skips these top-to-bottom. Dependency order: A → E-logic → B/C components → human integration. Each acceptance test runs with:
> `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination "platform=iOS Simulator,name=iPhone 16 Pro" -only-testing:HangsTests/<Suite>` (mba; pin `,OS=26.x` if mba has more than one iOS runtime — see pre-flight. On the laptop fallback use `name=iPhone 17 Pro`.)
> Source paths below are relative to `apps/ios-app/Hangs`, so the Swift sources live under `Hangs/` (e.g. `Hangs/ViewModels/…`).

### Track A — Design tokens (do first; everything imports them)

- [x] **45.1 Tokenize `Theme.Hangs.Colors` light/dark + tint.** Convert `bg`, `bgCard`, `bgElevated`, `ink`, `muted`, `mutedFaint` (and any border tokens listed above) to `Color(light:dark:)` using the existing helper. Change `bg` cream→`#F6F7F9`/`#161616`, `bgCard`→`#FFFFFF`/`#1F1F22`. Leave decorative `opacity()`-based fills hardcoded. Keep all legacy aliases intact.
      **Acceptance:** new `HangsColorTokenTests` resolves each adaptive token via `UIColor(...).resolvedColor(with: UITraitCollection(userInterfaceStyle:))` for `.light` and `.dark` and asserts RGB components equal the expected hex (within 1/255). `-only-testing:HangsTests/HangsColorTokenTests` GREEN; full build compiles.

### Track E (logic) — MCQ voice path (highest product value)

- [x] **45.2 `MCQTranscriptMatcher` (pure type + tests).** New value type that maps a committed transcript → matched option key (or nil). Match against: option keys (`"a"`/`"b"`…), Slovak ordinals/letters (`jedna`/`dva`/`tri`/`štyri`, `áčko`/`béčko`…), English ordinals (`one`/`two`…), and fuzzy value match against `sortedAnswerOptions`. Normalize (lowercase, strip punctuation/diacritics-aware). Ambiguous / no match → nil.
      **Acceptance:** `MCQTranscriptMatcherTests` covers key, SK ordinal, EN ordinal, value, and ambiguous→nil cases (SK + EN). `-only-testing:HangsTests/MCQTranscriptMatcherTests` GREEN.

- [x] **45.3 Remove MCQ guards + route transcript to submit.** Delete the three `isMultipleChoice` guards (`QuizViewModel.swift:773`, `QuizViewModel+Audio.swift:73,101`). In `handleCommittedTranscript(_:)`, when `currentQuestion?.isMultipleChoice == true`, run the transcript through `MCQTranscriptMatcher`; on a match submit the option **value** via the existing `submitMCQAnswer(key:value:)` / `submitTextInput` path; on no-match leave the existing re-record/fallback behavior. **No UI changes here** (mic wiring into `mcqBody` is 45.9, human).
      **Acceptance:** `QuizViewModelMCQVoiceTests` (mock services, vzor `QuizViewModelResubmitTests`): a committed transcript `"Jupiter"` and `"béčko"` on a loaded MCQ question drive `submitTextInput` with the resolved value and transition to `.processing`; a guard-removal regression asserts recording is no longer short-circuited for MCQ. GREEN. `grep -rc "isMultipleChoice != true" Hangs/ViewModels/` returns 0 for every file (all three guards removed: `QuizViewModel.swift:773`, `QuizViewModel+Audio.swift:73,101`).

### Track B — `AnswerOption` component

- [x] **45.4 `AnswerOption` SwiftUI view (4 states).** New view: circular letter badge (A/B/C/D) + answer text + optional right status badge; full-width, **64pt min height**, `cornerRadius 16`, 1.5pt border; tokens from 45.1. States: `default` (bgCard, subtle border, soft-purple badge `#8B5CF620`, purple letter) · `selected` (`#8B5CF6` border + solid badge, white letter) · `correct` (green `#22C55E` border+badge + `checkmark`) · `incorrect` (pink `#FF3D8F` border+badge + `xmark`). Preserve a11y id `mcq.option.<key>`.
      **Acceptance:** `AnswerOptionInspectorTests` (ViewInspector, vzor `HangsButtonInspectorTests`) asserts each of the 4 states renders the expected border/badge color + the right SF Symbol for correct/incorrect + a11y id present. GREEN.

- [ ] **45.5 Swap `MCQOptionPicker` internals to `AnswerOption` + token migration.** Render the option list via `AnswerOption`; replace all `Theme.Colors.*` with `Theme.Hangs.Colors.*`; keep `sortedAnswerOptions` ordering and the `onSelect(key,value)` contract and existing tap→`submitMCQAnswer` flow (no reveal behavior change — that's 45.7). Update the `.dump` snapshot baseline.
      **Acceptance:** `grep -c "Theme\.Colors\." Hangs/Views/Components/MCQOptionPicker.swift` returns 0; build compiles; existing MCQ ViewModel test (`QuizViewModelTests`) + `QuestionViewSnapshotTests` GREEN. Current QuestionView baselines are text-question states (`askingState`, `recordingState`) — they likely don't render `MCQOptionPicker`, so do NOT force a re-record; re-record a `.dump` baseline **only if** the swap actually changes an existing snapshot, and commit it in the same commit.

### Track C — Listening pill component

- [ ] **45.6 `ListeningPill` component.** Slim capsule: `audio-lines`/waveform-style icon + text, `pinkSoft` fill, pink hairline stroke. Copy by mode: open-ended "Listening — say your answer" · MCQ "Listening — say A–D or the answer" · T/F "Listening — say true or false". a11y id `question.listeningPill`. **Component only** — pinning it above Skip in the two bodies is 45.8 (human, layout).
      **Acceptance:** `ListeningPillInspectorTests` asserts the correct copy per mode + a11y id present + capsule fill/stroke colors. GREEN.

### Human integration / visual / simulator (post-Ralph, laptop)

> Convention: `- [HUMAN]` so Ralph skips them. Flip to `- [x]` when done by hand. Do these in one laptop session with the simulator + `design/quiz-agent.pen` open (node IDs in Resume context).

- [HUMAN] **45.7 Reveal-on-result UX decision + wiring.** Resolve D4 (in-place reveal vs keep `ResultView`). If reveal: drive `AnswerOption` `correct`/`incorrect` from the server result. **Acceptance:** chosen flow works on sim; correct/incorrect states show as designed.
- [HUMAN] **45.8 Pin `ListeningPill` above Skip** in both `mcqBody` and `voiceBody`, between `chipActionRow` and the Skip button (fixed vertical position). **Acceptance:** pill sits just above Skip in both screens, doesn't scroll with content.
- [HUMAN] **45.9 Remove big mic + wire mic into MCQ.** Drop `floatingMicRow`/`HangsMicBlock` from `voiceBody` (keep `transcriptCard` + slim `waveformStrip` for active state); make `mcqBody` start recording after question audio (matches non-MCQ flow) and reflect a spoken match by highlighting the matching `AnswerOption`. **Acceptance:** big mic gone; spoken answer on an MCQ on the sim highlights the option and submits.
- [HUMAN] **45.10 True/False visual variant (optional).** Render the 2 options taller (~80pt) per design. Visual only, no model change. **Acceptance:** T/F screen matches `.pen` node `WCaT6`.
- [HUMAN] **45.11 Light + dark visual QA vs `.pen`.** Toggle appearance; confirm tinted bg, white/dark cards, `AnswerOption` 4 states, pill all match `.pen` (`b8zObz`, `WCaT6`, `EZhqr`, `vAXMX`). **Acceptance:** no cream bg remains; tokens adapt; screens read as the design in both modes.
- [HUMAN] **45.12 RS regression for MCQ.** Add `RS-09 MCQ-voice` + `RS-10 MCQ-tap` to the `regression` skill; preserve `question.skip` / `question.micButton` / `question.statusPill` / `question.state` a11y IDs. **Acceptance:** both scenarios GREEN end-to-end.
- [HUMAN] **45.13 Snapshot baselines review + sign-off.** Review re-recorded `.dump` baselines for QuestionView/MCQ; confirm the meaningful structural assertions still hold (CLAUDE.md rule 9). **Acceptance:** snapshot suite GREEN, baselines reviewed not blindly accepted.

---

## Sequencing

```
Ralph:  45.1 → 45.2 → 45.3 → 45.4 → 45.5 → 45.6
Human:  45.7 → 45.8 → 45.9 → (45.10) → 45.11 → 45.12 → 45.13   (laptop + simulator + .pen)
```

45.1 (tokens) is a hard prerequisite — 45.4/45.5/45.6 reference the new tokens. 45.2 (matcher) gates 45.3. The 6 Ralph tasks are independent of the simulator; expect them to land as 6 compiling, tested building blocks. Human integration then assembles them in QuestionView + does the visual pass.

## Risks / open questions

1. **ViewInspector availability.** 45.4/45.6 assume `ViewInspector` is wired into `HangsTests` (existing `*InspectorTests` imply yes). If a component isn't introspectable, fall back to a `.dump` snapshot assertion — do NOT mark done without a real check (rule 12).
2. **Diacritics in `MCQTranscriptMatcher`.** SK ordinals carry diacritics (`štyri`); STT casing/diacritics vary. Normalize defensively and test both forms.
3. **Reveal UX (D4)** unresolved — 45.7 owns it; Ralph builds the capability, not the decision.
4. **Two color layers** — porting dark into Hangs widens the `Theme.Colors`/`Theme.Hangs.Colors` split. Flagged for a later consolidation issue, not this one.
5. **Line numbers drift** — verified at HEAD `62c6435` on 2026-06-03 (guards, helpers, landmarks, test scaffolding all confirmed present). Per `work-next.md` an iteration should still grep before editing, but the cited locations were accurate at verification time.

## Definition of done

- 45.1–45.6: six building blocks merged, each with a passing test; `mcqBody` accepts a spoken answer at the ViewModel layer; no `Theme.Colors.*` left in `MCQOptionPicker`.
- 45.7–45.13: QuestionView reflects the design in light + dark on the simulator; big mic gone; listening pill pinned above Skip; spoken MCQ answer accepted end-to-end; `RS-09`/`RS-10` GREEN.

## Changelog

- 2026-06-03 — created from handoff; absorbed #42 Track E (42.14–42.18); split tracks by verifiability (D5); pinned mba test destination to iPhone 16 Pro.
- 2026-06-07 (verification pass) — fresh-session verified at HEAD `62c6435`. Confirmed accurate: guards (`QuizViewModel.swift:773`, `QuizViewModel+Audio.swift:73,101`), `Color(light:dark:)` helper (`Color+Theme.swift:44,58`), `Theme.Hangs.Colors.bg` cream light-only, `MCQOptionPicker` 7× `Theme.Colors.`, ViewInspector wired + `Hangs-Local` scheme + `QuestionViewSnapshotTests` baselines, `submitMCQAnswer(key:value:)`→`networkService.submitTextInput(input:)`, no `true_false` enum case. Fixes: corrected grep acceptance paths to the `Hangs/` prefix (`Hangs/ViewModels/`, `Hangs/Views/Components/`) — they errored before; softened 45.5 snapshot acceptance (no forced re-record).
- 2026-06-07 (45.4) — added `AnswerOption` (4 states) + `AnswerOptionInspectorTests` (9 GREEN, iPhone 17 Pro). Added `Theme.Hangs.Colors.accentPrimary` (`#8B5CF6`, both modes — the spec's accent-primary token, not in 45.1's surface/text scope); badge-soft `#8B5CF620` kept hardcoded as `AnswerOption.softBadge` per the decorative-fills rule. Color assertions test the state→token mapping via internal computed props; ViewInspector covers letter/symbol/a11y-id structure.
- 2026-06-07 (host = mba) — retargeted the pre-flight to **mba** (its Xcode is being upgraded to 26.x); launch via `ssh mba bash code/quiz-agent/scripts/ralph/launch-issue45.sh`. Acceptance destination back to `iPhone 16 Pro` (laptop `iPhone 17 Pro` kept as documented fallback). Made `launch-issue45.sh` auto-select the iOS-26 Xcode (caller `DEVELOPER_DIR` → system 26.x → staged 26.3) so it survives whichever way the upgrade lands. Prep commits must be pushed to `origin` before launch (launcher `git pull --ff-only`).
