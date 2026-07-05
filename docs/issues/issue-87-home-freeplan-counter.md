# Issue #87 — Home: free-plan question counter + reset countdown

**Triage:** enhancement · needs-info (product decision: reset interval)
**Status:** Created 2026-07-05 — founder-requested during UI-proposals approval (G2 in `docs/design/ui-proposals-2026-07-decisions.md`).

## Why

Freemium model (daily/interval question limits) needs visibility: the user should see on Home how many free-plan questions remain and when the quota resets. Today the limit is enforced server-side (persistent `daily_usage`, #60) with no UI surface.

## Founder direction (2026-07-05)

- Home shows **remaining free-plan questions**.
- Quota resets on an interval **to be researched and decided**: 1 / 2 / 3 weeks or a month (note: current backend model is *daily* — an interval change touches backend usage accounting, not just UI).
- Home also shows **time remaining until reset**.
- **Design what a paying user sees** in that slot instead (nothing? unlimited badge? pack balance?) — proposal needed.

## Tasks

- [ ] 87.1 Research reset-interval options (weekly/bi-weekly/tri-weekly/monthly) vs. cost model — build on #49 (daily free-limit cost research); recommend one with rationale → founder decides.
- [ ] 87.2 Design the Home counter (free state: N questions left + reset countdown; paid state proposal) — lands as frame 86.8 in #86 (Pencil sync of approved UI).
- [ ] 87.3 Backend: quota window per the decided interval (extends the `daily_usage` model from #60; coordinate with #49 pricing and #65 endpoint hardening).
- [ ] 87.4 iOS: Home counter UI + API wiring.

## Constraints

- G3 copy freeze — minimal new text, English primary.
- Blocked for implementation until: (a) interval decision (87.1 → founder), (b) #86 frame review.

## Cross-refs

#49 (cost research) · #60 (usage persistence) · #86 (Pencil sync) · project_monetization memory (freemium with limits, paid unlimited).
