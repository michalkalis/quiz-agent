# Issue #78 — Bug: Sign in with Apple name disappears after re-sign-in (no server round-trip)

**Triage:** bug · **RESOLVED 2026-07-16** (workflow-implemented in worktree, merged to main; see Resolution)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** founder report ("po opätovnom prihlásení sa nezobrazilo meno") + UI/UX review code verification

**Severity:** high — founder-reproduced on device; permanent-looking data loss from the user's perspective.

## Problem

Apple delivers `fullName`/`email` **only on the very first authorization** of an Apple ID with the app.
The app persists the name correctly on first sign-in (Keychain + backend), but on **any subsequent
sign-in** (sign-out → sign-in, reinstall, revoked-credential recovery) Apple supplies `fullName: nil`,
and the client rebuilds and **overwrites the whole Keychain auth blob with `accountName: nil`** — with
no way to recover the name, because the `/auth/apple` response carries only tokens. The backend still
has the name forever; the client just never gets it back. Settings then silently omits the Name row.

## Evidence (code-verified 2026-07-03)

- First sign-in persists correctly: `SettingsView.swift:276-291` (reads live `credential.fullName`) → `AuthService.swift:431-440` (`AuthTokens(accountName:…)` → `store.save`); backend writes `full_name` once and never clobbers it with a later null (`apps/quiz-agent/app/api/routes/auth.py:385-386`).
- Display reads the persisted value, not the live credential: `SettingsView.swift:212` (`if let name = tokens.accountName`).
- Root cause: `AuthTokenResponse` (`apps/quiz-agent/app/api/deps.py:202-215`) has **no `full_name`/`email` field** — on re-sign-in the client has nothing to merge from, and `store.save` at `AuthService.swift:431-440` does a whole-blob overwrite (no nil-merge).
- Revoked-credential recovery path also rebuilds tokens from a nil name: `AuthService.swift:454-473`.
- Backend keeps the name durably (`app/db/models.py:181`); only `GET /auth/me/export` ever returns it.
- Gap is untested in `AppleAuthTests.swift`.
- Apple-documented behavior (see `docs/research/uiux-hig-research-2026-07-03.md` §2): fullName/email arrive only on first consent; Apple says persist immediately.

## Recommendation

1. Backend: include `full_name` (and `email` if stored) in the `/auth/apple` response model.
2. iOS: on sign-in, merge — prefer a non-nil live `credential.fullName`, else the server-returned value, else the existing Keychain value. Never overwrite a non-nil stored `accountName` with nil.
3. Follow the API-contract flow (update Pydantic model → `/verify-api` → Codable struct).

Cross-refs: #61 (Sign in with Apple — parent feature, still open `ready-for-human`).

## Acceptance

- [x] Sign out → sign in again with the same Apple ID: Name row still shows the user's name (covered by unit tests #78 a/b; on-device founder check pending)
- [x] Fresh install + sign-in with an already-consented Apple ID: name appears (recovered from server — `/auth/apple` now returns stored `full_name`/`email`)
- [x] ~~Revoked-credential recovery keeps the stored name~~ **obsolete** — current architecture (post-#61) deliberately drops to a fresh anonymous identity on revoke (tested full sign-out, not a name-loss bug); the name is recovered on the next sign-in via the server round-trip above
- [x] Unit test: merge logic never replaces non-nil `accountName` with nil (`AppleAuthTests` #78 a–d + refresh precedence)
- [x] `/verify-api` passes — iOS `TokenResponse` now decodes all 7 backend fields incl. `token_type`/`expires_in`

## Resolution (2026-07-16)

Implemented per Recommendation, plus one scope expansion found during recon: the **token-refresh
path** (`performRefreshOrBootstrap`) had the same whole-blob nil-overwrite and fired on every
successful refresh (~every 15 min), silently reverting a signed-in user to anonymous-looking state —
a much more frequent trigger of the same symptom. Fix:

- Backend: `AuthTokenResponse` gained nullable `full_name`/`email`; populated on `/auth/apple`
  (from the persisted user row) and `/auth/refresh` (user lookup by subject id).
- iOS: `mergedAccountField(live:server:stored:)` precedence merge applied at both `AuthTokens`
  build+save sites; `appleUserId` always carried forward on refresh. Codable struct brought into
  exact field-by-field agreement with the backend model.
- Tests: backend re-sign-in + refresh round-trip tests; 5 new iOS merge-matrix tests. Backend
  265 passed / iOS AppleAuthTests 9/9 green. Diff review (opus + adversarial verify): no must-fix.

Remaining human leg: founder on-device sign-out → sign-in check (fold into the #96 on-device checklist).
