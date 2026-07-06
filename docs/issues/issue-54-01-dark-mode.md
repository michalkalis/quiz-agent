# Plan 54.1 — Dark mode: white cards + invisible text (two-phase)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.1) · **Priority:** P0 (founder #3)
**Status:** ✅ Phase 1 LANDED 2026-06-12 (Phase 2 stays open as its own task) · **Confidence:** high (mechanism reproduced in code; matches screenshot)
**Founder decision:** **Phase 1 = quick legibility fix now; Phase 2 = deliberate Pencil dark
design + asset-catalog migration later** (its own task).

_2026-07-06: Phase 2 (deliberate dark design via asset catalog) carried over to #86 design sync 2026-07-06._

## Problem
In dark mode the page background adapts but the STREAK/BEST/session cards stay bright white with
near-invisible labels — the adaptive token system is half-applied.

## Root cause (file:line)
`Theme.Hangs.Colors.bg/ink/muted` **are** adaptive (`Color(light:dark:)` via a UIColor dynamic
provider, `Color+Theme.swift:44`). But card surfaces **hardcode `Color.white`** instead of the
adaptive `bgCard` token:
- `HangsBlocks.swift:72` — `HangsCard` `.fill(Color.white)` (every stat box, config card, settings
  group, result/completion card)
- `HangsBlocks.swift:332` — `HangsAnswerRow` `.background(Color.white)`
- `HangsChrome.swift:48` — `HangsNavChip` white fill
- `HangsChrome.swift:94` — `HangsQuizNav` close-button white circle
- `HomeView.swift:186` — `navChipVisual` white fill

Net in dark mode: white card (didn't adapt) + near-white adapted `ink` text = illegible.

**Also systemic (legacy islands):** ~18 view files still use the **old non-adaptive**
`Theme.Colors.* / Theme.Spacing.* / Theme.Radius.* / Theme.Components.*` (not `Theme.Hangs.*`):
MinimizedQuizView, PaywallView, LiveTranscriptView, ImageQuestionView, AudioDevicePickerView, and
components (ScoreCard, StatsCard, SettingRow, badges, PrimaryButton, SecondaryButton, MicButton …).

## Phase 1 — quick legibility fix (this task)
1. Replace the hardcoded `Color.white` card fills above with the adaptive `bgCard` token (confirm
   `Theme.Hangs.Colors.bgCard` exists and is adaptive — verified 2026-06-12: `Theme+Hangs.swift:19`,
   `Color(light: "#FFFFFF", dark: "#1F1F22")`, already used at `QuestionView.swift:398`).
2. Migrate the legacy `Theme.Colors.*` islands to `Theme.Hangs.*` (or, minimally, ensure the ones
   visible on the main flows adapt). Prioritise screens reachable in normal play.
3. Verify contrast of `ink`/`muted` on the adapted card in **both** appearances.

**Verification:** screenshot-verify light **and** dark for Home, Question, Result, Completion,
Settings (rule #2). Add a snapshot/inspector check only where it can assert the *meaningful* token
(structure-only snapshots won't catch a colour regression — a rendered screenshot is required).

## Phase 2 — deliberate dark design (defer to its own task/session)
Design dark mode in Pencil first, then back the tokens with **Xcode asset-catalog colour sets**
(light+dark variants) so toggling the colour scheme changes everything with no per-call logic. This
supersedes the Swift `Color(light:dark:)` approach. Do **not** attempt in Phase 1.

## Pencil 1:1 sync
Phase 2 *is* the Pencil work. For Phase 1, no new structure — just note in Pencil that dark variants
are pending Phase 2.

## Done criteria (Phase 1)
- [x] No hardcoded `Color.white` on adaptive card surfaces; legacy islands on main flows adapt.
- [x] Light + dark screenshots for the 5 core screens show legible cards/text. *(Completion verified
      indirectly — see Landed note below.)*
- [x] Re-record snapshots affected (Home/Question) — **not needed**: the 3 stale snapshots are
      `.stableDump` model dumps, unaffected by colour tokens (full suite re-run confirmed: same 3
      known failures, nothing new). Re-record stays with the snapshot plan after UI-final.
- [x] Update parent §54.1; Phase-2 task for the asset-catalog migration stays open (this file §Phase 2).

## Landed 2026-06-12 (Phase 1)

**Fix:** 6 surface fills swapped from hardcoded `Color.white` to adaptive `Theme.Hangs.Colors.bgCard`
(`#FFFFFF` light / `#1F1F22` dark): `HangsCard` (HangsBlocks:72), `HangsAnswerRow` (HangsBlocks:332),
`HangsNavChip` (HangsChrome:48), `HangsQuizNav` close circle (HangsChrome:94), `HomeView.navChipVisual`
(HomeView:186), **plus a 6th site the plan missed**: `HangsSecondaryButton` pill (HangsButton:73 —
same bug class: white pill + adaptive `ink` text = invisible Skip/Re-record labels in dark mode).

**Test (red→green):** new `HangsSurfaceAdaptivityTests` (3 tests) renders HangsCard / HangsAnswerRow /
HangsSecondaryButton via `ImageRenderer` in both appearances and asserts center-pixel luminance —
dark < 0.5, light > 0.5. Red run reproduced the bug (luminance 1.0 in dark). A revert to `Color.white`
fails it, which structure-only inspector tests cannot catch. Full suite: 366 tests, only the 3 known
deferred snapshot fails.

**Screenshot-verify (light + dark, sim, idb-driven):** Home, Question, ConfirmationSheet, Result,
Settings — `VISUAL: PASS`. Report with embedded screenshots:
`docs/artifacts/visual-verify-54-1-dark-mode-2026-06-12.html`. **Completion:** unreachable in
`--ui-test` mock mode (fixture never advances past question 02/10) — verified indirectly (no hardcoded
surfaces by grep; composed of the same pixel-tested primitives). Live sim-confirm batched into
`issue-54-sim-repro.md`.

**Legacy-islands correction (de-scopes step 2):** the umbrella's claim that the ~18 legacy
`Theme.Colors.*` files are *non-adaptive* is wrong — `Theme.Colors` surface/text tokens are
`Color(light:dark:)` adaptive. The live legacy screens (MinimizedQuizView, PaywallView,
LiveTranscriptView, AudioDevicePickerView) adapt fine in dark mode; they are merely *visually
inconsistent* (old zinc/purple design), which is restyle work owned by 54.6 (MinimizedQuizView) and
Phase 2. Most legacy components (ScoreCard, StatsCard, SettingRow, MicButton, badges, Primary/
SecondaryButton, ImageQuestionView, …) have **zero production callers** — dead code for the cleanups
plan (54.19 class), not a dark-mode risk.
