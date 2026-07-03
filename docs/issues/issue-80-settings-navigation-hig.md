# Issue #80 — Settings navigation: back button top-right, dead edge-swipe, header scrolls away

**Triage:** bug · needs-triage (draft from UI/UX review 2026-07-03)

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

- [ ] Back control renders top-LEFT in a pinned (non-scrolling) top bar on Settings
- [ ] Edge-swipe from the left edge pops back to Home
- [ ] Header/navigation remains visible when scrolled to the bottom of Settings
- [ ] VoiceOver announces the back control as "Back"
- [ ] Screenshot-verify step run (per iOS rules); RS scenarios pass
