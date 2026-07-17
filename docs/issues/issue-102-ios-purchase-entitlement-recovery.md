# #102 — iOS post-purchase entitlement recovery (residual of the sandbox-purchase bug)

**Triage:** bug · done
**Status:** ✓ DONE 2026-07-17 — all 4 findings fixed + opus-reviewed (merged `e1481ee`: `7975bbe` launch/foreground re-sync, `03df51e` pack restore, `7016959` activation gate, `96499b1` pre-paywall resync outcome honored at all 3 429 sites). HangsTests 661/661 green. Remaining `[HUMAN]`: acceptance bullet 4 on-device (next TestFlight, against #101 staging). Planned 2026-07-16 from the pre-MVP review. The `#96 P1` fix stopped the *happy-path* silent re-prompt, but the review found the **recovery paths** are still missing: if the post-purchase sync fails (offline in a tunnel) and the RC webhook lags/is lost, the client never reconciles and the paywall loop can resurface. This is the residual of the 2026-07-12 device failure.

## 1. Why

Server is the source of truth for the gate (`subscription` table, populated by the RC webhook). The client is supposed to *bridge* the gap by calling `POST /entitlements/sync` after purchase. The review confirmed that bridge only fires in narrow moments and swallows failure, with no later retry — so a single missed signal can strand a paying user behind the paywall.

## 2. Findings (confirmed, file:line + fix)

| # | Sev | Defect | Evidence | Fix |
|---|-----|--------|----------|-----|
| 1 | P1 | **No entitlement re-sync for a returning user** (only post-purchase + on identity mint) → missed webhook never self-heals | `Utilities/AppState.swift:118-121` syncs inside `setAccountLinkedHandler` (fires on anon-bootstrap / refresh-remint / sign-in, **not** a normal launch with a valid token); `AppState.swift:128-135` + `ViewModels/QuizViewModel.swift:709` `notifyPremiumPurchased` sync only post-purchase and **swallow** the error ("webhook will still catch up"). A returning-user launch does not re-sync. | Re-sync entitlements on launch **and** scene `.active`; retry with backoff; re-sync before showing the 429 paywall when RC reports the customer entitled/credited. |
| 2 | P2 | **Foreground refreshes neither usage nor entitlements** → stale "Free"/"limit reached" after a webhook lands while backgrounded | `ViewModels/QuizViewModel+ScenePhase.swift:56-58` `.active` only calls `refreshCommandWindow()`; `HomeView.onAppear` refreshUsage doesn't re-fire on background→foreground. Display-only (Start Quiz is server-gated), so not a hard block. | Refresh usage + reconcile entitlements on scene `.active` at the app root. |
| 3 | P1 | **Restore Purchases is subscription-only** → a pack buyer has no self-recovery | `Services/StoreManager.swift` `restorePurchases` excludes consumable packs. | Include consumable/pack entitlements in the restore path (re-sync from RC + `/entitlements/sync`). |
| 4 | P2 | **Premium UI trusts RC state before the server gate agrees** → "I paid but it still limits me" | `Services/PurchaseService.swift:119-126` flips `isPurchased` from RC's `customerInfoStream` instantly, while the server gate (`apps/quiz-agent/app/usage/tracker.py:114-124`) still denies until sync/webhook lands. | Show a transient "finishing activation" state until the server `/usage` mirror confirms, rather than treating RC state alone as entitled. |

## 3. Plan

One iOS sweep; each finding its own commit + a flow-altitude test (assert sync is *attempted* on launch/foreground; assert restore covers packs; assert the gate re-checks server truth). Sequence after or alongside `#101` so the fix can be validated against a sane environment (a sandbox that no longer pollutes prod).

## 4. Acceptance

- Launch + foreground each trigger an entitlement re-sync (test on `MockNetworkService.syncEntitlementsCallCount`).
- A simulated post-purchase sync failure followed by a later launch reconciles the user to entitled (no persistent paywall loop).
- Restore Purchases recovers a pack entitlement, not just a subscription.
- Founder on-device: buy → force-quit before webhook → relaunch → entitled without re-purchase. (`[HUMAN]`.)

## 5. Out of scope

The server-side environment gate (#101), pack-order backend robustness (#103), driving-loop (#100). The client idempotency-key defect on custom-pack orders is tracked in #103 (pack path).
