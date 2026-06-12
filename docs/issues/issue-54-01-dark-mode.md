# Plan 54.1 — Dark mode: white cards + invisible text (two-phase)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.1) · **Priority:** P0 (founder #3)
**Status:** ready · **Confidence:** high (mechanism reproduced in code; matches screenshot)
**Founder decision:** **Phase 1 = quick legibility fix now; Phase 2 = deliberate Pencil dark
design + asset-catalog migration later** (its own task).

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
- [ ] No hardcoded `Color.white` on adaptive card surfaces; legacy islands on main flows adapt.
- [ ] Light + dark screenshots for the 5 core screens show legible cards/text.
- [ ] Re-record snapshots affected (Home/Question) — coordinate with the snapshot plan.
- [ ] Update parent §54.1; open/keep a Phase-2 task for the asset-catalog migration.
