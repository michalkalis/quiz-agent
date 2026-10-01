---
paths:
  - "apps/ios-app/**/*.swift"
---

# Shared Components (Trubbo iOS) — which one to use

Inventory of `Views/Components` (#188 — unified design system, track C). Reuse before inventing: a new
screen composes these; a genuinely new shared component gets a row here and a
sample in `HangsTests/ComponentSamples+*.swift` (pixel snapshots per state, the
images the design catalog is built from). Tokens: `Utilities/Theme.swift` only.

## Actions

| Component | Use for |
|---|---|
| `HangsPrimaryButton` | The one main action of a screen (start, next, buy). States: disabled, `isLoading`/`showsSpinner`, `isDestructive` (end quiz), countdown fill (auto-advance). One per screen. |
| `HangsSecondaryButton` | A secondary full-width action under the primary (settings, maybe later). |
| `HangsGhostButton` | Low-emphasis text action (restore purchases, "not now"). |
| `QuestionSkipButton` | Skipping the current question; has its own skipping/disabled states. |
| `HangsNavChip` | Square icon chip in a top bar (close, back). |
| `HangsSourceLink` | Tappable source domain under an answer. |
| `QuizControlPill` | Quiz-screen mute + pause pair (toolbar glass). |
| `QuizOverflowMenu` | Quiz "…" menu (settings, feedback, rate question). |

## Layout and rows

| Component | Use for |
|---|---|
| `HangsHeroBlock` | Big display title (+ subtitle) at the top of a screen. |
| `HangsSectionLabel` | Mono uppercase label above a group. |
| `HangsCard` | Any grouped surface; don't hand-roll a rounded rectangle. |
| `HangsConfigRow` | Settings row with a value (and chevron when it opens something). |
| `HangsToggleRow` | Settings on/off row. |
| `HangsValueRow` | Read-only label + mono value (build info, stats). |
| `HangsDivider` | Hairline between rows. |
| `HangsBrandRow` | Brand mark row at the top of the root and onboarding screens. |

## Quiz

| Component | Use for |
|---|---|
| `HangsQuizNav`, `HangsQuizProgressHeader`, `HangsProgressBar` | Quiz top chrome: close + counter, category + segmented progress (recording tint), thin progress. |
| `HangsQuestionPrompt` | The question text with its accent bar; scales down, never wraps off screen. |
| `MCQOptionPicker` | Multiple-choice answers (picks `AnswerOption` rows or `AnswerTile` grid by option count/length). Don't use `AnswerOption`/`AnswerTile` directly. |
| `QuestionListenBar` | Voice bar on the question screen (reading → thinking → listening → evaluating/skipping). |
| `ListenBar` | Voice bar elsewhere: Home slim command bar, answer confirmation read-back, result footer. |
| `EmptyAnswerRetryHint` | "Didn't catch that" hint after an empty answer. |
| `HangsResultBanner`, `HangsInlineBadge` | Correct/incorrect verdict: banner on the result, small badge inline. |
| `ReviewBadge`, `QuestionProvenanceRow` | TestFlight-only review/translation badge and the question's provenance row. |
| `AmbientGlowWash`, `GlowSweepLine` | Voice feedback glow (animated; no snapshot). |

## Home

| Component | Use for |
|---|---|
| `HomePlanCard` | The plan/quota card (free, credits, subscriber, grace, expired). |
| `HomePacksSection` | The user's question packs on Home (owns `MyPacksViewModel`). |

## Unused — don't build on these

No call sites outside previews (2026-09-30): `HangsStatBox`, `HangsStatChip`,
`HangsVerdictCard`, `HangsAnswerRow`, `HangsAnswerComparisonCard`,
`HangsStatusBar`, `HangsRecordingBar`, `HangsFooterBar`, `HangsTerminalLabel`,
`HangsSessionDot`. Candidates for removal; not in the catalog.
