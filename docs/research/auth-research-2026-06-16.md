# Issue #58 — Authentication: Research, Design & Plan

**Scope:** Research and planning only. No auth code is written in this issue. Implementation issues are #60+ (#59 is taken by the quiz-flow bug cluster).
**Date:** 2026-06-16
**Status:** Ready for founder decision

---

## 0. Founder Constraints (2026-06-16)

Three hard constraints from the founder that shape every recommendation below:

1. **Global, not EU-only.** Launch is EU-first (SK/CZ) but the app targets the **whole world — US and the rest ASAP**. This means EU data residency is reframed from a *hard requirement* to an *EU-launch advantage*: the chosen approach must be **portable and region-agnostic**, ready to add US/other regions without re-platforming. It also means privacy compliance is **multi-jurisdiction** (GDPR **+ US CCPA/CPRA + others**), not GDPR-only. This is the key reason the recommendation favours **self-owned JWT identity** (no provider/region lock-in) over a managed provider tied to one region.
2. **Usable without login (try-before-sign-up) is mandatory.** A user must be able to open the app and play immediately, with **no login wall** at first launch. This makes **anonymous-first identity (Phase 1) a hard requirement**, not a nice-to-have. Sign in with Apple (Phase 2) is always an *upgrade*, never a gate — which also fits the voice-first / driving UX.
3. **Design screens via Pencil.** The auth flow needs mockups in the live Pencil source (`design/quiz-agent.pen`): anonymous start, contextual "create account / Sign in with Apple" prompt (shown at the freemium limit or at purchase, never at launch), and an account/manage screen with in-app delete. See **§9 Design (Pencil screens)**.

> Where the sections below say "EU data sovereignty", read it as: *an advantage for the EU launch and a portability property that keeps every region open* — Fly.io Postgres can run in fra/ams/cdg today and add US regions (iad/sjc) as the app expands, with no auth-vendor migration.

---

## 1. Is Auth Even Needed?

**Yes — and the current state is broken in three distinct ways.**

The app today uses a client-chosen UUID string (`"dev_" + 16 hex chars`, generated in `PersistenceStore.swift` and stored in UserDefaults) as the sole identity signal. The server trusts it blindly. This creates three compounding problems that are not theoretical:

**Freemium bypass (confirmed in code).** `UsageTracker` in `apps/quiz-agent/app/usage/tracker.py` keys its in-memory dict on whatever `user_id` string the client sends. Three trivial bypasses exist today:
1. Change the `user_id` field to any fresh string → new usage bucket, fresh 20-question daily limit.
2. Wait for a Fly.io deploy/restart → entire in-memory dict is wiped.
3. Delete and reinstall the app → new UUID generated, new limit.

The `is_premium` flag has the same problem: `POST /api/v1/usage/{userId}/premium` is completely unauthenticated. Any caller who knows (or guesses) a `user_id` can elevate themselves to premium at no cost.

**IAP binding is impossible without trusted identity (#50).** If a user purchases a premium tier via StoreKit, the server must link that purchase to a durable, server-verified identity. Right now there is no such identity. Purchases would bind to a UserDefaults UUID that is lost on reinstall.

**Per-account cost protection is unenforceable (#49).** Each quiz question triggers LLM spend (Whisper, GPT-4, TTS). Without verified identity, rate-limit enforcement per account is meaningless — a determined abuser resets their limit for free.

**GDPR forces the issue.** The current UUID, once linked to behavioral data on the server (question count, answer history, timestamps), is pseudonymous personal data under CJEU C-413/23 P (September 2025). This requires a lawful basis, privacy policy, and data deletion endpoint regardless of whether the user ever creates a "real" account.

**Multiplayer.** Not in scope for MVP, but any multiplayer feature (planned post-MVP) requires a server-trusted identity from day one. Retrofitting auth into multiplayer sessions is significantly harder than building it correctly now.

**Verdict: Auth is required before any IAP work (#50) can land and before freemium limits can be considered meaningful.**

---

## 2. Recommended Approach (Executive Summary)

**Implement a server-issued anonymous identity (Phase 1) now, with Sign in with Apple as an upgrade path (Phase 2), without adding any managed auth provider.**

The recommendation is a roll-your-own JWT on FastAPI backed by a Postgres table. The backend mints a signed JWT on first app launch, stores it in the iOS Keychain, and all subsequent requests use `Authorization: Bearer <token>` instead of the current `user_id` body field. The `UsageTracker` is migrated from in-memory to Postgres so limits survive server restarts.

This is the correct choice because:
- The codebase already mints short-lived JWTs: `ElevenLabsTokenResponse` is the exact same pattern extended to general auth.
- Identity data stays on Fly.io Postgres (EU Frankfurt region), the only option with full EU data sovereignty — no US corporate parent can be compelled to disclose it.
- Cost is zero incremental beyond existing Fly.io Postgres.
- App Store Guideline 5.1.1(v) is satisfied: anonymous use is allowed, no forced registration at launch.
- It fixes the freemium bypass immediately and unblocks #50 and #49.

**Main tradeoff:** You write and own the token issuance, refresh rotation, and revocation logic (~150–200 lines of backend code). There is no managed dashboard. This is the correct tradeoff for a solo founder MVP where EU data sovereignty and zero incremental cost matter more than operational convenience.

If and when real accounts with email/social login are needed at scale, Sign in with Apple is the Phase 2 addition — it requires no third-party auth service, satisfies App Store Guideline 4.8, and integrates via a single new FastAPI endpoint verifying Apple's JWKS.

---

## 3. Options Matrix

### 3a. Identity Model

| Option | Description | Cost | EU Residency | Lock-in / Ops | Fit with Stack |
|--------|-------------|------|--------------|---------------|----------------|
| **A-Lite — Server-issued anon JWT (RECOMMENDED)** | Backend mints JWT on first launch; stored in iOS Keychain; Postgres tracks identity | $0 | Full sovereignty (Fly.io fra) | No lock-in; own ~150 lines | Direct fit: ElevenLabsTokenResponse pattern already exists |
| A — Supabase anonymous auth | Supabase issues JWT; anon-to-account upgrade built-in | $0 (free) / $25/mo (Pro) | Data residency: Frankfurt; NOT sovereignty (US CLOUD Act) | Supabase SDK; free tier pauses after 7 days inactivity | Good fit; adds external dependency; free projects pause |
| B — Forced sign-in at first launch | User must register before using the app | $0 | Depends on provider | N/A | Hard App Store violation: Guideline 5.1.1(v) prohibits registration walls for apps without significant account-based features |

### 3b. Sign-in Methods (Phase 2 onward)

| Method | Guideline 4.8 Impact | Cost | EU Residency | Ops | Fit |
|--------|---------------------|------|--------------|-----|-----|
| **Email magic link (RECOMMENDED Phase 2a)** | Proprietary system → 4.8 does NOT apply | $0 (Resend/Postmark free tier) | Inherits Fly.io fra | Low | Direct fit; no third-party auth SDK needed |
| **Sign in with Apple (RECOMMENDED Phase 2b)** | Satisfies 4.8 if any social login added later | $0 | Minimal PII on Apple (global CDN); app data on Fly.io | Low; Apple handles 2FA | Best iOS UX; FastAPI verifies Apple JWKS (~50 lines) |
| Google OAuth | TRIGGERS 4.8 — must add Apple or equivalent simultaneously | $0 | No EU residency; Google US infra | Medium | Only add post-MVP alongside Apple; never before |
| Passkeys (FIDO2, iOS 26+) | Proprietary → 4.8 not triggered | $0 (custom RP) or ~$0 (Hanko EU) | Hanko EU-hosted | Medium (custom RP) or Low (Hanko) | Phase 3 ideal path; iOS 26 ships ASAuthorizationAccountCreationProvider (WWDC25) |
| Firebase Auth | Proprietary | $0 | No EU residency (confirmed US-only as of June 2026) | Low | Hard GDPR blocker; avoid |
| Clerk | Proprietary | $0 free / $25/mo | No EU region at all; DPF-only GDPR posture | Low | Do not use for SK/CZ launch |

### 3c. Backend Provider

| Provider | MAU Free Tier | EU Residency | Lock-in | Ops Burden | Cost at Scale | Fit |
|----------|--------------|--------------|---------|------------|--------------|-----|
| **Self-issued JWT on Fly.io Postgres (RECOMMENDED)** | Unlimited (own infra) | Full sovereignty (no US parent) | None | Own ~200 lines | $0 incremental | Perfect: ElevenLabs pattern, FastAPI native, existing Postgres |
| Supabase Auth (Frankfurt) | 50,000 MAU; pauses after 7d inactivity | Data residency only (US CLOUD Act applies) | Moderate (GoTrue schema) | Very low | $25/mo (Pro, removes pause) | Good fallback if ops burden becomes a concern |
| Auth0 (EU region) | 25,000 MAU | Data residency only (Okta US CLOUD Act) | High | Low | $35/mo (Essentials, 500 MAU base) | Overkill; expensive at small scale |
| Firebase Auth | 50,000 MAU | None (US-only, confirmed June 2026) | High | Low | Pay-as-you-go | Hard GDPR blocker for SK/CZ |
| Clerk | 50,000 MRU | None (DPF-only) | Moderate | Very low | $25/mo (Pro) | Do not use for EU-first app |

---

## 4. iOS Integration Plan

### Architecture

A new `AuthService` actor sits between `AppState` and `NetworkService`. `QuizViewModel` does not change — auth is transparent to it.

```
AppState (@MainActor)
  ├── AuthService (actor)          ← NEW: owns Keychain + Apple credential state
  └── NetworkService (actor)       ← EXTENDED: reads bearer token from AuthService
        └── QuizViewModel (@MainActor)  ← UNCHANGED
```

### Sign in with Apple Flow

**iOS side (AuthenticationServices — no third-party SDK):**

1. On first launch (no Keychain token), `AuthService` calls the bootstrap endpoint to get a server-issued anonymous JWT. Store in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
2. When user opts in to a real account, generate a 32-byte random nonce; compute SHA-256; pass hash to `ASAuthorizationAppleIDProvider().createRequest()`. Set `.requestedScopes = [.fullName, .email]`.
3. From `didCompleteWithAuthorization`, extract `credential.identityToken` (10-min JWT, not refreshable from iOS) and `credential.authorizationCode` (one-time). Send both plus the raw nonce to the backend's `POST /api/v1/auth/apple`.
4. Store the `apple_sub` (stable Apple user ID from `credential.user`) and the server-issued session token in Keychain. Do NOT store the Apple identity token — it expires in ~10 minutes.

**Keychain accessibility — critical for the driving use case:**

The app runs with background audio mode enabled (`Info.plist`). When the screen locks during a drive, `kSecAttrAccessibleWhenUnlocked` items become inaccessible to background tasks. The correct attribute is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: items are accessible from the first unlock post-reboot through subsequent screen locks, which covers the entire driving session. Do NOT add biometric flags to auth tokens — a Face ID prompt is impossible while driving.

**Revocation checks on cold launch:**

```swift
ASAuthorizationAppleIDProvider().getCredentialState(forUserID: storedAppleSub) { state, _ in
    switch state {
    case .authorized: break
    case .revoked, .notFound: // sign out, clear Keychain, revert to anonymous
    case .transferred: // rare: developer account transfer
    }
}
```

This call is local (no network). Do not block the UI on it — fire and update state reactively. Also register `ASAuthorizationAppleIDProvider.credentialRevokedNotification` as a belt-and-suspenders mid-session signal. Note: community reports indicate the notification has reliability issues across iOS versions — the cold-launch `getCredentialState` check is the primary mechanism.

**Token refresh and 401 handling in NetworkService:**

`NetworkService` catches a 401 from any endpoint and calls `authService.refreshServerToken()`. That method POSTs to `/api/v1/auth/refresh`. A single `Task<Token, Error>?` inside `AuthService` prevents duplicate refresh races (Donny Wals deduplication pattern). After refresh, the original request is retried once.

**Anonymous-to-Apple upgrade path:**

`PersistenceStore.deviceId` continues generating `"dev_XXXX"` until sign-in. On Apple sign-in success, the upgrade request sends both the old `deviceId` and the new `apple_sub`. The backend merges usage history (question count, premium status, rating history) from the `device_id` row to the `apple_sub` row, then returns a new server JWT. From that point all requests use `Authorization: Bearer` header. The `deviceId` is retired but kept in Postgres as a migration key.

This ensures a user who played 10 anonymous questions before signing in keeps those 10 questions counted — required for freemium fairness.

**App Attest (optional hardening):**

`DCAppAttestService` is available on iOS 14+ devices with a Secure Enclave — in practice iPhone 6S / SE 1st gen or newer (not iPhone 5S, which cannot run iOS 14). Before committing to App Attest as a hard requirement, verify the app's minimum deployment target (currently iOS 18.0 per ios.md rules — full coverage on all supported devices). App Attest adds one Apple server round-trip at first install only; subsequent assertions are local ECDSA operations with no Apple contact. It closes the bootstrap endpoint abuse surface. Consider for Phase 2, not Phase 1.

---

## 5. Privacy & Compliance Checklist (multi-jurisdiction)

> **Global scope (founder constraint #1):** GDPR is the *strictest* baseline and is treated as the default below, but the app ships worldwide. The same machinery (lawful basis, in-app delete, data export, deletion-on-request) also satisfies **US CCPA/CPRA** (right to know / delete / opt-out of "sale" — we sell nothing, which simplifies this) and most other regimes. Build to the GDPR bar once and the rest is largely covered; the only per-region additions are localized privacy-policy text and the App Store privacy labels (already global). No architectural change is needed for non-EU regions — only the Postgres region expands (see §6).

### Lawful Basis

| Data | Purpose | Basis |
|------|---------|-------|
| Anonymous session UUID / apple_sub | Account creation, auth, session management | Art 6(1)(b) — contract |
| Daily question count | Freemium limit enforcement | Art 6(1)(f) — legitimate interest |
| Quiz history, ratings | Abuse prevention, question quality | Art 6(1)(f) — legitimate interest |
| IAP purchase binding | Premium entitlement | Art 6(1)(b) — contract |

Document the legitimate-interest balancing test for the usage analytics basis. EDPB Recommendations 2/2025 on mandatory user accounts are currently in public consultation (closed February 2026, not yet finally adopted as of June 2026) — they are persuasive but not binding; document the reasoning independently.

### Required Endpoints (non-optional)

- `DELETE /api/v1/auth/me` — deletes all user data from Postgres (usage records, quiz history, ratings, apple_sub row); calls Apple token revocation endpoint (`https://appleid.apple.com/auth/revoke`) if the user has a linked Apple account. Required by App Store Guideline 5.1.1(v) and GDPR Article 17.
- `GET /api/v1/auth/me/export` — returns a JSON dump of the user's account data, usage history, and quiz results. Required by GDPR Article 20 (data portability).

**Account deletion note:** Apple's guideline requires an in-app deletion option, but a web redirect is permitted as long as it links directly to the deletion page (not a general settings page). This means a v1 implementation can use an in-app button that opens a deep-linked web page while the full in-app flow is built. Do not redirect to a generic settings page.

**GDPR deletion timeline:** The regulation says "without undue delay" (GDPR Art. 17), which regulators interpret as approximately one month, with a two-month extension available for complex cases (with notification to the subject within month one). A 30-day operational target is reasonable but is not the statutory deadline.

### iOS App Store Requirements

- **In-app account deletion UI:** Required before App Store submission once sign-in is supported. Add to Settings/Profile screen.
- **Privacy nutrition label (App Store Connect):** Declare: User ID (identifiers, linked to user); Usage Data (linked to user); Purchases (linked to user). Do NOT declare Contact Info unless you actively collect email.
- **PrivacyInfo.xcprivacy manifest:** Required for App Store submission since May 2024. The app must declare any `NSPrivacyAccessedAPITypes` used (e.g., UserDefaults access for the current `deviceId` store). Failure to include it blocks submission. Add this to Phase 1.
- **Sign in with Apple token revocation:** If Sign in with Apple is implemented, account deletion must call `https://appleid.apple.com/auth/revoke` with the Apple refresh token. Apple's documentation uses "should" but App Store review treats this as a hard requirement in practice.

### Data Retention Policy

| Data Category | Retention |
|---------------|-----------|
| Account data (apple_sub, email) | Duration of account + 1 year post-deletion |
| Daily usage counters | 90 days rolling |
| Quiz history (question IDs, answers) | Duration of account |
| Server logs | 30 days |
| Session data (in-memory) | TTL per session (30–120 min) |

### Record of Processing Activities (RoPA)

Write a one-page RoPA documenting: data category, purpose, lawful basis, retention period, and processor. The processor entry for Phase 1 is: Fly.io (hosting, EU Frankfurt region). For Phase 2 add Apple (identity token verification, global CDN — minimal PII).

---

## 6. Phased Implementation Plan

> These phases become separate implementation issues #60, #61, #62. Issue #58 (this document) is planning only.

### Phase 1 — Server-Trusted Anonymous Identity (fixes the bypass)

**What it delivers:** The freemium limit becomes trustworthy. The `setPremium` endpoint is auth-guarded. The daily limit survives server restarts. All blocked by #50 and #49 today.

**Scope:**

Backend (`apps/quiz-agent`):
- New Postgres table: `anonymous_identities(anon_id UUID PK, device_fingerprint TEXT, issued_at TIMESTAMPTZ, upgraded_to_user_id UUID NULLABLE)` and `refresh_tokens(token_hash TEXT PK, anon_id UUID, expires_at TIMESTAMPTZ)`.
- New Postgres table for persistent usage: `daily_usage(user_id UUID, date DATE, questions_count INT, is_premium BOOL, PRIMARY KEY(user_id, date))`.
- `POST /api/v1/auth/anon-bootstrap` — issues a long-lived refresh token + short-lived (15-min) access token (JWT, HS256, `anon_id` in `sub` claim). Rate-limit this endpoint by IP.
- `POST /api/v1/auth/refresh` — exchanges refresh token for new access JWT.
- Migrate `UsageTracker` to write to `daily_usage` table instead of the in-memory dict. The in-memory dict wipes on restart; the Postgres table does not.
- Add `Depends` middleware extracting `user_id` from `Authorization: Bearer` header. Fall back to client-sent `user_id` body field only during a grace period to avoid breaking the existing app in the field.
- Guard `POST /api/v1/usage/{userId}/premium` with the auth middleware.

iOS (`apps/ios-app`):
- New `AuthService` actor owning Keychain reads/writes (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- On first launch (no Keychain token), call `/auth/anon-bootstrap`, store returned tokens in Keychain.
- Extend `NetworkService` to add `Authorization: Bearer <token>` header on all requests. `QuizViewModel` is unchanged.
- Add `PrivacyInfo.xcprivacy` manifest (non-optional; blocks App Store submission if missing).

**Size: M** (backend migration is the main work; iOS Keychain setup is well-scoped)
**Dependencies:** None — this is the foundation. #49 and #50 depend on Phase 1.
**Issue:** #60 (new)

---

### Phase 2 — Sign in with Apple (optional real account)

**What it delivers:** Durable cross-device identity. IAP purchases bind to `apple_sub`, which survives app reinstall. Satisfies Guideline 4.8 if Google is added later. Users who delete the app can recover their quiz history and premium status by signing in again.

**Scope:**

Backend:
- New table: `users(id UUID PK, apple_sub TEXT UNIQUE, email TEXT, plan_tier TEXT, created_at TIMESTAMPTZ)`.
- `POST /api/v1/auth/apple`: verify identity token against Apple JWKS (`https://appleid.apple.com/auth/keys`, cache 24h), validate nonce, exchange `authorization_code` for Apple refresh token (using ES256 client_secret JWT; max expiry 15,777,000 seconds / ~6 months), upsert user row, merge anonymous usage history from `device_id` to `apple_sub`, return server-issued JWT.
- `POST /api/v1/auth/refresh`: standard token refresh.
- `DELETE /api/v1/auth/me`: delete user row + usage data + quiz history; call `https://appleid.apple.com/auth/revoke` with the stored Apple refresh token. Required by App Store Guideline 5.1.1(v) and GDPR Art. 17.
- `GET /api/v1/auth/me/export`: GDPR Art. 20 data export.
- Client-secret generation utility: PyJWT + `.p8` key from Apple Developer Portal. Key ID and Team ID stored as Fly.io secrets.

iOS:
- Add "Sign in with Apple" capability in Xcode Signing & Capabilities.
- `AuthService`: add nonce generation (32 random bytes, SHA-256), `ASAuthorizationAppleIDProvider` credential flow, `getCredentialState` on cold launch, `credentialRevokedNotification` observer, anonymous-to-Apple upgrade request.
- In-app "Delete Account" UI in Settings screen (mandatory before App Store submission).
- App Store privacy nutrition label update.

**Size: M–L** (Apple client_secret generation + token revocation are the trickiest parts)
**Dependencies:** Phase 1 (server auth middleware must be in place; `anon_id` must exist to merge).
**Also depends on #50** (StoreKit IAP binding): `apple_sub` is the anchor that StoreKit purchases bind to. Coordinate with #50 so the `users` table schema satisfies both.
**Issue:** #61 (new)

---

### Phase 3 — Cross-Device + Full Purchase Binding

**What it delivers:** A user can uninstall, reinstall, and sign in on any iPhone to recover full history, premium status, and all IAP entitlements. Post-MVP multiplayer identity foundation.

**Scope:**
- IAP receipt verification: the existing JWS verifier in `apps/quiz-pack-api/app/storekit/verifier.py` (ES256 ECDSA, Apple G3 root cert, Redis-backed 60s cache) is the model. Wire StoreKit V2 signed transactions to the `users` table via `apple_sub`.
- `PATCH /api/v1/auth/upgrade` — if email magic link is added later: link `anon_id` to a new email-based `user_id` without losing history.
- Consider passkeys (Hanko EU-hosted, or custom WebAuthn relying party) as a login method — iOS 26 ships `ASAuthorizationAccountCreationProvider` (WWDC25, verified) enabling one-tap passkey provisioning. By Phase 3 the iOS 26 install base may justify it. Magic link becomes the recovery fallback.
- App Attest on bootstrap endpoint (harden against fake clients generating identity tokens).

**Size: L** (IAP binding + passkeys + multi-device recovery are substantial)
**Dependencies:** Phase 2 (apple_sub must exist); #50 (IAP must be live).
**Issue:** #62 (new)

---

## 7. What the Research Corrected vs. #58's Assumptions

The following claims in the original #58 issue framing were checked against primary sources and required correction:

**The quiz-pack-api JWS verifier does NOT apply to freemium auth.** The #58 issue suggested the existing `AppleJWSVerifier` in `apps/quiz-pack-api/app/storekit/verifier.py` (with its Redis-backed 60s verify cache in `jws_cache.py`) could be reused for the general auth problem. This is incorrect. That verifier is purpose-built for StoreKit V2 IAP signed transactions sent in the `X-StoreKit-JWS` header to `POST /v1/orders` in quiz-pack-api. It does not touch the quiz-agent backend, does not know about `user_id`, and cannot validate the identity tokens issued by Sign in with Apple at the session bootstrap. The two verification paths are different: IAP receipt verification (ES256 ECDSA + Apple G3 cert chain) vs. Apple identity token verification (RS256 + Apple JWKS). They can share conceptual inspiration but not code.

**App Attest device floor was overstated.** An earlier research pass claimed App Attest covers "Touch ID devices from iPhone 5S onward." Incorrect: iPhone 5S cannot run iOS 14 (maxes out at iOS 12), so App Attest is unavailable on it. The correct floor is iPhone 6S / SE (1st gen) or newer — devices that support both iOS 14+ and the Secure Enclave. Since this app targets iOS 18.0 (per ios.md), all supported devices have App Attest available (`DCAppAttestService.shared.isSupported` will return `true` on all deployment targets).

**GDPR deletion is "without undue delay," not "within 30 days."** GDPR Article 17 uses "without undue delay." The 30-day figure is a common operational interpretation, not the statutory standard. Regulators allow up to two months for complex cases with notification within month one.

**App Store account deletion does allow web redirect.** The original research suggested "redirecting to a web page is insufficient." Apple's support page (`developer.apple.com/support/offering-account-deletion-in-your-app/`) explicitly permits a direct link to a web deletion page as an acceptable implementation. A full in-app flow is preferred but not mandated — the key requirement is that the link goes directly to the deletion page, not to a general settings menu.

**Guideline 4.8 (January 2024 revision) loosened the requirement, not tightened it.** The January 25, 2024 update removed the explicit mandate to offer "Sign in with Apple" by name. It now requires "another login service" meeting three criteria (name+email only, private email option, no ad tracking). Sign in with Apple satisfies these criteria and is the de facto compliant path, but the guideline is technology-neutral. Any privacy-preserving login service meeting all three criteria qualifies.

**EDPB Guidelines 01/2025 on Pseudonymisation are still in draft.** As of June 2026 these remain in public consultation — not finally adopted. Do not cite them as binding guidance; they are persuasive drafts only.

**Supabase free tier pauses projects after 7 days of inactivity.** This makes the Supabase free tier unsuitable for an always-on production backend without the $25/month Pro plan. Relevant if Supabase Auth is considered as a future migration.

---

## 8. Open Questions for the Founder

These are the decision gates that must be resolved before #60 can be spec'd and handed to the agent loop:

1. **App Attest on Phase 1 bootstrap?** App Attest makes the anonymous identity harder to mint from non-genuine app builds, closing the most sophisticated bypass. The tradeoff: one extra Apple server round-trip at first install, ~1 week of backend work (Python `cbor2` + `cryptography` verification). Given the app is in founder + close-circle beta, is the abuse risk high enough to justify Phase 1 App Attest, or is IP-based rate limiting on the bootstrap endpoint sufficient for now?

2. **Fly.io Postgres region confirmation.** The recommendation assumes Postgres is deployed to an EU Fly.io region (fra/ams/cdg) to satisfy the EU data residency posture. Confirm the current Fly.io Postgres region in use. If it is a US region, a migration or new database in an EU region is required before Phase 1 can claim GDPR-compliant data residency.

3. **Phase 1 grace period for existing in-field installs.** The current app sends `user_id` as a JSON body field with no bearer token. When Phase 1 lands, the backend must accept both the old (unauthenticated body `user_id`) and new (bearer token) until all users have updated. How long a grace period is acceptable before the server stops accepting unauthenticated requests? (Suggested: 30 days post-release, then drop unauthenticated path.)

4. **Sign in with Apple in Phase 2: required or optional?** The freemium bypass is fixed in Phase 1. Sign in with Apple enables cross-device identity recovery and is the IAP binding anchor for #50. Is Phase 2 a hard prerequisite for IAP (#50), or can #50 land with anonymous identity only and add account recovery later?

5. **Email magic link: include or skip?** Sign in with Apple is iOS-only. If a web UI (`apps/web-ui`) ever needs authentication, or if Android is a future target, email magic link is the portable fallback. Is there a plan for cross-platform auth, or is iOS-first acceptable for the foreseeable future?

6. **`.p8` key management for Sign in with Apple.** The Apple token exchange requires an ES256 private key (`.p8` file) and a Key ID + Team ID from the Apple Developer Portal. This key must be stored as a Fly.io secret. The `.p8` key expires after 6 months at maximum (15,777,000 seconds). Confirm that Fly.io secret rotation for the `.p8` key can be done by the autonomous agent (Ralph), or whether it requires a human action that needs to be calendared.

7. **Supabase as future migration target?** The recommendation is roll-your-own JWT for Phase 1 and Phase 2. If auth ops (user lookup, deletion, export) become burdensome as the user base grows, Supabase Auth (Frankfurt, 50k MAU free) is the cleanest migration target. Is this acknowledged as the escape hatch, or is the preference to stay on self-managed Postgres auth indefinitely?

---

## 8b. Founder Decisions (2026-06-17)

The founder reviewed §8. Resolutions below; these are the inputs for spinning off #60/#61/#62
(**not** #59/#60/#61 — #59 was taken by the quiz-flow bug cluster).

1. **Anti-abuse level → STRONG NOW.** App Attest is pulled **into Phase 1** (not deferred). The anonymous bootstrap endpoint must verify the request comes from a genuine app build (`DCAppAttestService`), so even the self-issued anonymous token can't be minted by a fake client. *Impact: Phase 1 grows from M to **L** (~1 week added for `cbor2`/`cryptography` attestation verification + one Apple round-trip at first install).*

2. **Platforms → iOS-only for MVP; keep the door open.** Web/Android are expected *eventually* but not soon (only after iPhone shows relative success). So MVP ships **Sign in with Apple only**; **email magic link is deferred**. The self-issued-JWT architecture already keeps magic link cheap to add later (no provider swap) — this property must be preserved (don't adopt anything Apple-only at the token layer).

3. **Paid IAP without login → APPROVED, with one constraint (verified 2026-06-17).** Verified against first-party Apple sources (WWDC22 "Implement proactive in-app purchase restore", TN2413, Review Guidelines §3.1.1/§5.1.1(v)):
   - **Auto-renewable subscriptions** and **non-consumables** restore automatically via the Apple ID through `Transaction.currentEntitlements` — **no app account required**, fully documented, and a Restore Purchases mechanism is itself mandated by §3.1.1.
   - **Consumables are NOT restorable** (TN2413) and are excluded from `currentEntitlements`; surviving reinstall/cross-device would force a server-side ledger keyed to an identity *before* launch.
   - **→ Constraint for #50:** ship premium as an **auto-renewable subscription** (and any "packs" as **non-consumables**, never consumables). Then paid IAP launches cleanly on anonymous identity, and Sign in with Apple is a pure Phase-2 upgrade. *Founder caveat:* if deferring login later proves to complicate the upgrade/merge, reconsider pulling Sign in with Apple into the App Store launch release.

4. **EU data residency → already satisfied.** Both Fly.io apps run `primary_region = "cdg"` (Paris). No migration needed for the EU launch; add US regions (iad/sjc) on expansion, no auth-vendor change (the reason self-owned JWT was chosen).

5. **Deferred technical questions (not blocking #60):** grace period for old in-field installs = **30 days** (default accepted); Apple `.p8` key rotation (6-month max) and Supabase-as-escape-hatch are **Phase 2 notes**, revisited when #61 is specced.

---

## 9. Design (Pencil screens)

The auth flow is **anonymous-first with a contextual upgrade** (founder constraint #2 — no login wall). Screens to design in the live Pencil source `design/quiz-agent.pen`:

1. **Anonymous start** — first launch goes *straight into the app/quiz*, no auth UI at all. (Often this is "no new screen" — just confirm the existing entry screen has no gate. Worth a frame to document the decision.)
2. **Contextual account prompt** — a sheet shown **only** when it earns its place: at the freemium daily limit ("you've hit today's free questions — keep going / create an account") or at purchase (#50). Primary action: **Sign in with Apple** button (Apple's required style). Secondary: "Maybe later" / continue anonymous. Never shown at launch.
3. **Account / Manage screen** — signed-in state: account identity, premium status, restore purchases (ties to #50), **Delete account** (in-app, mandatory — App Store §5.1.1(v) + GDPR Art. 17) and **Export my data** (Art. 20). Deletion needs a confirm step.
4. *(optional)* **Post-upgrade confirmation** — brief "your progress is saved across devices" affirmation after the anonymous→Apple merge, to make the value of signing in tangible.

These mockups are produced as a follow-up step once this doc is approved (the flow must be fixed first). They feed the iOS implementation in Phase 2 (#61).

---

## Key Sources

- Apple App Store Review Guidelines §4.8 and §5.1.1(v): [developer.apple.com/app-store/review/guidelines/](https://developer.apple.com/app-store/review/guidelines/) (fetched live 2026-06-16)
- Apple account deletion support: [developer.apple.com/support/offering-account-deletion-in-your-app/](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- Apple JWKS endpoint (confirmed live): [appleid.apple.com/auth/keys](https://appleid.apple.com/auth/keys)
- Apple client_secret JWT: [developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret)
- CJEU C-413/23 P (September 2025, pseudonymised data ruling): confirmed via Goodwin Law / Taylor Wessing analyses
- Supabase pricing (confirmed live): [supabase.com/pricing](https://supabase.com/pricing)
- Supabase DPA: [supabase.com/downloads/docs/Supabase+DPA+250314.pdf](https://supabase.com/downloads/docs/Supabase+DPA+250314.pdf)
- Firebase Auth EU residency (confirmed US-only June 2026): [firebase.google.com/support/privacy](https://firebase.google.com/support/privacy)
- iOS 26 passkeys / ASAuthorizationAccountCreationProvider: WWDC25 session 279 [developer.apple.com/videos/play/wwdc2025/279/](https://developer.apple.com/videos/play/wwdc2025/279/)
- PrivacyInfo.xcprivacy enforcement: Apple developer news, May 1 2024
- EU-US Data Privacy Framework (DPF) status: EU General Court upheld in Sept 2025 (Latombe); CJEU appeal filed Oct 2025 (C-703/25 P), pending
