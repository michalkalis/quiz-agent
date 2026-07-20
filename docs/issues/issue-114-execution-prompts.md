# Issue #114 — Execution plan + ready-to-paste session prompts

**Created:** 2026-07-20 — from the prepared plan (recon reused from the issue's Research section; no re-map needed). #114 is **large (7 tasks)**, **cross-cutting** (auth + paywall + logging), and **class-b-adjacent** (SIWA completion + purchase orchestration — two founder-critical surfaces), so it is split into session-sized, independently-committable chunks + a mandatory maker≠checker review gate. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-114-mvvm-conformance-account-paywall.md`](issue-114-mvvm-conformance-account-paywall.md). Gate verdicts: P3 plan READY · SOUND 0.83 · P5 impl-plan (cycle 2) READY · SOUND 0.85. Source: [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) items 4/8/10.

Paths are relative to `apps/ios-app/Hangs/Hangs/` (source) and `apps/ios-app/Hangs/HangsTests/` (tests). Build/test commands live in `.claude/rules/ios.md`.

---

## Recon snapshot — what the codebase already gives us

**Target-architecture rule (the one being enforced):** Views hold presentation `@State` only — no service calls, no Keychain reads, no purchase orchestration in a View; services reach the view tree only through AppState-injected protocols; every service logs warning/error through SentryLog, not os.Logger alone.

**Auth / account surface:**
- `Services/AuthService.swift` — `actor AuthService`, in-memory `tokens` mirror. `AuthServiceProtocol` at **:99** exposes only `accessToken()` + `refreshedAccessToken(replacing:)` — **no `isSignedIn`/`currentAccount`**, which is why 6 sites reach past the DI seam to Keychain. `TokenStore` seam at **:91**. The `signed-in session dropped` event = `Logger.network.error(...)` at **:350** (needs SentryLog).
- `Services/AdminKeyStore.swift` — **no protocol at all** → needs a TokenStore-style load/save seam injected via AppState.
- `Utilities/AppState.swift` — the injected-services container (holds concrete `authService`). Add `var accountService: AccountServiceProtocol { authService }` + `let adminKeyStore`.
- `Views/SettingsView.swift` (**737 lines**) — SIWA handler `:447` **fails silent** (Logger + return, no UI); `accountErrorMessage` alert channel `:490` wired **only** to delete-account. Ad hoc `KeychainTokenStore()` at `:114/:120/:470/:481/:488`; `AdminKeyStore()` direct at `:115` (load) + `:603` (save).
- `Views/ContextualSignInSheet.swift` — binds the **concrete** `AuthService` at `:28`; `handleAppleSignInResult` `:201` **fails loud** in all 3 failure paths, `.canceled` silent, success → `onDismiss()`. (This is the canonical fail-loud pattern to unify onto.)
- `ContentView.swift` — `:196` `KeychainTokenStore().load()` sign-in gate (must not slip past `SignInPromptGate` when it becomes async); `:37` shows the OnboardingViewModel injection pattern to mirror.

**Paywall / pack surface:**
- `Views/PaywallView.swift` — `:27` `@ObservedObject var storeManager`; `resetPurchaseState` onAppear `:111`; 1.5 s auto-dismiss `.task(id:)` `:117`; #96 P1 success-without-entitlement fail-loud `:145`; `effectivePlan` fallback `:261`; purchase triggers `:384/:440/:449`.
- `Services/StoreManager.swift` — `final class ObservableObject` (concrete). Published: `offerings, isPurchased, isLoading, hasAttemptedOfferingsLoad, purchaseError, purchaseState`. `PurchaseState.activating` `:58` = money-moved-server-unconfirmed (#102, finding 4); `:167` is the activating branch; **`.activating` must render distinctly and NOT auto-dismiss — only `.success` does.** `PurchaseActivationTests` guards this at store level.
- `Views/MyPacksView.swift` — `:14` `let service: PackOrderServiceProtocol` + `@State orders/isLoading/loadFailed`; `listOrders()` `:106`. `Services/PackOrderService.swift` = `PackOrderServiceProtocol`.

**Exemplars to mirror (in-repo, no new libs):** `ViewModels/OrderPackViewModel.swift` (`@MainActor final class ObservableObject`, `init(service:)`, `OrderState` enum mirroring `PurchaseState`; the file also holds `OrderPackView` with `@StateObject`) + `ViewModels/OnboardingViewModel.swift` (injected at `ContentView.swift:37`). New VMs go in `ViewModels/`; new tests in `HangsTests/` (Swift Testing, `@Test`/`#expect`).

**Test seams (must stay green — behavior-preservation proof):** `HangsTests/NetworkServiceTests.swift:394` `StubAuthService` (must be byte-identical), `AppleAuthTests`, `ContextualSignInSheetTests` (behavior `#expect`), `PurchaseActivationTests`, `StoreManagerTests`, `PaywallViewInspectorTests` (constructs `PaywallView(storeManager:limitError:onDismiss:)`), `HangsTests/Snapshots/PaywallViewSnapshotTests.swift` (2 baselines, non-gating re-record). **Gap:** no VM-level test exists yet for the account flow or a PaywallViewModel — both are new seams this issue creates.

**⚠️ Logging test seam:** `Utilities/Logging.swift:74` `SentryLog` is a static enum with **no** spy/protocol; `.network` category exists. T6 adds a pure event-builder + a test-only recorder/sink to make the event assertable.

---

## Locked decisions (carry into every session — lifted verbatim from the plan)

| # | Decision |
|---|---|
| **(a)** | **One `AccountViewModel` consumed by both views** (not a coordinator + two VMs) — the shared surface is small + stateful; one injectable observable both views bind via `@StateObject` matches the OrderPackViewModel exemplar and removes the duplication at source. |
| **(b)** | **Fail-loud is canonical** — unify both SIWA copies onto ContextualSignInSheet's pattern: every non-cancel failure sets an error state with a user-facing surface; `.canceled` stays a silent normal exit. |
| **(c)** | **ContextualSignInSheet binds the protocol, not concrete AuthService** — after this issue it depends only on `AccountServiceProtocol` through the VM. |
| **(d)** | **PaywallViewModel wraps, never duplicates, StoreManager's `@Published` state** — StoreManager stays the single source of truth; the VM exposes derived presentation state + forwards intents. **No purchase state mirrored into a `@Published` on the VM.** |
| **(e)** | **MyPacksView → a small dedicated `MyPacksViewModel`**, not folded into OrderPackViewModel (distinct responsibility; both share `PackOrderServiceProtocol`). |
| **(f)** | **Sentry scope = warning/error only, no PII** — route only warning/error auth events through SentryLog under `.network`; token values, Apple identity payloads, and account identifiers **never** in events — describe the failure class only. |
| **(g)** | **Test strategy** — add VM-level tests (account flow + PaywallViewModel); re-record the 2 snapshot baselines (non-gating, human sign-off); `AppleAuthTests`/`ContextualSignInSheetTests`/`PurchaseActivationTests`/`StoreManagerTests` **stay green unchanged** — a forced change in any is a review flag, not a green light. |

**Founder default (Phase 2):** Settings' Apple sign-in gets a **visible error surface** (reuse the existing `accountErrorMessage` alert channel) — executable, does **not** block the run; `.canceled` stays silent either way.

**`AuthServiceProtocol` invariant:** it stays untouched at its 2 methods — `AuthService` conforms to **both** `AuthServiceProtocol` and the new `AccountServiceProtocol` (one instance, two role-scoped seams). `StubAuthService` takes zero churn (`git diff HangsTests/NetworkServiceTests.swift` = empty).

---

## Session breakdown

| Session | Tasks | Risk | Notes |
|---|---|---|---|
| **A — Account seam + VMs** | T1 + T2 + T3 + `AccountViewModelTests` | Med | Sequential chain T1→T2→T3. Touches `AuthService.swift` (protocol near :99), `AdminKeyStore`, `AppState`, `ContentView`, `SettingsView` (737 lines), `ContextualSignInSheet`. Founder-default: Settings gains a sign-in error surface. |
| **B — Paywall + MyPacks + Sentry** | T4 + T5 + T6 + `PaywallViewModelTests` + `MyPacksViewModelTests` + Sentry test | Med | PaywallViewModel wrap (**#102 preserved**) + MyPacksViewModel + AuthService→SentryLog seam. **⇄ parallel-eligible with A** but both edit `AuthService.swift` (B only at :350). |
| **C — Verify + adversarial review gate** | T7 | **Gate** | reviewer **≠** implementer, MANDATORY (class-b-adjacent). Full suites + snapshot re-record + **sim eyeball of the auto-dismiss re-fire** + 6-point sign-off. **Blocks on A + B merged.** |

**Coordination:** A and B are logically independent, but both edit `Services/AuthService.swift` in non-overlapping regions (A: `AccountServiceProtocol` + conformance near `:99`; B: SentryLog at `:350`). On the solo `arch-review-ios` branch, run **A → B → C sequentially** to avoid a merge dance; if parallelised via worktrees, reconcile that one file.

**Review gate (class-b-adjacent, replaces a "human prerequisite" block):** the T7 adversarial leg is mandatory and must be run by a reviewer ≠ the implementer of A/B. This is the gate that lets the founder flip triage from `ready-for-human` to `ready-for-agent` (the #93 subscription-IAP precedent for auth/money-adjacent refactors).

---

## Ready prompt — Session A (Account seam + VMs)

```
Work on issue #114 (MVVM conformance), Session A only: the account surface — tasks T1 + T2 + T3 + AccountViewModelTests. Do NOT touch PaywallView / StoreManager / MyPacksView / SentryLog — that is Session B. Behavior-preserving except the one founder-approved fix (Settings gains a sign-in error surface). Commit per task, push to arch-review-ios when green.

Read first (recon is done — don't re-map):
- docs/issues/issue-114-mvvm-conformance-account-paywall.md → tasks T1–T3, decisions (a)(b)(c), Research anchors + SIWA-copy divergence.
- docs/issues/issue-114-execution-prompts.md → "Recon snapshot" + "Locked decisions".
- Services/AuthService.swift → actor; AuthServiceProtocol :99 (leave at 2 methods); TokenStore seam :91; in-memory `tokens` mirror.
- Utilities/AppState.swift → services container (holds authService); add `accountService` accessor + `adminKeyStore`.
- Services/AdminKeyStore.swift → needs a load/save protocol seam.
- ContentView.swift → :196 KeychainTokenStore().load() gate; :37 OnboardingViewModel injection to mirror.
- Views/SettingsView.swift (737 lines) → :447 SIWA handler (fails silent), :490 accountErrorMessage (delete-only today), KeychainTokenStore :114/120/470/481/488, AdminKeyStore :115/:603.
- Views/ContextualSignInSheet.swift → :28 binds concrete AuthService, :201 handleAppleSignInResult (fails loud, .canceled silent).
- ViewModels/OrderPackViewModel.swift + ViewModels/OnboardingViewModel.swift → the exact VM shape to copy.
- HangsTests/NetworkServiceTests.swift → :394 StubAuthService (must stay byte-identical).

Build:
1) T1 — AccountServiceProtocol (isSignedIn + currentAccount, both async, derived from the actor `tokens` mirror — NO new Keychain read, currentAccount is a non-secret descriptor) + the 6 account actions (generateRawNonce, hashedNonce(for:), completeAppleSignIn, signOut, deleteAccount, exportData). AuthService conforms to BOTH protocols; AuthServiceProtocol UNCHANGED (2 methods). AdminKeyStoreProtocol + conformance. AppState: `var accountService: AccountServiceProtocol { authService }` + `let adminKeyStore`. Migrate ContentView:196 → `appState.accountService.isSignedIn` in an async .task. ⚠ Async-gate timing: SignInPromptGate / signInPromptShownCount must still evaluate BEFORE first present — cover with a check/test (carried into AccountViewModelTests).
2) T2 — AccountViewModel(account:adminKeyStore:), @StateObject in SettingsView; owns sign-in/out, delete, export, token/sign-in state, accountErrorMessage. Fail-loud canonical (b); Settings sign-in failures surface via accountErrorMessage (founder default), .canceled silent. Delete the 5 SettingsView KeychainTokenStore reads; replace the 2 AdminKeyStore sites with the injected seam.
3) T3 — ContextualSignInSheet binds AccountViewModel (not concrete AuthService); :201 delegates to the shared VM; preserve per-phase structure, all 3 fail-loud paths, .canceled-silent, success→onDismiss(). ContextualSignInSheetTests: construction-only diff allowed, behavior #expect unchanged + green.
4) AccountViewModelTests: sign-in success/failure, sign-out, delete, export, token/sign-in-state transitions; the founder-default assertion (non-.canceled Settings failure sets accountErrorMessage, .canceled leaves it nil); the async-gate timing check.

Done = build clean; `grep -rn "KeychainTokenStore(" Views/ ContentView.swift` → 0; `grep -rn "AdminKeyStore(" Views/` → 0; AuthServiceProtocol still exactly 2 methods; `git diff HangsTests/NetworkServiceTests.swift` empty; AppleAuthTests + ContextualSignInSheetTests + AccountViewModelTests green on the iOS sim. Commit per task (T1 seam; T2 SettingsView; T3 sheet+tests), push, tick T1–T3 in the issue. Auth code: fail loud, no silent skips.
```

---

## Ready prompt — Session B (Paywall + MyPacks + Sentry)

```
Work on issue #114 (MVVM conformance), Session B only: paywall + pack-list + auth logging — tasks T4 + T5 + T6 + their tests. Do NOT touch the account surface (AccountViewModel / SettingsView / ContextualSignInSheet / AccountServiceProtocol) — that is Session A. ⚠ You edit Services/AuthService.swift at :350 ONLY (region-isolated from Session A's protocol near :99). Commit per task, push to arch-review-ios when green.

Read first (recon is done):
- docs/issues/issue-114-mvvm-conformance-account-paywall.md → tasks T4–T6, decisions (d)(e)(f), StoreManager surface + #102 state to preserve.
- docs/issues/issue-114-execution-prompts.md → "Recon snapshot" + "Locked decisions".
- Views/PaywallView.swift → :27 @ObservedObject storeManager, :111 resetPurchaseState onAppear, :117 1.5 s auto-dismiss .task(id:), :145 #96 P1 fail-loud, :261 effectivePlan fallback, triggers :384/:440/:449.
- Services/StoreManager.swift → final class ObservableObject; published offerings/isPurchased/isLoading/purchaseError/purchaseState; PurchaseState.activating :58 (#102, money-moved-server-unconfirmed), :167 activating branch.
- ViewModels/OrderPackViewModel.swift → VM shape to mirror (init(service:), @StateObject).
- Views/MyPacksView.swift → :14 service + @State orders/isLoading/loadFailed, :106 listOrders(). Services/PackOrderService.swift → PackOrderServiceProtocol.
- Services/AuthService.swift → :350 the Logger.network.error("signed-in session dropped") event.
- Utilities/Logging.swift → :74 SentryLog (static enum, .network exists; add the assertable seam).
- HangsTests/PaywallViewInspectorTests.swift, PurchaseActivationTests.swift, StoreManagerTests.swift → must stay green.

Build:
1) T4 — PaywallViewModel(storeManager:limitError:), @StateObject in PaywallView; PaywallView drops @ObservedObject storeManager and binds only the VM; init keeps a storeManager: param forwarded into the VM (keeps PaywallViewInspectorTests constructible). WRAP, never mirror (d): in init subscribe to storeManager.objectWillChange and re-emit self.objectWillChange.send() (stored AnyCancellable); expose purchaseState/offerings/isLoading/purchaseError/effectivePlan/selectedPlan + purchase/resetPurchaseState intents as passthroughs — NO @Published copy of purchase state. Preserve #102 EXACTLY: .activating renders distinct + NO auto-dismiss; only .success auto-dismisses at 1.5 s; #96 P1 fail-loud survives; resetPurchaseState onAppear + triggers intact.
2) T5 — MyPacksViewModel(service: PackOrderServiceProtocol); fold listOrders() + orders/isLoading/loadFailed out of MyPacksView; @StateObject at the owner, mirroring OrderPackViewModel.
3) T6 — Route AuthService warning/error events through SentryLog.warn/.error(_, category: .network), starting with the :350 dropped-session event; KEEP the existing Logger.network calls (f). NO PII — message/attributes describe the failure class only, never token/Apple-identity/account-id. Add the minimal SentryLog seam: a pure event-builder (assert PII-safe) + a test-only recorder/sink (assert the event fired).
4) Tests: PaywallViewModelTests (plan selection, effectivePlan fallback, .activating≠.success no-auto-dismiss, objectWillChange re-publishes on the transition, purchaseState passthrough reflects .success); MyPacksViewModelTests (listOrders load + failure); Sentry tests (dropped-session emits a .network event; builder payload carries no token/PII).

Done = build clean; `grep -n "@ObservedObject" Views/PaywallView.swift` shows no StoreManager, `grep -n "storeManager\." Views/PaywallView.swift` → 0 (only the init param permitted); PaywallViewModel has the objectWillChange subscription in init + no @Published purchase-state mirror; PaywallViewInspectorTests + PurchaseActivationTests + StoreManagerTests + the 3 new test files green on the iOS sim. Commit per task, push, tick T4–T6.
```

---

## Ready prompt — Session C (Verify + adversarial review gate)

```
Work on issue #114 (MVVM conformance), Session C only: verification + the MANDATORY maker≠checker adversarial review (task T7). Sessions A + B must be merged first. You are the CHECKER — a different agent/reviewer than whoever implemented A/B (class-b-adjacent rule). Do NOT re-implement; if you find a defect, record it as a flag and fix only what the review demands.

Read first:
- docs/issues/issue-114-mvvm-conformance-account-paywall.md → task T7 + Research §Class assessment (the 6 points) + Acceptance A1–A15.
- The Session A + B diffs on arch-review-ios (git log/diff).

Do:
1) Run the full named suites on the iOS sim: AppleAuthTests, ContextualSignInSheetTests (behavior), PurchaseActivationTests, StoreManagerTests + new AccountViewModelTests, PaywallViewModelTests, MyPacksViewModelTests. All green. Any FORCED change in a behavior-preservation suite = a flag, not a green light.
2) Re-record the 2 PaywallViewSnapshotTests baselines (limitErrorWithCountdown, noLimitErrorProductLoading in HangsTests/Snapshots/); confirm the diff is MODEL-ONLY (no rendered-pixel change) — non-gating, human sign-off recorded.
3) Sim eyeball (Gate B soft note): run the paywall on the simulator and confirm end-to-end the .task(id: vm.purchaseState) auto-dismiss RE-FIRES via the forwarded objectWillChange — .success dismisses at ~1.5 s, .activating does NOT. Record the observation.
4) Maker≠checker sign-off on the 6 points: (1) SIWA error-handling parity (no silent swallow, .canceled silent, Settings gained the surface); (2) token-swap + onAccountLinked/RC-alias untouched, no view-side Keychain read remains; (3) purchase orchestration (.activating≠.success, activating no-auto-dismiss, success 1.5 s, effectivePlan identical, #96 P1 fail-loud, resetPurchaseState onAppear); (4) PurchaseActivationTests green e2e; (5) new accessor exposes only isSignedIn/currentAccount, not raw tokens; (6) snapshot re-records human-reviewed.

Done = all named suites green; snapshot diff model-only; sim re-fire confirmed; 6-point review signed off (reviewer ≠ implementer), flags recorded. Commit the snapshot re-records + review note, push, tick T7 + flip the issue Status.
```

---

## Status

- ✅ Recon + split done (this doc), 2026-07-20. Decisions (a)–(g) locked from the parent plan; founder default = SURFACE Settings sign-in error (executable, non-blocking).
- ⬜ **Session A — Account seam + VMs (T1–T3)** — not started.
- ⬜ **Session B — Paywall + MyPacks + Sentry (T4–T6)** — not started.
- ⬜ **Session C — Verify + adversarial review gate (T7)** — blocks on A + B.
