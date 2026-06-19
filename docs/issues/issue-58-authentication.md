# Issue #58 — Authentication: research + design + plan

**Triage:** enhancement · researched — **plan delivered, impl issues spun off** (#60/#61/#62); only Pencil auth screens (§9) remain on this issue

> **✅ Research delivered 2026-06-16:** [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md)
> — options matrix + recommendation + phased plan (impl issues **#60/#61/#62** — #59 is taken) + 7 open questions (founder-answered 2026-06-17, doc §8b).
> Produced via a multi-agent workflow (5 research dimensions, each adversarially fact-checked).
> **Recommendation:** anonymous-first self-issued JWT on the existing FastAPI/Fly.io+Postgres stack
> (Phase 1, fixes the freemium bypass) → Sign in with Apple as an upgrade (Phase 2) → cross-device +
> IAP binding (Phase 3). No managed auth provider. Folds in founder constraints: global (not EU-only),
> usable without login, Pencil screens.
>
> **Research corrected two #58 assumptions:** (1) the `quiz-pack-api` JWS verifier *does* exist
> (`app/storekit/verifier.py`) but is StoreKit-IAP-only — it cannot be reused for general auth;
> (2) `POST /api/v1/usage/{userId}/premium` is currently **unauthenticated** — anyone can self-grant premium.

**Founder priority 2026-06-16:** This is the founder's #1 next initiative. **Scope of THIS
issue is research + analysis + a phased implementation plan only — no auth code is written
here.** Implementation lands in follow-up issues once the founder picks an approach.

## Why

The app currently has **no user authentication**. Before/at launch this becomes load-bearing:

- **Freemium enforcement** — daily free-question limits are easy to reset if they are only
  device-local; server-side enforcement needs a stable identity.
- **IAP entitlements (#50)** — "unlimited" / pack purchases must bind to an account so they
  survive reinstall and (later) cross-device.
- **Multiplayer (post-MVP product vision)** — requires real identities.
- **Abuse / cost control (#49)** — per-account rate limits protect the per-question LLM spend.
- **GDPR** — EU users (SK/CZ launch) need a clear data-subject identity for export/delete.

## What to research & decide (the deliverable)

Produce a design doc (`docs/product/auth-research-<date>.md` or a PRD) that covers:

1. **Identity model** — anonymous-first vs. forced sign-in. The product is voice-first while
   driving; forcing a login wall at first launch is hostile. Evaluate: anonymous device
   identity upgraded to a real account later, with freemium limits enforced server-side
   against the anonymous id from day one.
2. **Sign-in methods** — Sign in with Apple (near-mandatory for an iOS-first app that offers
   any social login; best UX on-device), passwordless email (magic link), and what App Store
   review requires. Recommend a minimal set.
3. **Backend approach** — own JWT issuance/verification in FastAPI vs. a managed provider
   (Firebase Auth / Supabase Auth / Auth0 / Clerk). Weigh: EU data residency (we are already
   EU-aligned — Sentry EU), cost at our scale, lock-in, and how it composes with the existing
   Fly.io deployment and the `quiz-pack-api` JWS verification that already exists.
4. **iOS integration** — `ASAuthorizationAppleIDProvider`, token storage in Keychain, refresh
   handling, and how it threads through the existing `QuizViewModel` / networking layer.
5. **Migration** — how existing anonymous/device users (and any existing data) map onto
   accounts without losing freemium state or purchases.
6. **GDPR/privacy** — data stored, retention, export/delete path, and alignment with the #50
   App Store privacy labels.

## Deliverable / Acceptance

- [x] Research doc exists with an **options matrix** (identity model, sign-in methods, backend
      provider) and a clear **recommendation** with stated tradeoffs.
- [x] A **phased implementation plan** (Phase 1 anonymous identity + server-side limits;
      Phase 2 Sign in with Apple; Phase 3 cross-device/purchase binding) with each phase sized
      and its dependencies on #50 (IAP) and #49 (cost/limits) noted.
- [x] Open questions for the founder are listed explicitly (7 gates — see research doc §8).
- [x] Founder picked the approach (doc §8b, 2026-06-17) → implementation issues **#60/#61/#62** spun off 2026-06-18 (`issue-60/61/62-*.md` + INDEX rows + TODO queue).
- [x] Pencil auth-flow screens drawn in `design/quiz-agent.pen` per §9 (2026-06-18): `Auth/Anonymous-Start`, `Auth/Account-Prompt` (Sign in with Apple sheet), `Auth/Account-Manage` (premium status + restore + in-app Delete + Export + Sign out), `Auth/Upgrade-Confirm`. Feeds Phase 2 (#61).

## Founder input needed

- Approve the recommended approach after the research lands (the gate before any implementation).
- Confirm the launch stance: is anonymous-first acceptable, or must accounts exist at launch?
- Confirm whether a managed auth provider is acceptable, or self-hosted JWT is required for
  cost/residency reasons.

## Cross-refs

- #50 (ASC listing + IAP) — purchases must bind to whatever identity this issue chooses.
- #49 (daily free-limit cost research) — limits are enforced against the identity from #58.
- #48 (pre-release review) — Stage 2 security review will assess the chosen auth design.

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-48-pre-release-review-gauntlet|#48 Pre-release review gauntlet]] · [[issue-49-daily-limit-cost-research|#49 Daily free-limit cost research]] · [[issue-50-app-store-connect-setup|#50 App Store Connect listing + ASC API setup]] · [[issue-59-quiz-flow-bug-cluster|#59 Quiz-flow bug cluster]] · [[issue-60-auth-phase1-anonymous-identity|#60 Auth Phase 1]] · [[issue-61-auth-phase2-sign-in-with-apple|#61 Auth Phase 2]] · [[issue-62-auth-phase3-cross-device-purchase-binding|#62 Auth Phase 3]]
<!-- obsidian-links:end -->
