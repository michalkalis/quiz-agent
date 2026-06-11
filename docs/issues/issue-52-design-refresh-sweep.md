# Issue 52: iOS design-refresh sweep (Pencil → app)

**Triage:** enhancement · ready-for-planning-review
**Status:** Planned 2026-06-11. Net-new design sweep covering the 16 `NEW_Screen/*` frames in `design/quiz-agent.pen`. **Depends on #45 finishing first** (shared QuestionView + AnswerOption + token foundation — see Phase 0). Founder decisions captured 2026-06-11: new issue (not folded into #45); all four net-new flows in scope (onboarding, error, quiz-complete, paywall-offline); **hybrid execution** (Ralph for foundation/logic, visual Workflow for screen assembly, interactive sessions for fidelity sign-off).
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
- **D2 — Ralph's exit gate ≠ visual fidelity.** "Compiles + test green" does not prove a screen matches the `.pen`. Therefore **screen-level visual assembly is NOT unattended-Ralph work.** Ralph owns only the machine-verifiable slice (tokens, fonts, component structure, flow logic). Visual assembly runs as an attended Workflow with a screenshot-vs-design judge; final fidelity is a human sign-off.
- **D3 — Token + font foundation is shared and goes first.** Everything downstream binds to it; porting it once, with token tests, de-risks every later screen.
- **D4 — Reveal-on-result (#45 D4) stays a #45 decision.** #52 inherits whatever #45 lands; Result-Correct/Result-Incorrect frames here are the visual target for that wiring.
- **D5 — Onboarding/permission is the only net-new state machine.** Error and Quiz-Complete reuse existing error/session data; they are mostly view + thin mapping. Keep new logic minimal (CLAUDE.md rule 1).
- **D6 — Slovak-first copy.** All new strings (onboarding, error, quiz-complete) authored for Slovak test mode; English parity is a follow-up, not a blocker.

---

## Execution model (hybrid — three tracks)

| Track | Scope | Where / how | Model | Attended? |
|-------|-------|-------------|-------|-----------|
| **A — Ralph foundation+logic** | tokens, fonts, AnswerOption reconcile, shared primitives, onboarding state machine, quiz-complete aggregation, error mapping | Ralph loop on **mba**, overnight (`launch-issue52.sh`); picks first `- [ ]` | **Sonnet** | No (1-min morning sign-offs) |
| **B — Visual assembly** | draft each screen from its `.pen` frame + components → build → sim screenshot → vision-judge vs `.pen` export → iterate to fidelity threshold | **Workflow** (laptop, founder present) — one pipeline item per screen | Sonnet draft + **Opus** judge | Yes |
| **C — Fidelity sign-off** | per-screen eyeball vs `.pen`, light/dark QA, record snapshot refs, RS regression, product copy | Interactive sessions with founder | **Opus** | Yes |

**Why not pure Ralph (the thing you asked me to weigh):** Ralph is ideal where the loop's stop condition equals success. For tokens/fonts/logic it does (a token test or a permission-flow unit test genuinely passes or fails). For a redesigned Home screen it does **not** — the view can compile and pass an inspector test while looking nothing like the frame. Track B closes that gap by making the *screenshot vs `.pen` export* the judged artifact (mba/laptop can drive the simulator — #44 harness + `regression` skill already do). Track C keeps a human as the final visual gate because snapshot references must be recorded by a human before they can guard anything.

**Rough size:** ~18 tasks; Track A ≈ 1 overnight Ralph run, Track B ≈ 2–3 attended workflow sessions (8 screens), Track C ≈ 1–2 sessions. Total ≈ 8–12 working sessions.

---

## Ralph pre-flight (Track A only) — host: mba

Same harness as #45. `launch-issue52.sh` (to be generated at launch time) runs `git pull --ff-only`, picks the first `- [ ]` line, commits per task on `main`, never pushes; `- [HUMAN]` / `- [WORKFLOW]` lines are skipped. iOS builds on mba's system Xcode 26.5 + iOS 26 SDK (no `DEVELOPER_DIR`, license OK — `project_mba_ios26_sdk_gap`). Acceptance build/test:
`cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination "platform=iOS Simulator,name=iPhone 16 Pro" -only-testing:HangsTests/<Suite>` (pin `,OS=26.x` if mba carries >1 runtime). **Prereq: #45 merged to `origin` first.** Source paths below are relative to `apps/ios-app/Hangs` (Swift sources under `Hangs/`).

---

## Full token set to mirror (light / dark)

From `get_variables(design/quiz-agent.pen)`. **Colors** — `bg-page` `#F6F7F9`/`#161616` · `bg-card` `#FFFFFF`/`#1F1F22` · `bg-elevated` `#FFFFFF`/`#2A2A2A` · `text-primary` `#0E1A2B`/`#F4F4F4` · `text-secondary` `#6B7280`/`#9CA3AF` · `text-tertiary` `#9CA3AF`/`#6B7280` · `text-on-accent` `#FFFFFF` · `text-on-accent-muted` `#FFFFFFB3` · `border-standard` `#0E1A2B1F`/`#FFFFFF24` · `border-subtle` `#0E1A2B14`/`#FFFFFF14` · `accent-primary` `#8B5CF6` · `accent-primary-soft` `#8B5CF620` · `accent-green` `#22C55E` · `accent-pink` `#FF3D8F` · `accent-amber/orange` `#F59E0B` · `accent-blue` `#0A84FF` · `accent-teal` `#14B8A6` · `success-text` `#16A34A`/`#4ADE80` · `error` `#FF4444` · `warning` `#F59E0B`. **Radii** sm4/md8/lg12/xl16/2xl26/pill100. **Spacing** xs4/sm8/md12/lg16/xl20/2xl24. **Type sizes** xs11/sm13/md15/lg17/xl24/xxl36. **Weights** 400/500/600/700/800. **Fonts** display=Anton, body=Inter, mono=IBM Plex Mono.

---

## Phase 0 — Prerequisite: land #45 (gating)

Not #52 tasks; #52's Question/Result slice is blocked until done.
- [ ] **0.a** Run #45 agent tail on mba (45.8, 45.9, 45.10, 45.12) — already queued in #45.
- [HUMAN] **0.b** Resolve #45 human tail (45.7 reveal decision, 45.11 light/dark QA, 45.13 snapshot sign-off) and merge #45 to `origin`.

---

## Phase 1 — Foundation (Track A · Ralph · Sonnet)

- [ ] **52.1 Full token port.** Extend `Theme.Hangs.Colors` (+ a radius/spacing/type-scale companion if one doesn't exist) to cover the **entire** token set above with light/dark. **Acceptance:** a token test in the `HangsColorTokenTests` style asserts each color resolves to the correct light AND dark hex (the test is the intent: a wrong-mode regression must fail it); `Hangs-Local` builds GREEN. *(Reconcile with #45's partial port — extend, don't duplicate.)*
- [ ] **52.2 Bundle custom fonts.** Add Anton / Inter / IBM Plex Mono (all three confirmed OFL by founder 2026-06-11 — bundle-safe), place under app resources, register in Info.plist, expose via `Font+Theme.swift` as display/body/mono roles. **Acceptance:** a unit test loads each font family by PostScript name and asserts it is registered (not silently falling back to system); build GREEN.
- [ ] **52.3 Reconcile `AnswerOption` to the 4-state reference (`vAXMX`).** Ensure #45's `AnswerOption` matches default/selected/correct/incorrect (letterBadge fill, statusBadge check/x, stroke per state). **Acceptance:** inspector tests assert each of the 4 states' distinguishing properties; build GREEN. *(No-op if #45 already covers all four — then mark done with a one-line note.)*
- [ ] **52.4 Shared primitives extraction.** Reusable views recurring across frames: `BrandRow`, `StatusBar` stub, `StatChip`, slim `ProgressBar`, CTA/secondary button styles, `PageIndicator` (onboarding dots). Each token-bound. **Acceptance:** one inspector test per primitive asserting its key tokens/structure; build GREEN.

## Phase 2 — Net-new flow logic (Track A · Ralph · Sonnet)

- [ ] **52.5 Onboarding navigation + permission state machine.** Model: `Welcome → Features → Permission → (granted → Home | denied → 3b-Denied)`, page index, persisted `hasSeenOnboarding` (first-launch gate), mic-permission request/observe. **Founder decision 2026-06-11: also re-runnable from Settings** — expose a `startOnboarding()` entry that replays the flow without clearing/depending on the persisted flag (Settings entry point wired in 52.9). **Logic only — views in Phase 3.** **Acceptance:** ViewModel unit tests drive each transition incl. granted/denied branches, the first-launch persisted-flag gate on relaunch, AND a manual `startOnboarding()` replay that does not reset the flag; build GREEN.
- [ ] **52.6 Quiz-Complete aggregation.** Compute end-of-session summary (final score, correct/total, streak/accuracy as the `NPlqf` frame shows) from existing session/stats data. **Acceptance:** unit test feeds a known session → asserts the aggregated summary values; build GREEN.
- [ ] **52.7 Error-state mapping.** Map network/backend failure cases to the Error screen model (title/desc/retry action per `Fwafe`). **Acceptance:** unit test maps representative failures → expected error model + retry closure wired; build GREEN.

## Phase 3 — Visual assembly (Track B · Workflow · Sonnet draft + Opus judge)

> Each is a Workflow pipeline item: export `.pen` frame image → draft SwiftUI from frame + Phase-1 components → build on sim → screenshot → Opus judge scores fidelity vs export → iterate to threshold → emit draft + score + diff notes. Marked `- [WORKFLOW]` so the Ralph harness skips them.

- [WORKFLOW] **52.8 Home** (`rJ7dB`) — statusBar/brandRow/hero/statsRow/sessionWrap/configWrap/CTA.
- [WORKFLOW] **52.9 Settings** (`Jjcs5`) — voice/lang/audio/about sections; **add a "replay onboarding" row** wired to 52.5's `startOnboarding()`.
- [WORKFLOW] **52.10 Question states** (`b8zObz`,`WCaT6`,`f9csl`,`uGhZg`) — apply design to the #45 QuestionView (MultiChoice/TrueFalse/Listen/Capture); reuse, don't rebuild.
- [WORKFLOW] **52.11 Result Correct/Incorrect** (`X4o4l`,`31AzE`) — visual target for #45 reveal wiring.
- [WORKFLOW] **52.12 Quiz-Complete** (`NPlqf`) — bind to 52.6 aggregation.
- [WORKFLOW] **52.13 Onboarding ×4** (`gkeCn`,`hTdkE`,`haWJM`,`COHnz`) — bind to 52.5 state machine.
- [WORKFLOW] **52.14 Error** (`Fwafe`) — bind to 52.7 mapping.
- [WORKFLOW] **52.15 Paywall + Paywall-Offline** (`u2ySy`,`PouwN`) — redesign existing PaywallView + offline variant.

## Phase 4 — Fidelity sign-off (Track C · interactive · Opus)

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
