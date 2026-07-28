# UI variant picks 2026-07-28 — founder decisions

Binding record of the founder's picks on the five HTML variant pages in `docs/design/variants/`
(process rule of 2026-07-28: HTML variants → founder pick → Pencil → code).
Nothing is implemented yet; Pencil sync comes first.

## Global directives

- **V1 — Component ownership wins across issues (founder, 2026-07-28).** When a component is designed in the issue that owns it, every other picked variant must use that design, not its own local sketch of the same component. Concretely: **#122 Variant C's ambient-glow is the app-wide voice-command feedback treatment** — #125A's full-width listening bar and #127C's footer adopt its match/no-match states rather than inventing their own. Resolve any similar collision in favour of the owning issue.
- **V2 — Variant pages are visual-first (founder, forward rule).** Future HTML variant pages: the visual is the deliverable — minimal annotation, no long spec tables.

## Picks

**#122 — Voice-command feedback (Track A): Variant C "Ambient glow"** (`issue-122A-voice-command-feedback.html`).
Text-free peripheral signal: bottom-third teal wash + light sweep on a match (teal progress-bar and record-ring accents), one slow amber breath on a no-match; no new strings. Resolves the issue's decision 3 (visual ambition). Still open there: recording word (1), Home scope (2), no-match throttle (4).

**#123 — Home entitlement (Track B): Variant A "One adaptive balance card"** (`issue-123B-home-entitlement-states.html`).
One card, one tap target, Anton headline showing the combined spendable total (free + credits) over a two-tone track; Track A's loading row survives. Implicitly resolves the issue's decision 3: a free user's pack credits DO show on Home, folded into the total.

**#125 — MCQ minimalist layout (Track B): Variant A "Answer Grid"** (`issue-125B-mcq-minimal-layout.html`).
2×2 letter tiles halve the option block (292→188pt); reclaimed space becomes a 360pt stem floor at Anton 34; the listening pill becomes a full-width bar that absorbs the mute button (its feedback states follow V1/#122C). The page's assumed SE-class 375×667 design floor stands.

**#127 — Result screen: Variant C "Zero-Scroll Deck", MODIFIED** (`issue-127-result-screen.html`).
Colour-washed verdict field (verdict word + score inline), answer dominant, one consolidated footer row. **Founder modification: the screen chrome itself never scrolls, but long content scrolls *inside* the answer/explanation card** — clipping stays structurally impossible while long explanations remain reachable. As drawn, the explanation shows on wrong answers too. "Try this question again" is not in the picked variant → formally dropped (closes the open item in `issue-96-ios-mvp-completion.md:137`).

**#129 — Paywall in-flight states: Variant C "The Button Narrates"** (`issue-129-paywall-inflight-states.html`).
The CTA is the single status surface and morphs per product (purple "Buying 100 Question Pack…", pink for the plan, blue for restore) with a progress track; no row spinners. Resolves the issue's decision 1 (CTA repurposed as narrator — no dead-looking button, no second purchase mid-flight) and decision 2 (pink selection check kept but demoted).

## Follow-through

1. **Pencil sync** — redraw all five picked variants into `design/quiz-agent.pen` in ONE session so V1 holds (draw #122C's glow language first, reuse it in #125A and #127C); founder reviews frames + `⌘S`.
2. **Implementation** — per source issue, only after the Pencil frames are approved. #122A's glow component lands first; #125 and #127 consume it.
