# App Store Readiness Audit — 2026-07-30

**Verdict: NOT READY to submit.** Submission is mechanically impossible today (no privacy-policy URL, ASC listing unfinished), and even with those fixed the review would likely reject on paywall-compliance and data-deletion grounds. Separately, the product is not sellable: prod serves 31 approved questions against a 30/month free tier.

Scope: iOS app (`apps/ios-app`), both backends on Fly (prod live-checked), docs/TODO/issue state, legal assets. Evidence = `file:line` or doc reference.

---

## B — Blockers (cannot submit / near-certain rejection)

**B1. No privacy policy or Terms of Use exist — anywhere.**
- No policy text, no hosted page, no support URL, no marketing site in the repo; `docs/artifacts/legal-compliance-map-2026-07-03.html` states this explicitly. `apps/web-ui` no longer exists.
- In-app: zero links to Privacy Policy or Terms/EULA (broad grep; only `PrivacyInfo.xcprivacy` manifest exists). Paywall (`Views/PaywallView.swift`) has price, restore, auto-renew text — but not the two links Apple requires for auto-renewable subs (Guideline 3.1.2).
- ASC won't accept a submission without a privacy-policy URL at all.

**B2. App Store Connect listing not prepared (#50 — ASC listing, `ready-for-human` since 2026-06-09, pre-dates the subscription model).**
- Missing: description, subtitle, keywords, App Store screenshots, privacy nutrition labels (#61 leg open), age rating, support URL, review notes/demo account. No fastlane `metadata/`/`screenshots/` dir; Fastfile has no `upload_to_app_store`/`deliver` lane — pipeline ends at TestFlight (`fastlane/Fastfile` L30-124).
- IAP products + subscription group must exist and be attached to the first submission in ASC (repo cannot verify ASC state — founder check).

**B3. Content: prod corpus = 31 approved questions** (12 text + 19 MCQ, all `general`; `docs/reviews/corpus-audit-2026-07-28.md`, TODO line 32) vs `FREE_MONTHLY_LIMIT=30` (`app/usage/tracker.py:39`). A €4.99 subscriber exhausts all content in one sitting. Generation is PARKED behind #99 Phase 4 founder blind rating; quality flags (A1, P0 of `docs/research/generation-review-2026-07-30.md`) confirmed unset on both Fly envs (re-verified live today). #30 (grow corpus → ~500) blocked behind it.

**B4. Purchases never verified end-to-end on device.** Sandbox purchase test FAILED on device (#96 S1 / #93 RC `[HUMAN]` leg); #101 founder TestFlight sandbox-purchase validation never executed (issue-101 L96). App Review exercises IAP; an unverified purchase path is a rejection risk and a business risk.

**B5. Data deletion missing for anonymous users (Guideline 5.1.1(v)).** Server-side identity exists from first launch (device/App Attest bootstrap, `Services/AuthService.swift`), but delete-account is gated on Sign in with Apple (`SettingsView.swift:449`; anonymous state shows only a sign-in button, `:456-483`). Backend `DELETE /auth/me` exists (`AuthService.swift:666-688`) — the gap is iOS-side exposure.

## H — High risk (fix before submitting)

- **H1. Raw voice-transcript logging must be removed before GA** — explicit TODO (line 52). Privacy-label answers must match actual collection; transcripts are sensitive.
- **H2. EU AI Act Art. 50 AI-disclosure notice — deadline 2026-08-02 (in 3 days)**; 18+ age-gate decision and data-retention periods also open (`legal-compliance-map-2026-07-03.html`).
- **H3. Divergent mic purpose strings via dual Info.plist mechanism**: physical `Info.plist:68` text ≠ `Shared.xcconfig:21` text, with `GENERATE_INFOPLIST_FILE=YES` also active — ambiguous which ships; mic/speech texts are review-sensitive. Same dual-mechanism issue for `UILaunchScreen`.
- **H4. Version literals hardcoded** — `Info.plist:20,22` pin `1.0`/`1` as literals instead of `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` (Shared.xcconfig:47-48) — build-number bumps for successive uploads won't propagate.
- **H5. Beta TF track still ships staging** (596-question stale corpus) against the founder's 2026-07-30 prod-only directive; staging apps saw a deploy today. Re-point beta or retire it before launch. Same bundle ID across Local/Staging/Prod (`com.missinghue.hangs`) — accepted MVP decision, noted.
- **H6. App-name mismatch unresolved**: display name "Trubbo", internal Hangs, #92 rename still `[~]`; ASC record name must match the marketed name.

## M — Medium (hardening; not gating)

- M1. Session-scoped mutating endpoints (delete/extend/participants, quiz input/rate/flag) rely solely on possession of a 48-bit session id, no auth `Depends` (`sessions.py:149-207`, `quiz.py` several). Session creation is bearer-authed; residual risk is guessable-id abuse.
- M2. Rate limiting is in-memory per instance (`rate_limit.py:18,26`), not Redis; several endpoints unlimited (session delete/extend, `/rate`, TTS feedback-audio).
- M3. `quiz-pack-api /health` is static — no DB/Redis probe (`main.py:152-155`); quiz-agent's real health check lives at `/api/v1/health` (root `/` 200, `/health` 404 — monitoring should target the right path).
- M4. `GET /api/v1/admin/health` (corpus health) is unauthenticated (`main.py:404-411`) — info disclosure only.
- M5. Stale, inconsistent `.storekit` files (retired `com.carquiz.unlimited` nonconsumable in `Products.storekit`).
- M6. `TRANSLATION_MODEL` (claude-opus-5) silently falls back to English unless `LLM_GATEWAY=openrouter` (`translator.py:56-60`) — prod has `LLM_GATEWAY` set; keep in mind on any direct-mode rollback (known #53 degradation).

## Solid (verified, no action)

- Release path is correct: `release` lane → `Hangs-Prod` / `Release-Prod` → `https://quiz-agent-api.fly.dev`; default config is Release-Prod.
- Both prod services up (live-checked); Sentry wired in both; secrets hygiene clean (no tracked real .env, no hardcoded keys); `ITSAppUsesNonExemptEncryption=false` set.
- Monetization plumbing: RC webhook HMAC-verified + fail-closed env split (`RC_ALLOWED_ENVIRONMENT`), StoreKit JWS offline verification chained to bundled Apple root, entitlement grant/revoke covers full RC event set, 429 quota contract clean.
- 1024×1024 icon (no alpha); Slovak localization complete (483/484, remainder junk key); paywall has price/restore/auto-renew disclosure; Backend CI green (iOS CI has a known-flaky red on latest run).

## Path to submission

**Founder-only gates:** ASC listing + metadata + screenshots + privacy labels + age rating + review notes/demo (#50, #61); ASC IAP/product + banking/tax verification; approve privacy-policy & terms text + hosting; on-device sandbox purchase (#93/#96/#101); #99 Phase 4 blind rating (unparks generation → corpus growth); on-device checklists (#96, #109, #120 car legs, #130 Slovak wording).

**Agent-executable now:** draft privacy policy + terms + host a page, add paywall/settings links (B1); anonymous-user delete-data flow (B5); strip transcript logging (H1); AI-disclosure notice (H2); unify purpose strings/version refs/Info.plist mechanism (H3, H4); clean `.storekit` (M5); re-point or retire beta staging track (H5); `deliver` lane + metadata skeleton (part of B2); M1–M4 hardening.

**Sequencing note:** B3 (content) is the long pole — it chains #99 founder rating → quality flags → generation run → review/approve cycle. Everything else is parallelizable agent work + a founder ASC session.
