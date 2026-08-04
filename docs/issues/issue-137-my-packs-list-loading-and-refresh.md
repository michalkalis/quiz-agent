# Issue 137: My Packs list — broken loading layout, raw status strings, list never refreshes

**Triage:** bug · done (2026-08-04)
**Reversibility:** a
**Status:** Founder field report 2026-08-04 (screenshots: spinner in a narrow vertical strip; raw "FAILED" label).
**Created:** 2026-08-04

Three mechanical defects in `MyPacksView` (Moje balíky), no design round needed:

1. **Loading layout broken** — `ProgressView()` at `MyPacksView.swift:26` sits in the content `VStack` without `.frame(maxWidth: .infinity)`, so the spinner renders in a narrow vertical strip instead of centered (the `emptyState` at `:90` does it correctly).
2. **Raw wire status shown** — `Text(verbatim: order.status)` at `MyPacksView.swift:56-60` prints uppercase English wire values (`FAILED`, `IN_PROGRESS`…). Localize per status (`PackOrder.swift:104-149` has the enum helpers); SK+EN catalog entries.
3. **List loads once and never updates** — `.task { await load() }` only (`MyPacksView.swift:43,102-113`); an order transitioning `in_progress → delivered/failed` never appears without leaving the screen. Add pull-to-refresh + periodic refresh while any order is non-terminal (reuse the cadence pattern from `OrderPackViewModel.poll`, `OrderPackViewModel.swift:154-203`).

Bigger "how do I know it's ready / how long will it take" UX (ETA, notification, failed-state actions like retry) is design-gated in #138 — pack purchase flow redesign; don't gold-plate here.

## Acceptance

- [x] Loading state renders the spinner centered full-width (ViewInspector layout test on the loading branch: `flexFrame().maxWidth == .infinity`).
- [x] No raw wire status string rendered; each of the 5 statuses maps to a localized SK+EN label via `OrderSnapshot.statusLabel` (unit test over all statuses + unknown-status fallback). Key `Ready` was taken (voice-recognizer meaning), so delivered = `Delivered`/`Hotový`.
- [x] `MyPacksViewModel` keep-fresh loop: periodic reload while any order is non-terminal (stops hitting the network once settled), `in_progress → delivered` row update covered by unit test; `.refreshable` pull-to-refresh wired and works on a settled list too.
- [x] Targeted suites green: 28/28 (MyPacksViewModel, PackOrderStatusLabel, MyPacksViewLoadingLayout, OrderPackViewModel, PackOrderCodable), 0 skipped.
