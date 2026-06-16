# Issue #58 — Authentication: research + design + plan

**Triage:** enhancement · needs-info (research issue — deliverable is a plan, not code)

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

- [ ] Research doc exists with an **options matrix** (identity model, sign-in methods, backend
      provider) and a clear **recommendation** with stated tradeoffs.
- [ ] A **phased implementation plan** (e.g. Phase 1 anonymous identity + server-side limits;
      Phase 2 Sign in with Apple; Phase 3 cross-device/purchase binding) with each phase sized
      and its dependencies on #50 (IAP) and #49 (cost/limits) noted.
- [ ] Open questions for the founder are listed explicitly.
- [ ] Founder picks an approach → implementation issues (#59+) are spun off from the plan.

## Founder input needed

- Approve the recommended approach after the research lands (the gate before any implementation).
- Confirm the launch stance: is anonymous-first acceptable, or must accounts exist at launch?
- Confirm whether a managed auth provider is acceptable, or self-hosted JWT is required for
  cost/residency reasons.

## Cross-refs

- #50 (ASC listing + IAP) — purchases must bind to whatever identity this issue chooses.
- #49 (daily free-limit cost research) — limits are enforced against the identity from #58.
- #48 (pre-release review) — Stage 2 security review will assess the chosen auth design.
