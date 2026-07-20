# Issue 115: Raise deployment target to iOS 26 + Swift 6 test targets + dead-code sweep

**Triage:** chore · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 items 5, 6. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 items 5, 6 + dimensions 5, 6, 8. Link, don't restate.

## Why (stub — Phase 2 expands)

1. **Raise deployment target 18.0 → 26.0** (Top 10 item 5) — the entire availability surface is two `@available(iOS 26,*)` guards (SilenceDetectionService, AppState wiring); there is **no legacy speech fallback**, so sub-26 silently loses VAD/barge-in/voice commands — an untested product-degrading path. Raising deletes both guards, makes SilenceDetectionServiceProtocol non-optional (~15 nil-branches removed), guarantees SpeechAnalyzer everywhere (`Shared.xcconfig:42` + test-target overrides).
2. **Unify test targets onto Swift 6 strict** (same change) — HangsTests/HangsUITests pin SWIFT_VERSION = 5.0 (xcconfigs never include Shared.xcconfig), so test code compiles without Sendable checking or MainActor default (`project.pbxproj:427`); make test xcconfigs include Shared.xcconfig, delete the 12 explicit overrides.
3. **One dead-code sweep** (Top 10 item 6) — 13 dead pre-redesign Views/Components files (incl. MicButton/PrimaryButton/SecondaryButton name-colliding with the live Hangs* set) + dead LanguagePickerView + AudioRoutePickerWrapper/Button + MicButtonInspectorTests/ProgressBarViewInspectorTests keeping dead code green. **Check the #104 — car-audio Media Mode mic-picker implementation before removing AudioRoutePickerWrapper** (Settings mic picker shipped 2026-07-17 may use it).

**Founder decision needed:** raising min iOS to 26.0 drops pre-iPhone-11 hardware. Default = proceed per the review's explicit recommendation (zero real users; founder device runs iOS 26+; memory `user_device_ios26`).

**Sequencing note:** run before #113 — QuizViewModel decomposition (the nil-branch deletion shrinks it).

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ⬜ pending | — |
| 2 · Plan              | ⬜ pending | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 11:19 · **Next:** Phase 1 · **Gate attempts:** P3 0/3 · P5 0/3
