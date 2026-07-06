# Issue #80 — Settings navigation: back button top-right, dead edge-swipe, header scrolls away

**Triage:** bug · done 2026-07-06

_2026-07-06: header was stale `needs-triage`; founder approval already recorded below. #86 design gate lifted 2026-07-06 → implemented same day._

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** founder report ("back button vpravo hore je zle; edge-swipe back nefunguje") + UI/UX review (sim-reproduced + code-verified)

**Severity:** medium — no data loss, but violates three HIG conventions at once on a screen every user visits; founder-reported friction.

## Problem

Settings is a real `NavigationStack` push, but it hides the system navigation bar and draws a custom
back chip (`arrow.left`) **top-right**. Three consequences, all confirmed on sim:

1. Back control is on the trailing side — HIG places Back leading (top-left).
2. Edge-swipe back does nothing — hiding the bar/back button disables the interactive pop gesture.
3. The whole header (including the back chip) scrolls away with content — once scrolled, the screen
   has **no visible navigation at all**.

## Evidence

- `HomeView.swift:18-20` — `NavigationLink { SettingsView(...) }` inside the `NavigationStack` from `ContentView.swift:46` (it *is* a push, not a sheet).
- `SettingsView.swift:50-51, 78-79` — `.navigationBarBackButtonHidden(true)` + `.navigationBarHidden(true)` + custom chip (`settings-back-button`) calling `dismiss()`, placed in the scrollable content.
- Screenshots: `docs/research/uiux-review-2026-07-03-shots/05-settings-top.png`, `06-settings-bottom.png`.
- HIG citations: `docs/research/uiux-hig-research-2026-07-03.md` §1 (back is leading; don't override standard gestures; nav bars stay pinned).

## Recommendation

Adopt the standard pinned navigation bar with the system (or lightly restyled) **leading** back
button and a title — the interactive pop gesture comes back for free; delete the custom chip. If the
brand look must stay, keep the visual treatment but in a pinned top bar with the back control leading
and `interactivePopGestureRecognizer` intact. Audit sibling pushed screens for the same pattern while
in there (one commit per screen).

## Acceptance

- [x] Back control renders top-LEFT in a pinned (non-scrolling) top bar on Settings
- [x] Edge-swipe from the left edge pops back to Home
- [x] Header/navigation remains visible when scrolled to the bottom of Settings
- [x] VoiceOver announces the back control as "Back"
- [x] Screenshot-verify step run (per iOS rules); RS scenarios pass (RS not re-run — Settings nav has no RS coverage; full HangsTests green)

## Implementation (2026-07-06)

Per frame `Jjcs5` + decision 1 (Variant B): system pinned bar restored on `SettingsView`
(`navigationBarHidden` gone), leading `HangsBackChip` (`← hangs. •` pill, "Back" a11y label,
same `settings-back-button` id), principal mono micro-caps `SETTINGS` title that fades in
once the hero scrolls past 96 pt (`onScrollGeometryChange`). New `HangsNavBar.swift` holds
the chip + `NavigationPopGestureEnabler`.

**Finding — iOS 26 kills the classic edge-swipe fix.** With `navigationBarBackButtonHidden`,
SwiftUI's NavigationStack no longer consults `interactivePopGestureRecognizer`'s delegate at
all (verified empirically: replaced delegate stays installed but is never asked; synthetic
edge swipes also never drive `UIScreenEdgePanGestureRecognizer`). Solution: a plain pan
recognizer accepting only touches starting ≤30 pt from the left edge; pops via
`popViewController` once the swipe is decisively horizontal past 60 pt; simultaneous only
with other pans (so a swipe can't double-fire a row tap); removed on disappear so sibling
screens (DebugLogView) keep native behavior. Pop is threshold-triggered (standard pop
animation), not finger-tracked — SwiftUI exposes no public interactive-pop driver here.

**Sister-screen audit:** Settings was the only offender. DebugLogView already uses the
system bar/back (native gesture verified on sim); quiz screens are state swaps, not pushes.

Tests: 6 new (`SettingsNavigationTests`) — chip action/a11y/content, collapse threshold
both sides, back-control-pinned-not-scrolling integration.

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 1 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED as recommended: Variant B large-title collapse, HangsNavChip moved leading with Back a11y label, sister-screen audit inside #80, mono micro-caps bar title.
