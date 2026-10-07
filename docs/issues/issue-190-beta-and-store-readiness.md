# #190 — External TestFlight beta + App Store listing readiness

**Triage:** in-progress · **Founder ask (2026-10-07):** everything ready for external beta via TestFlight / App Store Connect: all metadata, languages (en/sk/cs), screenshots, everything else needed.

## Live state (ASC readiness audit 2026-10-07, `asc-audit` workflow, script `asc_readiness_audit`)

- App record Trubbo, primary locale **en-GB**; only en-GB name exists. No subtitle/description/keywords, no category, no screenshots, no review contact, no age rating answers. Version 1.0 in Prepare for Submission, no build attached.
- TestFlight: no Test Information (beta description, feedback email) in any locale, no beta review contact. Groups: internal `family+friends`, external `Alpha` (public link off). Builds 62–66 valid, export compliance set (`ITSAppUsesNonExemptEncryption=NO`), no What to Test.
- Subscriptions: monthly + annual READY_TO_SUBMIT, en-GB + sk only (no cs). Annual stays unsubmitted (founder 2026-10-07; product decision PR #171 = no annual).
- Consumables `pack_30`, `questions100`: MISSING_METADATA (no localizations, no review screenshot).
- Repo fastlane metadata: en-US + sk drafts (2026-07), no cs, no en-GB; description says "Slovak and English" and pitches driving only.

## Founder decisions 2026-10-07

- iPhone only for launch (PR #237); iPad later (TODO).
- External testers via public link with a tester limit.
- Screenshots: designed frames with a caption, marketing-minded, proposals first; founder sees every language copy before upload.
- Annual subscription: leave unsubmitted.

## Tracks

- **A — iPhone-only** (PR #237).
- **B — Copy in en/sk/cs** for review: App Store listing, TestFlight Test Information, What to Test, IAP/subscription names and descriptions, review notes. Rules: `docs/design/copy-style.md`, no filler copy, natural phrasing in every language.
- **C — Screenshots:** storyline + 2–3 visual variants → founder picks → capture in en/sk/cs on 6.9" iPhone (1320×2868) → compose.
- **D — Upload** after approval: metadata (fastlane deliver / ASC API), screenshots, TF Test Information + review contact, IAP localizations + review screenshots, age rating, public link group, What to Test wired into the release workflow.
- **E — Founder-only ASC steps:** DSA trader status, App Privacy labels publish, Paid Apps Agreement check, beta review submission go.

## Open

- Review contact phone number + feedback email (founder).
- Developer/seller identity for DSA (individual vs company).
