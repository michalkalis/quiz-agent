# Issue 50: App Store Connect listing + ASC API setup (markets SK / CZ / EN)

**Triage:** enhancement · ready-for-human
**Status:** Proposed — needs founder action (Apple account). From launch decisions #5 + #7 (`docs/product/launch-decisions-2026-06-08.md`).
**Created:** 2026-06-09
**Related:** `docs/product/launch-decisions-2026-06-08.md` (#5, #7, #8), `.claude/skills/testflight`, `project_target_users` memory

## TL;DR

The app has no App Store Connect (ASC) listing yet. To ship, we need the app record created,
metadata filled for **SK + CZ + EN** markets, **pack purchasing** (in-app purchases) configured —
and, where possible, the **App Store Connect API** set up so an agent can automate listing/metadata
in future instead of clicking the web UI. Launch model is **pack purchasing only** (no subscription,
no paywall yet — decision #7).

## Why this matters here

This is the gating piece between "prod content is live" (#30 done) and "users can install from the
App Store." It's the one launch blocker that **requires the founder's Apple Developer account** —
an agent can't create the app record or accept agreements. TestFlight already works
(`.claude/skills/testflight`, fastlane + match), so the build pipeline exists; what's missing is the
public listing + IAP products + the API credentials to automate metadata going forward.

## What needs doing — founder vs agent split

### `[HUMAN]` — founder, in App Store Connect (needs Apple ID + Developer Program)
1. Confirm the Apple Developer Program membership is active and agreements accepted.
2. Create the **app record** (bundle id matching the iOS app, primary language, app name "Hangs").
3. Set **availability** to SK + CZ + EN markets (English = rest-of-world).
4. Configure **In-App Purchases** for pack purchasing (non-consumable per pack, per #36/#33 model).
   Set tier prices (informed by #49 once available).
5. Generate an **App Store Connect API key** (Users and Access → Integrations → API keys):
   download the `.p8`, note the Key ID + Issuer ID. Store per `feedback_secrets_management`
   (`.env` / fastlane, gitignored — never in `~/.zshrc`).

### `[AGENT]` — once the API key + app record exist
6. Wire the ASC API key into fastlane (`app_store_connect_api_key`) so metadata/screenshots can be
   pushed programmatically (`feedback_api_first_tools` — prefer the API over web UI).
7. Draft store metadata: description, keywords, subtitle, privacy labels (data collection: what the
   app actually collects — verify against the code, don't over-declare), support URL — in SK/CZ/EN.
8. Prepare/screenshot the required device sizes (reuse the simulator screenshot tooling).

## Scope guards

- **Pack purchasing only** — do NOT set up subscriptions or the paywall here (decision #4/#7).
- Don't invent privacy-label declarations — derive from actual data flows in the codebase.
- Prices wait on #49's cost model; the listing can be created with placeholder tiers and updated.
- Secrets handling: `.p8` and IDs in gitignored config only.

## Success criteria

- App record exists in ASC, available in SK/CZ/EN, with pack-purchase IAP products configured.
- ASC API key generated, stored securely, and wired into fastlane so future metadata pushes are scriptable.
- Store metadata drafted in all three languages with verified privacy labels.

## Memory references

- `feedback_secrets_management` — `.p8` + key IDs in `.env`/fastlane, gitignored
- `feedback_api_first_tools` — use the ASC API, not manual web clicks, wherever possible
- `feedback_company_accounts` — register API key under the company Apple account if applicable
- `feedback_plain_language_explanations` — walk the founder through the `[HUMAN]` steps in plain language
- `project_target_users` — SK-first audience, families post-MVP
