# Issue 141: Play a custom pack from Home — "my custom packs" entry point

**Triage:** enhancement · design-gated (HTML variants → founder pick → Pencil → code)
**Reversibility:** a
**Status:** Founder 2026-08-04: after buying a custom pack there is no visible way to play it — Home should surface "moje custom balíky" with pick-and-play. Design first (explicit founder instruction).
**Created:** 2026-08-04

## Current state

Delivered packs are playable only via Settings → Moje balíky (`MyPacksView.swift`) — which is also admin-key-gated today (#140 removes the gate). Home renders plan/credit state (`HomePlanCard`, #123 Track B) but nothing pack-shaped. Related voice-first gap: #117 — voice "start" on a delivered pack screen doesn't carry pack context.

## Direction

- Home gets a "my custom packs" affordance (only when the user owns ≥1 pack; consider also surfacing an in-progress "pripravuje sa" state — ties into #138's readiness communication).
- Tap → pick a pack → play. Reuse the existing delivered-pack play path (pinned by `testRSPackNavStart`).
- Design round: HIG check, HTML variants (card vs list row vs section), founder picks in-chat, Pencil sync (`design/quiz-agent.pen`, founder ⌘S), then implement.
- Coordinate with #123 (Home card real estate), #138 (flow/states), #140 (no admin gate), #117 (voice-start pack context — don't block on it, but don't make it harder).

## Design pick (founder, 2026-08-05)

Variant B — "Moje balíky" section on Home listing up to 3 pack rows (HTML variants in `docs/artifacts/issue-141-home-packs-variants.html`): delivered row plays on one tap (circular pink play button), in-progress row shows "Pripravuje sa…" with a disabled control, footer "Zobraziť všetky" pushes the existing MyPacksView. Founder also picked: the section shows already when the only order is still generating (pre-delivery). Failed/refunded-only accounts see no section — Home is a play entry, MyPacksView owns failure comms. Pencil synced same day (Home frame, awaiting founder ⌘S).

## Acceptance

- [x] Home shows the custom-packs entry iff the account owns ≥1 relevant pack order (`HomePacksSectionVisibilityTests`: zero-pack hidden, failed-only hidden, in-progress shown, cap 3).
- [x] Entry → quiz starts with that pack's questions (unit pin `playCarriesPackId` on the start path carrying packId; reuses the `beginQuizStart(packId:)` path pinned by `testRSPackNavStart`).
- [x] In-progress pack state visible per design pick (visible pre-delivery, non-playable).
- [x] Slovak + English strings in the catalog (`my packs`, `Preparing…`, `Show all` added with sk translations; `%lld questions` reused).
