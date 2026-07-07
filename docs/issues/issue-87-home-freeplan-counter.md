# Issue #87 — Home: free-plan question counter + reset countdown

**Triage:** enhancement · done
**Status:** ✓ Shipped 2026-07-07. Created 2026-07-05 — founder-requested during UI-proposals approval (G2 in `docs/design/ui-proposals-2026-07-decisions.md`).

## Founder decisions (2026-07-07, in-session)

Research basis: metered-paywall practice (news industry monthly meters, Canva monthly credits, ChatGPT weekly throttle precedent; no market precedent for 2–3-week intervals) + #49 cost model (marginal cost per question ≈ $0.0001 → interval is a product choice, not a cost one). Bursty road-trip usage (30–100 questions per trip) fits one monthly pool better than a daily cap that breaks mid-trip.

1. **Reset interval: monthly**, calendar-month window (resets 00:00 UTC on the 1st, like Canva) — aligns with the $2.99/month billing cycle.
2. **Free quota: 100 questions/month** (`FREE_MONTHLY_LIMIT`, env-overridable; was 20/day) — covers one typical trip; a long or second trip hits the wall = natural upgrade moment.
3. **Paid state: small "Unlimited questions" row** in the same card slot (bolt icon, no progress track, no countdown).

## Implementation notes (2026-07-07)

- **Backend:** `daily_usage` rows stay per-day (no migration); the limit check sums the calendar month. Wire error code renamed `daily_limit_reached` → `quota_limit_reached` (interval-agnostic; no client matches on the string). `resets_at` = 1st of next month.
- **iOS:** `freePlanCard` on Home per frame 86.8 (`rJ7dB`/`j04Lk`) between subtitle and session section; hidden until `/usage` loads. `DailyLimitError` → `QuotaLimitError` rename; daily-flavored copy (paywall subtitle, error body, "Never wait for the daily reset") reworded to monthly. Countdown rounds up (never promises an early reset). Paywall CountdownPill gained a days tier ("12d 4h").
- The `.pen` paid-state variant is not drawn (decision post-dates #86 founder review); implementation = same card, text swap — re-sync at the next Pencil pass if desired.

## Why

Freemium model (daily/interval question limits) needs visibility: the user should see on Home how many free-plan questions remain and when the quota resets. Today the limit is enforced server-side (persistent `daily_usage`, #60) with no UI surface.

## Founder direction (2026-07-05)

- Home shows **remaining free-plan questions**.
- Quota resets on an interval **to be researched and decided**: 1 / 2 / 3 weeks or a month (note: current backend model is *daily* — an interval change touches backend usage accounting, not just UI).
- Home also shows **time remaining until reset**.
- **Design what a paying user sees** in that slot instead (nothing? unlimited badge? pack balance?) — proposal needed.

## Tasks

- [x] 87.1 Research reset-interval options (weekly/bi-weekly/tri-weekly/monthly) vs. cost model — build on #49 (daily free-limit cost research); recommend one with rationale → founder decides. **Done 2026-07-07: monthly / 100 q.**
- [x] 87.2 Design the Home counter (free state: N questions left + reset countdown; paid state proposal) — lands as frame 86.8 in #86 (Pencil sync of approved UI). **Free frame shipped in #86; paid state = Unlimited row (founder pick).**
- [x] 87.3 Backend: quota window per the decided interval (extends the `daily_usage` model from #60; coordinate with #49 pricing and #65 endpoint hardening). **Monthly sum over daily rows; 301 backend tests green.**
- [x] 87.4 iOS: Home counter UI + API wiring. **Card reads the already-fetched `/usage`; targeted suites + sim visual (light+dark) green.**

## Constraints

- G3 copy freeze — minimal new text, English primary.
- Blocked for implementation until: (a) interval decision (87.1 → founder), (b) #86 frame review.

## Cross-refs

#49 (cost research) · #60 (usage persistence) · #86 (Pencil sync) · project_monetization memory (freemium with limits, paid unlimited).
