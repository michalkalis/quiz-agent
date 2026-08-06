# Issue 146: A paid pack order becomes unrecoverable once Settings is dismissed — retry proof lives only in view-scoped `@State`

**Triage:** bug · needs-triage
**Priority:** serious
**Reversibility:** a
**Source:** architectural audit 2026-08-06
**Created:** 2026-08-06

## Context

A custom pack is a real purchase: the user pays, the backend generates, and generation can still fail server-side (#139, #142 are both live examples). The whole retry story — "you already paid, press Try again" — depends on the app still holding the StoreKit proof the order was created with, because that proof is the only thing the retry endpoint accepts from a user build. Today that proof exists only inside a view model owned by `SettingsView`'s `@State`, and the app tears that view down on every quiz start and every relaunch. So the user who follows the app's own advice ("check My packs later") walks out of the one screen that could ever recover their order. The paid path is not live yet (App Store Connect `pack_30` is still an open founder leg), which makes this a cheap pre-GA fix rather than an incident.

## Confirmed findings

### F1 — The only retry credentials for a paid order are held in a view-scoped view model (verified, serious)

**Where:** `apps/ios-app/Hangs/Hangs/ViewModels/OrderPackViewModel.swift:97` and `:102`

`orderId` (:97) and `orderPaymentProof` (:102) are plain in-memory properties. The durable copy is deliberately destroyed the moment the backend accepts the order — `OrderPackViewModel.swift:345-349`:

```
orderPaymentProof = intent.paymentProof
if intent.paymentProof != nil {
    purchaseService.clearPendingProof()
}
```

with the comment at `:344` stating why nothing else will do: *"the backend accepts nothing else in a user build."*

That is accurate. `retry_order` in `apps/quiz-pack-api/app/api/v1/orders.py:544-594` authorises on `X-StoreKit-JWS` (whose `transaction_id` must match the order's) **or** `X-Admin-Key`, and otherwise raises 401 — a bearer JWT alone is not accepted, unlike `GET /v1/orders/{id}`.

The proof is genuinely unrecoverable after that point: `PackPurchaseService` finishes the consumable transaction right after persisting it, and the file itself records that *once finished, a consumable transaction cannot be re-read from StoreKit*; `Transaction.updates` only surfaces new or deferred transactions.

**Where the object lives:** `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift:59` —
`@State private var orderPackViewModel: OrderPackViewModel?`, built lazily in `presentCreatePack()` (~`SettingsView.swift:186-195`). `SettingsView` is a pushed `navigationDestination` route (`apps/ios-app/Hangs/Hangs/ContentView.swift:142,145`), and `ContentView.swift:233-235` runs `navModel.handleQuizStateChange(newState)` on every `$quizState` change; that handler calls `clearAll()` on entry into `.startingQuiz` (`apps/ios-app/Hangs/Hangs/ViewModels/NavigationModel.swift:61-64`), emptying the pushed path and destroying the `@State`. App relaunch does the same.

**The other surface offers nothing:** `apps/ios-app/Hangs/Hangs/Views/MyPacksView.swift:67` gates the only action button on delivery — `if order.isDelivered, let packId = order.packId` — so a `failed` row renders a red status label and no way forward.

**Impact:** if the user leaves Settings, starts any quiz, or relaunches while an order is generating, a later server-side failure is permanently unrecoverable in-app. The money is spent, the order is `failed`, and no screen can authorise `POST /v1/orders/{id}/retry`. The only visible option is to pay again — reopening exactly the "nearly re-paid" class of bug that #138 (pack purchase flow redesign) hardened this file against, this time through view lifetime instead of navigation.

**No mitigating path exists.** `refund_eligible` is only a flag written by the sweep and failure paths (`apps/quiz-pack-api/app/worker/sweep.py:129,139,150`; `app/worker/tasks.py:289`) and read back in the order snapshot — nothing auto-refunds. ARQ auto-retries are already exhausted by the time the order is terminal `failed`. And the in-app poll timeout message ("Still working — check My packs later") actively pushes the user off the only screen that can retry.

**Not covered elsewhere:** absent from `docs/issues/INDEX.md` and `docs/todo/TODO.md`; distinct from #139 (pack generation hang observability), #142 (non-JSON provider response) and #133.

*Severity note:* the audit's adversarial pass lowered this from critical to serious — the door only opens for real paying users, and the founder's own build retries fine via the admin key.

*No unverified/minor findings accompany this issue.*

## Proposed approach

One design call decides the shape; both options are small and self-contained. Decide it first, then implement one.

**Option A — client-side durability (the audit's sketch).** Move `OrderPackViewModel` ownership out of `SettingsView`'s `@State` and into `AppState`, which already owns `packOrderService` and `packPurchaseService`, so the model's lifetime matches the app rather than a pushed route. Persist `orderId` plus the payment proof durably — alongside the existing pending-proof slot — and keep it until the order reaches a terminal *delivered* state (not merely "created"), then clear it. `MyPacksView` gains a "Try again" action on a `failed` row that uses the stored proof.
*Cost:* one more durable secret-ish blob on device, and an explicit lifecycle for clearing it (delivered, refunded, retry budget exhausted).

**Option B — backend-authorised retry.** Let `retry_order` accept a bearer JWT whose user matches `order.user_id`, since the order row already stores `transaction_id` and the app can identify the order from the `MyPacks` list alone. The client then needs no persisted proof at all; `MyPacksView` just calls retry on a failed row.
*Cost:* widens the retry endpoint's authorisation surface (currently proof-bound), so it needs the same care as any monetisation-path change; arguably the simpler of the two, because it deletes the client-side persistence problem rather than managing it.

Whichever is chosen, `MyPacksView` must stop being a read-only screen for failed orders — that is the user-visible half of the fix in both options, and the `@State` ownership in `SettingsView` should still move to `AppState` so a live order survives a quiz start.

**Founder decision (2026-08-06, in-session): Option B.** `retry_order` accepts a bearer JWT whose subject matches `order.user_id` (in addition to the existing JWS/admin paths); the client persists no proof. `MyPacksView` gains the retry action; `OrderPackViewModel` ownership still moves to `AppState`.

## Done criteria

- [ ] Option A or B explicitly chosen and recorded in this file before implementation starts.
- [ ] A pack order created in Settings survives a quiz start and an app relaunch: its identity and retry authorisation are still available afterwards (unit test on the owning object's lifetime, not on view internals).
- [ ] `MyPacksView` renders a working retry action on a `failed` order row, and no action on `pending`/`in_progress`/`delivered` rows (ViewInspector structure test per the repo's verification altitude).
- [ ] Retry from `MyPacksView` after the full teardown path (order created → quiz started → app relaunched → order fails) reaches the backend and is accepted — 202, not 401/409. Verified against a real failed order (admin path, no charge) or a simulated failure, and the result stated concretely.
- [ ] Retry credentials/state are cleared exactly when the order reaches a terminal delivered state (or refunded / retry budget exhausted) — asserted, so a stale proof cannot linger indefinitely.
- [ ] The existing #138 guarantee still holds: no path produces a second paid create where a retry was intended.
- [ ] iOS suite green for the touched targets; UI change screenshot-verified per `docs/testing/screenshot-verify-procedure.md` (non-gating).
