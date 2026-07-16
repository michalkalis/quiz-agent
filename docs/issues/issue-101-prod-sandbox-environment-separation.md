# #101 — Prod vs sandbox environment separation (monetization trust)

**Triage:** infra · needs-design → then agent
**Status:** Planned 2026-07-16 from the pre-MVP review (cross-stack seam finding, the single most severe item). **Founder decided 2026-07-16: Option A — separate environments** (2 now: prod + non-prod/staging; a 3rd likely later), which implies a **separate database** for the non-prod environment. Needs a short design pass before implementation because the RevenueCat + Fly + iOS-scheme topology must be grounded, not guessed.

## 1. Why

The backend RC ingest does **not** distinguish a sandbox purchase from a production one. During the imminent TestFlight, testers buy in the StoreKit **sandbox** (no real charge), RevenueCat forwards those events, and the backend writes **real production entitlement / credit rows** that the prod gate honors.

Consequences: (a) the €4.99 paywall is effectively **off** during TestFlight — every tester silently gets unlimited; (b) prod entitlement data is **polluted** with test rows; (c) you **cannot use TestFlight to validate the real money path** — which is exactly why the earlier on-device sandbox test (2026-07-12, `#93`/`#96 P1`) was ambiguous.

## 2. Findings (confirmed, file:line)

- **No environment gate in the RC ingest:** `apps/quiz-agent/app/usage/rc_service.py:352` `handle_webhook_event` dispatches on `event["type"]` only; `app/usage/rc_service.py:459` `_reconcile_subscription_state` (the REST sync path) folds `subscriptions` without reading `environment`/`is_sandbox`; `app/usage/entitlement.py:37-57` `account_is_entitled` reads only the `subscription` table. Nothing rejects a `SANDBOX` event.
- **Contrast — the pattern already exists on the pack side:** `apps/quiz-pack-api/app/api/deps.py:41` carries `storekit_environment`; the subscription path in quiz-agent never adopted it.
- **iOS uses one RC key for all environments:** `apps/ios-app/Hangs/Hangs/Services/PurchaseService.swift:98-102` `configure(withAPIKey: Config.revenueCatPublicSDKKey)` — no per-environment split, so the client itself can't be the gate.

## 3. Design pass (do this first — `/prepare-issue` or a research workflow)

Ground the topology in how RevenueCat + Fly actually behave, then lock decisions. Open questions to resolve:

1. **RC webhook routing.** One RC project emits both sandbox and production events to a single webhook URL, tagged with `environment`. Decide: (a) one RC project + prod backend drops non-`PRODUCTION` events + staging backend accepts only `SANDBOX` (needs two webhook URLs → likely **two RC projects**, or a router), vs (b) a single backend that filters and writes to the correct DB by environment. Recommend the cleanest that keeps prod data pure.
2. **Backend/infra topology.** Separate Fly app for staging vs same app + `APP_ENV` var; **separate Postgres DB** for staging (founder-confirmed) — new Fly Postgres vs a second database on the existing cluster. Ground against the memory note *"never Fly Managed Postgres"* and the Hetzner-preferred direction.
3. **iOS build targeting.** A dev/TestFlight scheme points at the staging backend URL + staging RC key; the release scheme stays prod. Reconcile with the existing `Hangs-Local`/`Hangs-Prod` schemes.
4. **Migration/secrets parity** so staging is a faithful mirror (alembic head, RC secret, `APP_ATTEST_REQUIRED`, `LEGACY_USER_ID_GRACE`).
5. **Env count:** 2 now (prod + staging), design so a 3rd (e.g. dev) slots in later without rework.

## 4. Implementation (after design lock)

- Gate every RC ingest site (`handle_webhook_event`, the REST sync reconcile, and the read gate) on the chosen environment rule — prod honors only `PRODUCTION`.
- Stand up the staging environment (Fly app/config + separate Postgres DB + secrets + RC config per the design).
- Point the TestFlight/dev iOS build at staging (URL + RC key).
- Backfill/quarantine any existing sandbox rows already written to prod (audit `subscription` + `credit_ledger`).

## 5. Acceptance

- A `SANDBOX` RC event (webhook and REST-sync) does **not** grant entitlement or credits on the prod backend — covered by a test that feeds a sandbox-tagged event and asserts no prod write.
- The staging backend + DB accept sandbox purchases and gate correctly, so the founder can validate the real purchase→entitlement flow end-to-end from a TestFlight build without touching prod data.
- Prod `subscription`/`credit_ledger` audited clean of sandbox rows.

## 6. Notes

Interim mitigation if staging slips: prod backend simply drops non-`PRODUCTION` events (closes pollution + the free-unlimited bypass immediately) — but then purchases can't be tested until staging exists. Founder chose full separation, so treat the drop as a stopgap only. Ties to `project_93_subscription_backend_done`, `project_96_ios_mvp_completion`, `project_hosting_platform_decision`.
