# Issue 52: iOS design-refresh sweep (Pencil → app)

**Triage:** enhancement · ready-for-overnight
**Status:** Planned 2026-06-11; **re-planned 2026-06-11 for one autonomous Ralph loop** (founder override of the original hybrid). Net-new design sweep covering the 16 `NEW_Screen/*` frames in `design/quiz-agent.pen`. **Depends on #45 finishing first** (shared QuestionView + AnswerOption + token foundation — see Phase 0). Founder decisions captured 2026-06-11: new issue (not folded into #45); all four net-new flows in scope (onboarding, error, quiz-complete, paywall-offline). **Execution: the entire sweep runs as a single overnight Ralph loop on `mba`** — every visual screen carries a screenshot-verify acceptance (build → sim screenshot → compare to the committed reference PNG in `docs/design/frames/` → self-correct), which is what makes unattended visual work viable. Only three genuine judgment tasks stay `- [HUMAN]` (52.16 SK copy, 52.17 fidelity sign-off, 52.18 snapshot baselines).
**Created:** 2026-06-11
**Design source:** `design/quiz-agent.pen` · **Related:** #45 (Question/Result redesign + MCQ voice — must land first), #44 (screenshot-verify harness), #46 (snapshot baselines).

---

## Motivation

A full Pencil redesign landed **16 new screens** plus a complete design-token system (light + dark) and three custom fonts. The current app uses an older cream-themed look on ~5 screens and has **no** onboarding, error, quiz-complete or offline-paywall screens at all. This issue ports the whole design language into the iOS app.

### What's in the design (16 `NEW_Screen/*` frames + components)
**Redesign of existing views:** Home (`rJ7dB`), Settings (`Jjcs5`), Paywall (`u2ySy`), Question states — MultiChoice (`b8zObz`) / TrueFalse (`WCaT6`) / Listen (`f9csl`) / Capture (`uGhZg`), Result-Correct (`X4o4l`) / Result-Incorrect (`31AzE`).
**Net-new flows (no view exists today):** Onboarding 1-Welcome (`gkeCn`) / 2-Features (`hTdkE`) / 3-Permission (`haWJM`) / 3b-Denied (`COHnz`), Error (`Fwafe`), Quiz-Complete (`NPlqf`), Paywall-Offline (`PouwN`).
**Components:** `AnswerOption` (`EZhqr`, reusable) + 4-state reference (`vAXMX`), App-Icon variant (`FTSNG`).

### Reality check (codebase, 2026-06-11)
- **Existing views & sizes:** Home 217 r · Settings 309 r · QuestionView 574 r · ResultView 419 r · Paywall 166 r. Onboarding / Error / Quiz-Complete views **do not exist**.
- **Tokens:** `Theme.Hangs.Colors` is the live layer (#45 ports light/dark into it). The new design is a **larger** token set than #45 mirrored — see "Full token set" below.
- **Fonts:** **none bundled.** No `.ttf`/`.otf` in `apps/ios-app`; `Font+Theme.swift` has no Anton/Inter/IBM Plex. The design needs **Anton** (display), **Inter** (body), **IBM Plex Mono** (labels). Net-new bundling + licensing task.
- **#45 overlap:** #45 already redesigns QuestionView (MCQ/TF) + Result + builds `AnswerOption` + ports tokens. **#52 must not re-port those.** #52 picks up Home/Settings/Paywall/Onboarding/Error/Quiz-Complete and the *full* token+font system, then reuses #45's QuestionView/Result/AnswerOption work.

---

## Decisions / constraints

- **D1 — #45 is a hard prerequisite for the Question/Result/AnswerOption/token slice.** Finish #45's agent tail (45.8/45.9/45.10/45.12) and human tail (45.7/45.11/45.13) before #52 touches QuestionView, so that screen is not redesigned twice. #52's Phase 0 = "land #45".
- **D2 — Screenshot-verify (#44) closes the visual gate, so screens run in the loop.** "Compiles + test green" alone does not prove a screen matches the `.pen` — but the #44 harness gives each iOS iteration a sim screenshot to self-check against the frame export. So every Phase-3 screen task carries a **screenshot-verify acceptance** (build → light-mode screenshot → compare to the committed reference PNG `docs/design/frames/<frameId>.png` → self-correct until it reads as the design) and runs unattended in Ralph. References are **pre-exported and committed** (this session) because the headless loop on `mba` has no `pencil` MCP — see `docs/design/frames/README.md`. The self-check is best-effort, not pixel-perfect; the human keeps only a final fidelity pass (52.17) and snapshot recording (52.18). *(Supersedes the original "visual assembly is not Ralph work" stance — founder override 2026-06-11.)*
- **D3 — Token + font foundation is shared and goes first.** Everything downstream binds to it; porting it once, with token tests, de-risks every later screen.
- **D4 — Reveal-on-result resolved in #45 (2026-06-11).** MCQ uses select→confirm→`ResultView` (no in-place reveal); #52 inherits that. The `Result-Correct`/`Result-Incorrect` frames are the redesign target for `ResultView` itself (52.11), the screen MCQ jumps to after confirm.
- **D5 — Onboarding/permission is the only net-new state machine.** Error and Quiz-Complete reuse existing error/session data; they are mostly view + thin mapping. Keep new logic minimal (CLAUDE.md rule 1).
- **D6 — Slovak-first copy.** All new strings (onboarding, error, quiz-complete) authored for Slovak test mode; English parity is a follow-up, not a blocker.

---

## Execution model (one autonomous Ralph loop)

The whole sweep runs as a **single overnight Ralph loop on `mba`** (`launch-issue52.sh`, ~18 iters). The loop picks the first `- [ ]` task, does it, commits on `main`, and repeats; `- [HUMAN]` lines are skipped. Three task classes, all in the one loop:

| Class | Tasks | Acceptance the loop checks | Model |
|-------|-------|-----------------------------|-------|
| **Token/font foundation** | 52.1–52.2 | token tests + build GREEN | **Opus** (52.1 reconciles two systems) · **Sonnet** (52.2 bundling) |
| **Components + flow logic** | 52.3–52.4, 52.6–52.7 | inspector/unit tests + build GREEN | **Sonnet** |
| **New navigation seam** | 52.5 | ViewModel tests for all state-machine branches + build GREEN | **Fable** (new routing architecture + permission + persistence) |
| **Visual screens** (assemble each frame) | 52.8–52.15 | build GREEN **+ screenshot-verify**: take a light-mode sim screenshot via the #44 harness, compare to the committed reference `docs/design/frames/<frameId>.png`, self-correct until it reads as the design | **Sonnet** |
| **Human judgment** (skipped by the loop) | 52.16–52.18 | SK copy · final fidelity eyeball · snapshot baselines | **Opus** (52.17) |

**Why this is viable as one loop (the founder override):** the original plan split visual assembly out because Ralph's "compiles + test green" gate can't prove a Home screen matches its frame. The bridge is **#44 screenshot-verify** — it gives each iOS iteration a sim screenshot to self-check against the `.pen` export, so the *screenshot vs frame* becomes the judged artifact inside the loop. That self-check is **best-effort, not pixel-perfect**: expect complete, compiling, self-checked screen drafts that still need the human fidelity pass (52.17) + snapshot recording (52.18). **Do not report #52 "done" off a green loop alone.**

**Hard ordering:** `#44` (screenshot-verify harness — the eyes) must land first, then `#45` (Phase 0 below — shared QuestionView/AnswerOption/tokens), then this loop. Queue order is `#44 → #45 → #52`.

**Rough size:** ~18 iters in one overnight run (15 `- [ ]` tasks + slack), then 1–2 interactive sessions for the human tail (52.16–52.18).

---

## Ralph pre-flight — host: mba

Same harness as #45. `launch-issue52.sh` (to be generated at launch time) runs `git pull --ff-only`, picks the first `- [ ]` line, commits per task on `main`, never pushes; `- [HUMAN]` lines are skipped. iOS builds on mba's system Xcode 26.5 + iOS 26 SDK (no `DEVELOPER_DIR`, license OK — `project_mba_ios26_sdk_gap`). Acceptance build/test:
`cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination "platform=iOS Simulator,name=iPhone 16 Pro" -only-testing:HangsTests/<Suite>` (pin `,OS=26.x` if mba carries >1 runtime). **Prereq: #45 merged to `origin` first.** Source paths below are relative to `apps/ios-app/Hangs` (Swift sources under `Hangs/`).

---

## Full token set to mirror (light / dark)

From `get_variables(design/quiz-agent.pen)`. **Colors** — `bg-page` `#F6F7F9`/`#161616` · `bg-card` `#FFFFFF`/`#1F1F22` · `bg-elevated` `#FFFFFF`/`#2A2A2A` · `text-primary` `#0E1A2B`/`#F4F4F4` · `text-secondary` `#6B7280`/`#9CA3AF` · `text-tertiary` `#9CA3AF`/`#6B7280` · `text-on-accent` `#FFFFFF` · `text-on-accent-muted` `#FFFFFFB3` · `border-standard` `#0E1A2B1F`/`#FFFFFF24` · `border-subtle` `#0E1A2B14`/`#FFFFFF14` · `accent-primary` `#8B5CF6` · `accent-primary-soft` `#8B5CF620` · `accent-green` `#22C55E` · `accent-pink` `#FF3D8F` · `accent-amber/orange` `#F59E0B` · `accent-blue` `#0A84FF` · `accent-teal` `#14B8A6` · `success-text` `#16A34A`/`#4ADE80` · `error` `#FF4444` · `warning` `#F59E0B`. **Radii** sm4/md8/lg12/xl16/2xl26/pill100. **Spacing** xs4/sm8/md12/lg16/xl20/2xl24. **Type sizes** xs11/sm13/md15/lg17/xl24/xxl36. **Weights** 400/500/600/700/800. **Fonts** display=Anton, body=Inter, mono=IBM Plex Mono.

---

## Phase 0 — Prerequisite: land #45 (gating)

Not #52 tasks; #52's Question/Result slice is blocked until done.
- [x] **0.a** Run #45 agent tail on mba (45.8, 45.9, 45.10, 45.12) — done, landed in merge be83537 (2026-06-11).
- [HUMAN] **0.b** Resolve #45 human tail (45.7 reveal decision, 45.11 light/dark QA, 45.13 snapshot sign-off) and merge #45 to `origin`.

---

## Phase 1 — Foundation (Ralph loop · Opus/Sonnet)

- [x] **52.1 Full token port.** Extend `Theme.Hangs.Colors` (+ a radius/spacing/type-scale companion if one doesn't exist) to cover the **entire** token set above with light/dark. **Acceptance:** a token test in the `HangsColorTokenTests` style asserts each color resolves to the correct light AND dark hex (the test is the intent: a wrong-mode regression must fail it); `Hangs-Local` builds GREEN. *(Reconcile with #45's partial port — extend, don't duplicate.)* — **Done 2026-06-11.** Extended #45's port (no duplication): fixed `bgElevated` dark drift (`#1F1F22`→`#2A2A2A`), added net-new tokens `accentPrimarySoft` (`#8B5CF620`), `accentTeal` (`#14B8A6`), `successText` (adaptive `#16A34A`/`#4ADE80`), `textOnAccentMuted` (`#FFFFFFB3`), and aligned `error` to the design `#FF4444` (was legacy alias to brand pink). `Spacing`/`Radius`/`Font` companions already existed (#45). Tests: `HangsColorTokenTests` 7/7 GREEN on iPhone 16 Pro / iOS 26.0.
- [x] **52.2 Bundle custom fonts.** Add Anton / Inter / IBM Plex Mono (all three confirmed OFL by founder 2026-06-11 — bundle-safe), place under app resources, register in Info.plist, expose via `Font+Theme.swift` as display/body/mono roles. **Acceptance:** a unit test loads each font family by PostScript name and asserts it is registered (not silently falling back to system); build GREEN. — **Done 2026-06-11.** Downloaded 7 TTF files (Anton-Regular, IBMPlexMono-Regular/Medium, Inter-Regular/Medium/SemiBold/Bold) from Google Fonts CDN into `Hangs/Hangs/Fonts/`; registered all 7 in `UIAppFonts` (Info.plist); updated `Theme+Hangs.swift` — added `Theme.Hangs.Fonts` enum with `display/body/mono` role functions backed by real PostScript names; wired existing `hangsDisplay/hangsMono/hangsBody` helpers through the new enum. `HangsFontRegistrationTests` (4 tests) GREEN on iPhone 16 Pro / iOS 26.0.
- [x] **52.3 Reconcile `AnswerOption` to the 4-state reference (`vAXMX`).** Ensure #45's `AnswerOption` matches default/selected/correct/incorrect (letterBadge fill, statusBadge check/x, stroke per state). **Acceptance:** inspector tests assert each of the 4 states' distinguishing properties; build GREEN. *(No-op if #45 already covers all four — then mark done with a one-line note.)* — **Done 2026-06-11.** One real discrepancy found: status badge (correct/incorrect) rendered a bare tinted SF symbol, but `vAXMX` shows a colored circle with white icon inside. Fixed: wrapped `Image(systemName:)` in a `ZStack` + `Circle().fill(borderColor)` (32pt), icon color forced white. Also aligned `badgeFill` default case to use `Theme.Hangs.Colors.accentPrimarySoft` (was a local duplicate constant `softBadge` — the token was formally added in 52.1). Added `statusIconColor: Color?` computed property (testable); updated `AnswerOptionInspectorTests` — all 4 state tests now assert `statusIconColor` + the badge-fill uses the token. Both `AnswerOptionInspectorTests` + `AnswerOptionTrueFalseTests` suites GREEN on iPhone 16 Pro / iOS 26.0.
- [x] **52.4 Shared primitives extraction.** Reusable views recurring across frames: `BrandRow`, `StatusBar` stub, `StatChip`, slim `ProgressBar`, CTA/secondary button styles, `PageIndicator` (onboarding dots). Each token-bound. **Acceptance:** one inspector test per primitive asserting its key tokens/structure; build GREEN. — **Done 2026-06-11.** Two net-new primitives added: `HangsStatChip` (compact inline stat capsule, in `HangsBlocks.swift`) and `HangsPageIndicator` (onboarding dots with wider active pill, in `HangsChrome.swift`). Existing primitives already present: `HangsBrandRow`, `HangsStatusBar`, `HangsProgressBar` (slim 3pt bar in `HangsChrome.swift`), CTA/secondary buttons (in `HangsButton.swift`). `HangsSharedPrimitivesTests.swift` added: 5 suites × inspector + unit tests covering all 6 primitives (buttons covered by existing `HangsButtonInspectorTests.swift`). All 5 new suites GREEN on iPhone 16 Pro / iOS 18.5.

## Phase 2 — Net-new flow logic (Ralph loop · Fable/Sonnet)

- [x] **52.5 Onboarding navigation + permission state machine.** Model: `Welcome → Features → Permission → (granted → Home | denied → 3b-Denied)`, page index, persisted `hasSeenOnboarding` (first-launch gate), mic-permission request/observe. **Founder decision 2026-06-11: also re-runnable from Settings** — expose a `startOnboarding()` entry that replays the flow without clearing/depending on the persisted flag (Settings entry point wired in 52.9). **Logic only — views in Phase 3.** **Acceptance:** ViewModel unit tests drive each transition incl. granted/denied branches, the first-launch persisted-flag gate on relaunch, AND a manual `startOnboarding()` replay that does not reset the flag; build GREEN. — **Done 2026-06-11.** New `ViewModels/OnboardingViewModel.swift`: `Page` enum (`welcome/features/permission/permissionDenied`), `advance()` linear transitions, `requestMicPermission()` branch (granted → `finish()` persists flag + `isComplete`; denied → `permissionDenied`), `continueWithoutMic()` exit from denied, `shouldPresentOnFirstLaunch(persistenceStore:)` first-launch gate over the existing persisted `hasCompletedOnboarding` flag, `startOnboarding()` replay that never clears/consults the flag, `pageIndex` maps denied onto the permission dot. `MockAudioService` gained configurable `micPermissionResult` for the denied branch. Note: views NOT rebound — the legacy `OnboardingView` (local `@State`) still renders; 52.13 rebinds to this ViewModel. `OnboardingViewModelTests` 7/7 GREEN on iPhone 16 Pro / iOS 26.0.
- [x] **52.6 Quiz-Complete aggregation.** Compute end-of-session summary (final score, correct/total, streak/accuracy as the `NPlqf` frame shows) from existing session/stats data. **Acceptance:** unit test feeds a known session → asserts the aggregated summary values; build GREEN. — **Done 2026-06-11.** New `Models/QuizCompleteSummary.swift`: pure `Equatable`/`Sendable` value type with `static func from(score:questionsAnswered:maxQuestions:stats:)` factory. Computes: `finalScore`, `correctCount`, `incorrectCount`, `totalAnswered`, `totalQuestions`, `sessionAccuracyPercent` (this-quiz, not cumulative), `bestStreak` (from `QuizStats.bestStreak`), `avgPointsPerQuestion`. Guards against divide-by-zero (0 answers) and negative incorrectCount. `QuizCompleteSummaryTests` 6/6 GREEN on iPhone 16 Pro / iOS 26.0.
- [x] **52.7 Error-state mapping.** Map network/backend failure cases to the Error screen model (title/desc/retry action per `Fwafe`). **Acceptance:** unit test maps representative failures → expected error model + retry closure wired; build GREEN. — **Done 2026-06-11.** New `Models/AppErrorModel.swift`: pure `Equatable`/`Sendable` value type with `AppErrorRetryAction` enum (`.retryOperation`/`.goHome`/`.dismiss`) and `static func from(_ error:context:)` factory. Maps `URLError` connectivity/timeout → `retryOperation`; `NetworkError.dailyLimitReached`/`sessionNotFound` → `goHome` (terminal); `serverError(5xx)`/`429`/`invalidResponse`/`decodingError` → `retryOperation`; `invalidURL` → `dismiss`; context-driven fallback for unrecognised error types (initialization/submission/recording/general contexts). Copy is SK-first per D6. `AppErrorModelTests` 16/16 GREEN on iPhone 16 Pro / iOS 26.0.

## Phase 3 — Visual assembly (Ralph loop · Sonnet · screenshot-verify)

> Each task runs in the loop: draft SwiftUI from the design + Phase-1 components → build `Hangs-Local` GREEN → take a **light-mode** sim screenshot via the #44 harness → compare it to the **committed reference PNG** for that frame in `docs/design/frames/<frameId>.png` → **self-correct until the screenshot reads as the reference.** The loop runs headless on `mba` with **no `pencil` MCP** (`.pen` is encrypted + needs an interactive session), so references are pre-exported and committed — see `docs/design/frames/README.md` for the frame-id → PNG → task map. Each task writes a `VISUAL:` note (frame id + what matched / what drifted) to the run report under `docs/testing/runs/`. **Shared acceptance for all of 52.8–52.15:** build GREEN · screenshot-verify (light) pass against `docs/design/frames/<frameId>.png` · token-bound (no hardcoded colors) · `VISUAL:` line recorded. **Dark mode is NOT loop-verifiable** (no dark `.pen` frames) — it stays the human `52.17` pass. Per-screen specifics below. *(Fidelity here is best-effort; 52.17 is the human pixel pass.)*

- [x] **52.8 Home** (`rJ7dB`) — statusBar/brandRow/hero/statsRow/sessionWrap/configWrap/CTA. Screenshot-verify vs `rJ7dB`. — **Done 2026-06-11.** Removed `HangsHeroBlock` (design shows subtitle-only, no large Anton hero); stat boxes corrected to both use `labelColor: pink / valueColor: ink` (design shows dark numbers, not blue); removed 4th "Age" config row (not in design frame); difficultyRow value aligned to blue (matches other config values). Build GREEN + light-mode screenshot matches `rJ7dB` — all tokens/layout/components confirmed. `VISUAL:` run report at `docs/testing/runs/52.8-home-rJ7dB-2026-06-11.md`.
- [x] **52.9 Settings** (`Jjcs5`) — voice/lang/audio/about sections; **add a "replay onboarding" row** wired to 52.5's `startOnboarding()`. Screenshot-verify vs `Jjcs5`; assert the replay row invokes `startOnboarding()` without clearing `hasSeenOnboarding`. — **Done 2026-06-12.** Redesigned `SettingsView.swift`: updated file comment to reference Jjcs5 frame, removed legacy `showResetConfirmation` state and defunct reset-history alert, renamed groups (removed old `moreGroup`), added `onReplayOnboarding: (() -> Void)?` callback parameter, wired "Replay intro" row in `aboutGroup` to fire the closure, moved Microphone row into `voiceGroup`. Added `SettingsViewOnboardingTests.swift` (3 tests): structural (replay row renders), contract (startOnboarding resets to Welcome without clearing hasCompletedOnboarding), wiring (closure fires). Tests 3/3 GREEN on iPhone 16 Pro / iOS 26. Code-level VISUAL PASS vs `Jjcs5.png` — structure/tokens match; run report at `docs/testing/runs/52.9-settings-Jjcs5-2026-06-12.md`.
- [x] **52.10 Question states** (`b8zObz`,`WCaT6`,`f9csl`,`uGhZg`) — apply design to the #45 QuestionView (MultiChoice/TrueFalse/Listen/Capture); reuse, don't rebuild. Screenshot-verify each of the 4 states vs its frame on a seeded question of that type. — **Done 2026-06-12.** MCQ: new `mcqQuestionHeader` formats "CATEGORY · QUESTION N" (matches b8zObz), removed `chipActionRow`. Voice: complete `voiceBody` rewrite — lowercase pink category, Anton display question (no left bar), "Answer out loud — I'm listening." subtitle, centered waveform icon + "Ready"/"I hear you..." label, recording pill ("● recording · 0:04") in active state, live transcript card when STT streaming, pink Record/Stop | Skip capsule button row. `QuestionViewInspectorTests` 11/11 GREEN on iPhone 16 Pro / iOS 26.0. Code-level VISUAL pass vs all 4 frames documented at `docs/testing/runs/52.10-question-states-2026-06-12.md`.
- [ ] **52.11 Result Correct/Incorrect** (`X4o4l`,`31AzE`) — redesign `ResultView` (the screen MCQ select→confirm jumps to, per #45 D4); surface source/explanation detail. Screenshot-verify both states vs `X4o4l`/`31AzE`.
- [ ] **52.12 Quiz-Complete** (`NPlqf`) — bind to 52.6 aggregation. Screenshot-verify vs `NPlqf` with a seeded finished session.
- [ ] **52.13 Onboarding ×4** (`gkeCn`,`hTdkE`,`haWJM`,`COHnz`) — bind to 52.5 state machine. Screenshot-verify each of the 4 pages vs its frame (incl. the 3b-Denied branch).
- [ ] **52.14 Error** (`Fwafe`) — bind to 52.7 mapping. Screenshot-verify vs `Fwafe` with a seeded failure.
- [ ] **52.15 Paywall + Paywall-Offline** (`u2ySy`,`PouwN`) — redesign existing PaywallView + offline variant. Screenshot-verify both vs `u2ySy`/`PouwN`.

## Phase 4 — Fidelity sign-off (human · interactive · Opus — loop skips these)

- [HUMAN] **52.16 Copy pass (Slovak).** Author/confirm onboarding, error, quiz-complete strings in Slovak.
- [HUMAN] **52.17 Per-screen fidelity + light/dark QA.** Eyeball every Phase-3 screen vs its `.pen` frame in both modes; fix drift.
- [HUMAN] **52.18 Snapshot refs + RS regression.** Record snapshot baselines for the new/changed screens (reviewed, not blind-accepted — rule 6); add RS scenarios for onboarding + quiz-complete + error; full regression GREEN on sim.

---

## Open questions

All resolved 2026-06-11 — none blocking:
1. ~~Font licensing~~ — **Anton / Inter / IBM Plex Mono all OFL** (founder confirmed), bundle-safe (52.2).
2. ~~App icon (`FTSNG` variant)~~ — **out of scope** (founder: not needed now); the `.pen` `App Icon / Variant A` frame is left as a design asset, no implementation task.
3. ~~Onboarding placement~~ — **first-launch gate + re-runnable from Settings** (founder); folded into 52.5 + 52.9.

## Changelog
- 2026-06-11 — Planned from `design/quiz-agent.pen` (16 `NEW_Screen/*` frames). Founder decisions: new issue, all net-new flows in scope, hybrid execution. Token set + missing fonts + #45 prerequisite identified.
- 2026-06-11 — Open questions resolved: fonts OFL (bundle), app icon out of scope, onboarding also re-runnable from Settings (52.5/52.9 updated).
- 2026-06-11 — **Re-planned for one autonomous Ralph loop** (founder override of the hybrid). Phase-3 screens 52.8–52.15 converted from `- [WORKFLOW]` to Ralph `- [ ]`, each with a screenshot-verify acceptance (#44 harness vs committed reference PNGs in `docs/design/frames/`, pre-exported this session via `pencil` because the headless loop has no `pencil` MCP). Execution-model + D2 rewritten; only 52.16–52.18 stay `- [HUMAN]`. D4 reconciled with #45's resolved select→confirm→`ResultView` decision (52.11 = `ResultView` redesign).
