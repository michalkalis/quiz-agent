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

## Acceptance (sketch — finalize after design pick)

- [ ] Home shows the custom-packs entry iff the account owns ≥1 pack order (unit test over usage/orders states, incl. zero-pack hidden state).
- [ ] Entry → pack picker → quiz starts with that pack's questions (RS-style sim scenario or unit pin on the start path carrying packId).
- [ ] In-progress pack state visible per design pick.
- [ ] Slovak + English strings in the catalog (`xcstringstool sync` run).
