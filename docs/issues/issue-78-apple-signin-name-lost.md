# Issue #78 — Bug: Sign in with Apple name disappears after re-sign-in (no server round-trip)

**Triage:** bug · needs-triage (draft from UI/UX review 2026-07-03)

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

- [ ] Sign out → sign in again with the same Apple ID: Name row still shows the user's name
- [ ] Fresh install + sign-in with an already-consented Apple ID: name appears (recovered from server)
- [ ] Revoked-credential recovery keeps the stored name
- [ ] Unit test: merge logic never replaces non-nil `accountName` with nil
- [ ] `/verify-api` passes (iOS Codable matches updated `AuthTokenResponse`)
