# Issue #62 — Auth Phase 3: Cross-Device + Full Purchase Binding

**Triage:** enhancement · ready-for-human (auth + IAP receipt verification — maker≠checker)
**Reversibility:** c · StoreKit V2 receipt binding + optional passkeys/magic-link recovery — **NOT blind-overnight eligible** (payment + auth; human-reviewed).
**Status:** Spun off 2026-06-17 from #58 research §6 Phase 3. Phase 3 of 3 — post-MVP hardening. **Depends on #61 + #50.**

> Plan: [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md) §6 (Phase 3). Research issue: [#58](issue-58-authentication.md).

## Why

Phase 2 (#61) gives a recoverable Apple account. Phase 3 closes the loop on **full multi-device entitlement recovery** and lays the identity foundation for post-MVP multiplayer:

- Uninstall → reinstall → sign in on any iPhone recovers full history, premium status, and **all IAP entitlements**.
- Establishes server-side purchase truth (not just `Transaction.currentEntitlements` on-device).
- Sets up the identity layer multiplayer will need.

## Scope

- **IAP receipt verification:** the existing JWS verifier in `apps/quiz-pack-api/app/storekit/verifier.py` (ES256 ECDSA, Apple G3 root cert, Redis-backed 60s cache) is the **model** — note it is StoreKit-IAP-only and **cannot be reused for general auth** (§7). Wire StoreKit V2 signed transactions to the `users` table via `apple_sub`.
- `PATCH /api/v1/auth/upgrade` — when/if email magic link is added: link `anon_id` to a new email-based `user_id` **without losing history**.
- **Passkeys (evaluate):** iOS 26 ships `ASAuthorizationAccountCreationProvider` (WWDC25 session 279, verified) enabling one-tap passkey provisioning. By Phase 3 the iOS 26 install base may justify it; magic link becomes the recovery fallback. Decision gate, not a commitment.
- **App Attest on bootstrap** is already in #60 (founder pulled it into Phase 1) — Phase 3 only revisits hardening if abuse patterns emerge.

## Size & dependencies

**Size: L** — IAP binding + (optional) passkeys + multi-device recovery are substantial.
**Depends on:** #61 (`apple_sub` must exist) · #50 (IAP must be live).

## Tasks (atomic)

- [ ] 62.1 — Wire StoreKit V2 signed transactions to `users` via `apple_sub` (server-side entitlement truth).
- [ ] 62.2 — Cross-device recovery: reinstall + sign-in restores history + premium + entitlements end-to-end.
- [ ] 62.3 — (decision gate) Evaluate passkeys via `ASAuthorizationAccountCreationProvider` against the then-current iOS 26 install base; document go/no-go.
- [ ] 62.4 — (if magic link lands) `PATCH /auth/upgrade` linking `anon_id`→email `user_id` without history loss.
- [ ] 62.5 — Tests: pytest for receipt binding + recovery; iOS unit/regression for the recovery flow.

## Acceptance

- [ ] On a fresh device, reinstall + Sign in with Apple restores history, premium status, **and** all IAP entitlements (server-verified, not just on-device).
- [ ] StoreKit V2 transaction verification binds to `apple_sub` and survives reinstall.
- [ ] Passkey go/no-go documented with the install-base rationale.
- [ ] pytest + iOS suites green; **human review** signed off.

## Cross-refs

- #58 (parent) · #61 (Phase 2 prerequisite) · #50 (IAP live) · #48 (security review) · post-MVP multiplayer (product vision).
