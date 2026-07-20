# Issue 114: MVVM conformance — AccountViewModel, PaywallViewModel, DI seams, auth Sentry logging

**Triage:** refactor · ready-for-human (class-b-adjacent: SIWA + purchase surfaces; founder may flip to ready-for-agent with the mandatory T7 maker≠checker adversarial leg, per the #93 — subscription IAP precedent)
**Reversibility:** a (code-only; touches SIWA + purchase-orchestration surfaces → maker≠checker review leg mandatory; pipeline decides ready-for-agent vs ready-for-human per the class-b guard)
**Status:** Prep complete 2026-07-20 — all six /prepare-issue phases passed (P5 impl-plan gate cycle 2: ready-check READY · design-soundness SOUND 0.85), split into 2 build sessions (account T1–T3 · paywall+rest T4–T6) plus a mandatory maker≠checker review gate (T7), paste-in prompts in `issue-114-execution-prompts.md`, landing ready-for-human on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 items 4, 8, 10 + dimensions 1, 2, 9. Link, don't restate.

## Why

**One target-architecture rule, enforced on the three worst offenders** ([review](../research/ios-architecture-review-2026-07-18.md) → Target architecture, *ViewModels & DI*): *Views hold presentation `@State` only — no service calls, no Keychain reads, no purchase orchestration in a View; services reach the view tree only through AppState-injected protocols.* Plus the corollary the same section states: *every service logs warning/error events through SentryLog, not os.Logger alone.*

- **AccountViewModel** — the SIWA / sign-out / delete-account / export flow is duplicated view-side in `SettingsView.swift:447` and `ContextualSignInSheet.swift:201`, and **the two copies have already diverged**: the sheet **fails loud** (error banner on every non-cancel failure), Settings **fails silent** (Logger + return, no UI). Duplicated identity + token-swap logic drifting apart on a founder-critical surface is a latent bug, not a cosmetic nit.
- **PaywallViewModel** — purchase trigger, `effectivePlan` fallback, and the 1.5 s success auto-dismiss run inside the View on the revenue-critical screen (`PaywallView.swift:27`), untestable except through view-inspection and entangled with #102 `.activating` semantics that must not regress.
- **AuthService → SentryLog** — auth events (e.g. dropped signed-in session, `AuthService.swift:350`) reach only local os.Logger, so TestFlight auth incidents are **invisible to production monitoring** while every peer service already routes through SentryLog.

Adjacent (same rule, small): `MyPacksView.swift:14` calls PackOrderService directly with view-local `@State` while sibling pack screens go through a VM.

## Scope

**In:**

1. **AccountViewModel** (`@MainActor final class ObservableObject`, protocol deps injected via AppState, `@StateObject` at each owner) consumed by **both** SettingsView and ContextualSignInSheet — owns sign-in / sign-out, delete-account, export-data, and token/sign-in state. Introduce a role-scoped `AccountServiceProtocol` (`isSignedIn` + `currentAccount`, both **async** — AuthService is an actor) that the existing AuthService actor **also** conforms to; **`AuthServiceProtocol` stays untouched at its 2 methods** (no unused stubs forced on its `StubAuthService` mock). Delete all **6** ad hoc `KeychainTokenStore()` reads (`SettingsView.swift:114/120/470/481/488` + `ContentView.swift:196`). Give `AdminKeyStore` a protocol seam mirroring TokenStore, injected via AppState, replacing the **2** direct sites (`SettingsView.swift:115` load, `:603` save).
2. **PaywallViewModel** wrapping StoreManager — owns plan selection, `effectivePlan` fallback, purchase trigger, and post-success dismissal — **preserving #102 `.activating` (money-moved / server-unconfirmed) semantics**: `.activating` renders distinctly and must **not** auto-dismiss; only `.success` auto-dismisses at 1.5 s; the #96 P1 success-without-entitlement fail-loud survives.
3. **AuthService warning/error events → SentryLog** (`.network` category already exists; keep the existing os.Logger calls alongside).
4. **MyPacksView → `MyPacksViewModel`** (decision (e)) — fold `listOrders()` + loading/failure state out of the View.

**Out:** any redesign of auth or purchase *behavior* (this is behavior-preserving — see the one founder call below); backend / API / Pydantic; StoreManager's internal purchase logic (wrap, don't touch); #113 (separate).

## Resolved design decisions

- **(a) One `AccountViewModel` consumed by both views** — not an AppleSignInCoordinator + two VMs. The shared surface is small and stateful (token state + four async actions); a single injectable observable both views bind via `@StateObject` matches the in-repo OrderPackViewModel / OnboardingViewModel exemplar exactly and removes the duplication at the source. A coordinator+VMs pair would re-introduce two seams to keep in sync — the very problem being fixed.
- **(b) Fail-loud is canonical** — unify both copies onto ContextualSignInSheet's pattern: every non-cancel failure sets an error state with a user-facing surface; `.canceled` stays a silent normal exit. This is the repo norm (Rule #2, fail loud) and picks a winner rather than averaging the divergence (Rule #4).
- **(c) ContextualSignInSheet binds the protocol, not concrete AuthService** — it currently binds concrete `AuthService` (`:28`); after this issue it depends only on `AccountServiceProtocol` through the VM, so sign-in UI state is mockable.
- **(d) PaywallViewModel wraps, never duplicates, StoreManager's `@Published` state** — StoreManager stays the single source of truth for `offerings / purchaseState / …`; the VM exposes derived presentation state and forwards intents. No purchase state is mirrored into the VM (avoids the two-sources-of-truth bug class the review flags elsewhere).
- **(e) MyPacksView → a small dedicated `MyPacksViewModel`**, not folded into OrderPackViewModel. Listing order history is a distinct responsibility from ordering + generating one pack (OrderPackViewModel owns a full `OrderState` progression a list view never needs); a small VM mirroring the same `init(service:)` shape keeps both single-purpose and ≤300 lines. Reversible, low-risk; both share `PackOrderServiceProtocol`.
- **(f) Sentry scope = warning/error only, no PII** — route only warning/error-level auth events through SentryLog under `.network`; **token values, Apple identity payloads, and account identifiers are never placed in events** — messages describe the failure class only.
- **(g) Test strategy** — add VM-level tests for the account flow (sign-in/out, delete, export, token-state transitions) and for PaywallViewModel (plan selection, `effectivePlan` fallback, `.activating` ≠ `.success` no-auto-dismiss). Re-record the **2** `PaywallViewSnapshotTests` baselines (`limitErrorWithCountdown`, `noLimitErrorProductLoading`) — **non-gating**, human sign-off. **`AppleAuthTests`, `ContextualSignInSheetTests`, `PurchaseActivationTests` / `StoreManagerTests` must stay green unchanged** — that is the behavior-preservation proof; a change forced in any of them is a review flag, not a green light.

**Founder decision needed — SettingsView sign-in error surface.** Merging the SIWA copies forces the choice the research surfaced: give Settings' Apple sign-in a **visible error surface** (it currently fails silently) or keep it silent. **Default = SURFACE it** — reuse the existing `accountErrorMessage` alert channel (today wired only to `performDeleteAccount`, `:490`). Rationale: fail-loud is the repo norm (Rule #2), silent sign-in failure is arguably a latent bug, and this is a one-line reuse of an existing channel, not new UX. Product/UX call so it is flagged for the founder, but the default is **executable — do not block the run on it**; `.canceled` stays silent either way.

**Class assessment (from Phase 1, kept visible).** **class-b-adjacent** — Reversibility=a (code-only; no schema/API/migration/secret/prod-money), but blast radius is two founder-critical surfaces (SIWA completion + purchase orchestration), so a maker≠checker adversarial review leg is mandatory (parity checklist in Research). **Final triage state is decided at finalize, not here** — two live options: **ready-for-human**, or **ready-for-agent with a mandatory adversarial-review leg** (the #93 precedent for auth/money-adjacent refactors). Recorded, not decided — this is founder-side policy.

**Second-order (forward-compat).**
- `AccountViewModel` is the seam a future **Google / email / passkey sign-in** plugs into (#61 roadmap noted Google/passkey room) — a new provider becomes a new action on one VM + one protocol method, not a third divergent view-side copy.
- `PaywallViewModel` is where **#94-style design / paywall-copy syncs stop touching purchase logic** — future paywall redesigns edit presentation state on the VM, never StoreManager's purchase orchestration.

## Tasks (atomic)

*Ordered; each independently committable and buildable. Paths relative to `apps/ios-app/Hangs/Hangs/` (tests under `apps/ios-app/Hangs/HangsTests/`). New VMs mirror the OrderPackViewModel shape (`@MainActor final class … ObservableObject`, `init(<protocol deps>)`, `@StateObject` at the owner). New tests use Swift Testing (`@Test`/`#expect`). **Session split (Phase 6):** T1–T3 = Session A (account) · T4–T6 = Session B (paywall + MyPacks + Sentry) · T7 = the maker≠checker review gate — paste-in prompts + shared recon in [`issue-114-execution-prompts.md`](issue-114-execution-prompts.md).*

- [ ] **T1 — AccountServiceProtocol + AdminKeyStore seam + ContentView migration (foundation).**
  - New `AccountServiceProtocol` (declared next to `AuthServiceProtocol` in `Services/AuthService.swift:99`) carries the account surface the VM binds: `isSignedIn` + `currentAccount` (both **`async`**, derived from the actor's in-memory `tokens` mirror — no new Keychain read; `currentAccount` returns a non-secret descriptor only, never a raw token), plus the **6** account actions the VM calls (`generateRawNonce`, `hashedNonce(for:)`, `completeAppleSignIn`, `signOut`, `deleteAccount`, `exportData`). The **existing `AuthService` actor conforms to BOTH** `AuthServiceProtocol` and `AccountServiceProtocol` (one instance, two role-scoped seams). **`AuthServiceProtocol` is left untouched — exactly its 2 methods** (`accessToken()`/`refreshedAccessToken(replacing:)`), so its consumers (NetworkService, `PackOrderService.swift:151`) and its sole mock `StubAuthService` (`NetworkServiceTests.swift:394`) take **zero** churn. `AppState.authService` stays the concrete `AuthService`; add a protocol-typed accessor `var accountService: AccountServiceProtocol { authService }` (same instance) that AccountViewModel + ContentView depend on.
  - New `AdminKeyStoreProtocol` (load/save, mirroring the `TokenStore` seam at `AuthService.swift:91`); `AdminKeyStore` conforms; expose on AppState (`let adminKeyStore: AdminKeyStoreProtocol`).
  - Migrate `ContentView.swift:196` `KeychainTokenStore().load()` → read `appState.accountService.isSignedIn` inside an async `.task` (gate note: ContentView reads via `appState.accountService`).
  - **Async-gate timing (Gate B soft note).** The old gate is a *synchronous* Keychain read; making it an `async` actor read must not let first render slip past the sign-in-prompt gate — the prompt gating (`SignInPromptGate` / `signInPromptShownCount`) must still evaluate **before** first present. Carry a small test or explicit check on `signInPromptShownCount` timing into T2's `AccountViewModelTests`.
  - Done-when: builds; ContentView shows no `KeychainTokenStore(`; `AccountServiceProtocol` + AdminKeyStore seam compile with `AuthService`/`AdminKeyStore` conforming; `AuthServiceProtocol` + `StubAuthService` unchanged (`git diff HangsTests/NetworkServiceTests.swift` = none).

- [ ] **T2 — AccountViewModel + SettingsView migration.**
  - New `AccountViewModel(account: AccountServiceProtocol, adminKeyStore: AdminKeyStoreProtocol)`, `@StateObject` in SettingsView. Owns Apple sign-in (`handleAppleSignInResult`), sign-out, delete-account, export-data, token/sign-in presentation state, and `accountErrorMessage`.
  - Fail-loud canonical (decision b): every non-`.canceled` failure sets `accountErrorMessage`; `.canceled` is a silent normal exit.
  - Founder-default (Phase 2): Settings' Apple sign-in failures surface via the existing `accountErrorMessage` alert channel (`SettingsView.swift:490`, previously wired only to `performDeleteAccount`).
  - Delete the 5 `KeychainTokenStore()` reads (`SettingsView.swift:114/120/470/481/488`) — read sign-in state/account via the VM's protocol accessors. Replace the 2 `AdminKeyStore()` direct sites (`:115` load, `:603` save) with the injected `adminKeyStore` seam.
  - **Async-gate timing test (Gate B soft note, from T1).** Add an `AccountViewModelTests` assertion that the async `isSignedIn` read resolves the sign-in-prompt gating before first present — the `signInPromptShownCount` timing must match the old synchronous gate (prompt not shown/suppressed spuriously by the await hop).
  - Done-when: builds; SettingsView shows no `KeychainTokenStore(` and no `AdminKeyStore(`; sign-in/out/delete/export drive the VM.

- [ ] **T3 — ContextualSignInSheet migration to the VM/protocol.**
  - ContextualSignInSheet binds `AccountViewModel` (protocol-backed) instead of the concrete `AuthService` (`:28`) — decision (c). `handleAppleSignInResult` (`:201`) delegates to the shared VM; preserve the per-phase structure, fail-loud in all 3 failure paths, the `.canceled`-silent exit, and success → `onDismiss()`.
  - `ContextualSignInSheetTests`: construction-only migration allowed (gate note) — an init/type change is not a behavior regression; the behavior `#expect` assertions stay unchanged and green.
  - Done-when: builds; sheet holds no concrete `AuthService`; ContextualSignInSheetTests green (any diff construction-only).

- [ ] **T4 — PaywallViewModel wrapping StoreManager.**
  - New `PaywallViewModel(storeManager: StoreManager, limitError:…)`, `@StateObject` in PaywallView. PaywallView drops `@ObservedObject var storeManager` (`:27`) and binds only the VM; PaywallView's `init` keeps a `storeManager:` param forwarded into `PaywallViewModel(storeManager:)` (so `PaywallViewInspectorTests` stays constructible).
  - Change-forwarding mechanism (gate note; decision d — wrap, never mirror): in `init`, subscribe to `storeManager.objectWillChange` and re-emit `self.objectWillChange.send()` (stored `AnyCancellable`). Expose `purchaseState`, `offerings`, `isLoading`, `purchaseError`, `effectivePlan` (`:261` fallback), `selectedPlan`, and the purchase / `resetPurchaseState` intents as VM passthroughs — **no** purchase state copied into a `@Published` on the VM. The `.task(id: vm.purchaseState)` auto-dismiss re-fires because the View re-renders on the forwarded `objectWillChange`.
  - Preserve #102 exactly: `.activating` renders distinctly and does **not** auto-dismiss; only `.success` auto-dismisses at 1.5 s (`:117`); the #96 P1 success-without-entitlement fail-loud (`:145`) survives; `resetPurchaseState` on appear (`:111`) and purchase triggers (`:384/440/449`) intact.
  - Done-when: builds; PaywallView binds no StoreManager directly; #102 behavior preserved.

- [ ] **T5 — MyPacksViewModel.**
  - New `MyPacksViewModel(service: PackOrderServiceProtocol)` (decision e) — fold `listOrders()` (`MyPacksView.swift:106`) + `orders / isLoading / loadFailed` (`:14`) out of the View; `@StateObject` at the owner, mirroring OrderPackViewModel's `init(service:)`.
  - Done-when: builds; MyPacksView holds no service call and no order-loading `@State`.

- [ ] **T6 — AuthService warning/error events → SentryLog + PII-safe test seam.**
  - Route AuthService warning/error events through `SentryLog.warn/.error(_, category: .network)` (`Utilities/Logging.swift:74`), starting with the `signed-in session dropped` event (`AuthService.swift:350`); keep the existing `Logger.network` calls alongside (decision f). No PII: messages/attributes describe the failure class only — never token values, Apple identity payloads, or account identifiers.
  - Test seam: `SentryLog` is today a static enum with **no** spy/protocol → add the minimal seam to make it assertable — a pure event-builder for message/attributes (asserted directly for PII-safety) + a test-only recorder/sink on `SentryLog` confirming the event fired. (Flagged for Phase 5: this touches shared `Utilities/Logging.swift`.)
  - Done-when: builds; the dropped-session path emits a `.network` warning/error verified by a test; the builder payload carries no token/PII.

- [ ] **T7 — Verification + maker≠checker adversarial review leg (MANDATORY, final).**
  - Suites green: `AppleAuthTests`, `ContextualSignInSheetTests` (behavior assertions), `PurchaseActivationTests`, `StoreManagerTests`, plus new `AccountViewModelTests`, `PaywallViewModelTests`, `MyPacksViewModelTests`.
  - Re-record the 2 `PaywallViewSnapshotTests` baselines (`limitErrorWithCountdown`, `noLimitErrorProductLoading`, in `HangsTests/Snapshots/`); confirm the diff is **model-only** (no rendered-pixel change) — non-gating, human sign-off.
  - **Sim eyeball (Gate B soft note).** On the simulator, confirm end-to-end that the `.task(id: vm.purchaseState)` auto-dismiss actually **re-fires** through the forwarded `objectWillChange` after the `@ObservedObject`→wrapped-passthrough change: one manual/inspector check that `.success` dismisses at ~1.5 s and `.activating` does **not** (the re-fire is the easiest thing to silently lose in this refactor).
  - Adversarial review leg by a reviewer **≠** implementer (class-b-adjacent, mandatory), signing off the 6 coverage points (Research §Class assessment): (1) SIWA error-handling parity — no path silently swallows a sign-in failure, `.canceled` still silent, Settings gained the error surface; (2) token-swap + `onAccountLinked`/RC-alias path untouched, no view-side Keychain read remains; (3) purchase orchestration — `.activating`≠`.success`, activating no-auto-dismiss, success auto-dismisses at 1.5 s, `effectivePlan` fallback identical, #96 P1 fail-loud intact, `resetPurchaseState` on appear intact; (4) `PurchaseActivationTests` green end-to-end; (5) new protocol accessor exposes only `isSignedIn`/`currentAccount`, not raw tokens; (6) snapshot re-records human-reviewed. Any forced change in a behavior-preservation suite is recorded as a flag, not a green light.
  - Done-when: all named suites green; snapshot diff confirmed model-only; 6-point review signed off with reviewer ≠ implementer.

## Acceptance

*Machine-evaluable. Greps run from `apps/ios-app/Hangs/Hangs/`; suites run via the iOS test scheme (Swift Testing).*

**DI seam — no view-side service reach:**
- **A1.** `grep -rn "KeychainTokenStore(" Views/ ContentView.swift` → **0 matches** (was 5 in SettingsView + 1 in ContentView).
- **A2.** `grep -rn "AdminKeyStore(" Views/` → **0 matches** (the `:115`/`:603` sites now use the injected `adminKeyStore` protocol).
- **A3.** `AuthServiceProtocol` is **unchanged** — still declares exactly its **2** requirements (`accessToken()`, `refreshedAccessToken(replacing:)`) and **no** `isSignedIn`/`currentAccount` (grep in `Services/AuthService.swift`). A new `AccountServiceProtocol` declares `isSignedIn` + `currentAccount` (both `async`) + the 6 account actions (`generateRawNonce`, `hashedNonce(for:)`, `completeAppleSignIn`, `signOut`, `deleteAccount`, `exportData`), with `AuthService` conforming to both (grep in the same file). `StubAuthService` is untouched: `git diff HangsTests/NetworkServiceTests.swift` → **empty**. `AdminKeyStoreProtocol` exists with `AdminKeyStore` conforming — grep the AdminKeyStore source.
- **A4.** ContentView's sign-in gate reads `appState.accountService.isSignedIn` in an async `.task` — grep shows the accessor and no `KeychainTokenStore`.

**Paywall — VM-only binding:**
- **A5.** PaywallView binds no StoreManager directly: `grep -n "@ObservedObject" Views/PaywallView.swift` shows no StoreManager property, and `grep -n "storeManager\." Views/PaywallView.swift` → **0** (no member access in the body). The only `storeManager` occurrence permitted is the `init` param forwarded into `PaywallViewModel(storeManager:)`. PaywallView binds `@StateObject … PaywallViewModel`.
- **A6.** `PaywallViewModel` forwards via a `storeManager.objectWillChange` subscription (grep shows it in `init`) and declares **no** `@Published` mirror of `purchaseState`/`offerings` (grep-zero mirrored purchase state).
- **A7.** `PaywallViewModelTests` exercises the activating→success republish: asserts `objectWillChange` emits on the transition, the `purchaseState` passthrough reflects `.success`, and the auto-dismiss predicate is true only for `.success` (false for `.activating`). Green.

**Behavior-preservation suites (green, unchanged):**
- **A8.** `AppleAuthTests`, `PurchaseActivationTests`, `StoreManagerTests` pass with **no** edit to their behavior assertions (`git diff` on those files = none, or construction-only).
- **A9.** `ContextualSignInSheetTests` behavior `#expect` assertions pass unchanged; any diff is construction-only (init/setup lines), reviewer-confirmed. `PaywallViewInspectorTests` (constructs `PaywallView(storeManager:…)`) likewise construction-or-migrate — behavior assertions unchanged.

**New VM tests (present + green), in `HangsTests/`:**
- **A10.** `AccountViewModelTests.swift` — sign-in success/failure, sign-out, delete, export, token/sign-in-state transitions. `PaywallViewModelTests.swift` — plan selection, `effectivePlan` fallback, `.activating`≠`.success` no-auto-dismiss (A7). `MyPacksViewModelTests.swift` — `listOrders` load + failure state. All green.

**Founder-default pinned:**
- **A11.** A test in `AccountViewModelTests` asserts a non-`.canceled` Settings Apple sign-in failure sets `accountErrorMessage`, and `.canceled` leaves it `nil` (the surface-the-error default).

**Sentry (no PII):**
- **A12.** A unit assertion (via the added `SentryLog` recorder/spy) confirms the `signed-in session dropped` path emits a `.network` warning/error event.
- **A13.** A test asserts on the event builder's message + attributes that they contain **no** token value, Apple identity payload, or account identifier.

**Snapshots:**
- **A14.** The 2 `PaywallViewSnapshotTests` baselines re-recorded; diff verified **model-only** (rendered output unchanged). Non-gating; human sign-off recorded in the review.

**Adversarial review:**
- **A15.** Maker≠checker leg completed by a reviewer ≠ implementer; all 6 coverage points (T7) signed off; any forced change in a behavior-preservation suite recorded as a flag.

## Research (Phase 1, 2026-07-20)

*Anchors verified against `apps/ios-app/Hangs/Hangs`. Source: [arch review](../research/ios-architecture-review-2026-07-18.md) items 4/8/10 + dims 1/2/9 — not restated.*

**Anchors (all confirmed; drift noted):**
- Five ad hoc `KeychainTokenStore()` reads in SettingsView: `:114, :120, :470, :481, :488` (+ ContentView `:196`) = **6 total**. AdminKeyStore direct at **two** sites: `SettingsView.swift:115` (load) + `:603` (save), not one. Settings SIWA handler is `:447` (item cited `:460` = the `completeAppleSignIn` Task inside it). SettingsView is 737 lines.
- `PaywallView.swift:27` = `@ObservedObject var storeManager: StoreManager`; effectivePlan `:261`, auto-dismiss `.task(id:)` 1.5 s `:117`, purchase triggers `:384/:440/:449`, `resetPurchaseState` onAppear `:111`.
- `AuthService.swift:350` = the `Logger.network.error("signed-in session dropped")` — the exact event needing SentryLog. `MyPacksView.swift:14` = `let service: PackOrderServiceProtocol` + `@State orders/isLoading/loadFailed`, `listOrders()` at `:106`.

**SIWA-copy divergence (the two `handleAppleSignInResult`):** `ContextualSignInSheet.swift:201` **fails loud** in all 3 failure paths — missing payload / `completeAppleSignIn`→nil / non-cancel `ASAuthorizationError` all set `phase=.failed` (error banner) — and explicitly treats `.canceled` as a silent normal exit; success → `onDismiss()`. `SettingsView.swift:447` **fails silent** — missing payload → `Logger.warning`+return, nil result → only `isSigningIn=false`, failure → `Logger.info` with no cancel/error distinction and **no UI**; success reloads via a view-side `KeychainTokenStore().load()`. Settings *has* an `accountErrorMessage` alert channel but it is wired only to `performDeleteAccount` (`:490`), never to sign-in. Unifying must give Settings a real error surface it currently lacks while preserving the sheet's canceled-detection.

**Protocol gap:** `AuthServiceProtocol:99` exposes only `accessToken()` + `refreshedAccessToken(replacing:)` — **no `isSignedIn`/`currentAccount`**, which is why 6 sites reach past the DI seam to Keychain. AuthService is an `actor` (in-memory `tokens` mirror) → new accessor is `async`. `ContextualSignInSheet` binds the **concrete** `AuthService` (`:28`), not the protocol. `AdminKeyStore` has **no protocol at all** → needs a TokenStore-style seam injected via AppState.

**StoreManager surface (what PaywallViewModel wraps):** `final class StoreManager: ObservableObject` (concrete, not protocol-injected). Published: `offerings, isPurchased, isLoading, hasAttemptedOfferingsLoad, purchaseError, purchaseState`. Methods: `loadOfferings, purchase(productID:), resetPurchaseState, restorePurchases, checkPurchaseStatus, logIn`; callback `onPurchaseSuccess` (set by AppState). View currently owns: `effectivePlan` fallback (annual↔monthly when an offering is missing, `:261`), `selectedPlan` @State, purchase triggers, `resetPurchaseState` on appear, the 1.5 s auto-dismiss. **#102 state to preserve:** `PurchaseState.activating` (`:58`) = money-moved-but-server-unconfirmed (finding 4); `purchase()` lands there when `onPurchaseSuccess?()` returns false (`:167`), renders distinctly and **must not auto-dismiss** (only `.success` does); the success-without-entitlement fail-loud (#96 P1, `:145`) must survive. `PurchaseActivationTests` already guards this at store level.

**Exemplars to mirror (in-repo, no new libs):** `OrderPackViewModel` (`@MainActor final class ObservableObject`, `init(service: PackOrderServiceProtocol)`, `OrderState` enum mirroring `PurchaseState`) + `OrderPackView` (`@StateObject`, `init(service:onPlayPack:)` → `StateObject(wrappedValue:)`); `OnboardingViewModel` injected the same way at `ContentView.swift:37`. AccountViewModel + PaywallViewModel + MyPacksVM should copy this shape (protocol deps via AppState, `@StateObject` at the owner). MyPacksView's `listOrders` folds into a sibling VM (its pack-flow sibling already uses OrderPackViewModel — Phase 2 decision (e) keeps the list concern in a small dedicated MyPacksViewModel).

**Test seams:** reusable — `AppleAuthTests` (service-level `completeAppleSignIn`/nonce/deleteAccount), `ContextualSignInSheetTests` (SignInPromptGate + per-phase structure — must stay green), `PurchaseActivationTests`/`StoreManagerTests` (activating≠success), `PaywallViewInspectorTests` (constructs `PaywallView(storeManager:limitError:onDismiss:)` — new VM init must keep it constructible or migrate), `OrderPackViewModelTests`. Snapshots: `PaywallViewSnapshotTests` 2 baselines (`limitErrorWithCountdown`, `noLimitErrorProductLoading`) → any paywall view change re-records (non-gating, human sign-off). **Gap:** no ViewModel-level test for the Settings account flow (sign-in/out/delete/export) and none for a PaywallViewModel — both are new testable seams this issue creates.

### Class assessment

**Verdict: class-b-adjacent (not class-b).** Reversibility=a (code-only; no schema/API/migration/secret/prod-money mutation). But the blast radius is two founder-critical surfaces: SIWA completion (identity + token swap + RC account-alias) and purchase orchestration (#102 activation semantics on the revenue screen). A "behavior-preserving refactor" framing is only ~90% true — unifying the SIWA copies forces the divergence to resolve one way (see product question), so it is not purely mechanical. Maker≠checker review leg must cover: (1) SIWA error-handling parity — no path silently swallows a sign-in failure, `.canceled` still silent, Settings gains the error surface it lacked; (2) token-swap + `onAccountLinked`/RC-alias path untouched, no view-side Keychain read remains; (3) purchase orchestration — `.activating`≠`.success`, activating no-auto-dismiss, success auto-dismisses at 1.5 s, `effectivePlan` fallback identical, #96 P1 fail-loud intact, `resetPurchaseState` on appear intact; (4) `PurchaseActivationTests` green end-to-end; (5) new protocol accessor exposes only `isSignedIn`/`currentAccount`, not raw tokens; (6) snapshot re-records human-reviewed.

**Prior art (build-vs-adopt):** Adopt — in-repo MVVM exemplars (OrderPackViewModel/OnboardingViewModel + `@StateObject` wiring) are the exact pattern; SentryLog + PurchaseState already exist and are reused. No external library or framework involved.

**Web pass skipped:** pure in-repo refactor mirroring established local exemplars — no external API/library/version question to research.

**Product question (genuine, for founder):** Settings' Apple sign-in currently fails **silently** (no user-facing error) while ContextualSignInSheet shows an error banner. Merging into one AccountViewModel forces a choice: give Settings a real sign-in error surface (a behavior *change* / bugfix, breaks the strict "behavior-preserving" claim) or keep it silent (preserves behavior but keeps the divergent UX). Recommend surfacing the error (parity + it is arguably a latent bug), but this is a UX call. → Phase 2 resolved: **default SURFACE** (reuse `accountErrorMessage`), executable, does not block the run.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.83 |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | ✅ done | cycle 2: ready-check READY · design-soundness SOUND 0.85 |
| 6 · Split             | ✅ done | multi-session: 2 build (account T1–T3 · paywall+rest T4–T6) + review gate (T7); `issue-114-execution-prompts.md` written |

**Last updated:** 2026-07-20 · **Prep complete** (all six phases ✅). · **Gate attempts:** P3 0/3 (passed) · P5 2/3 (passed cycle 2)
