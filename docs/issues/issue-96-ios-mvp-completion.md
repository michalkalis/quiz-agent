# Issue #96 — iOS MVP completion: founder-feedback batch + design parity + TestFlight

**Triage:** umbrella (bug+enhancement) · ready-for-agent (8 sessions S0–S7, sequential)
**Status:** Planned 2026-07-12 from founder device-test feedback on the 2026-07-11 TestFlight build + an MVP-completion review request. Scope locked with founder in-session (Q&A below). Execution NOT started — run each session in a fresh context.

**How to run:** paste into a fresh session: *"Vykonaj session Sx z docs/issues/issue-96-ios-mvp-completion.md"*. Sessions are sequential (one checkout — never parallel, see memory project_concurrent_sessions_same_checkout). Founder asked for /workflows fan-out inside analysis-heavy sessions (S0, S1).

## Goal

Bring the iOS app to the founder's MVP bar and ship a TestFlight build as **Trubbo**: fix the two device-blocking bugs (IAP purchase flow, voice commands), apply founder UI corrections, close app⇄Pencil parity gaps (both directions), build the missing #95 client half, land #88/#89 backend fixes, finish #92 (S2 design/docs + S3 ship).

## Founder feedback (2026-07-12, from the 2026-07-11 TestFlight build on his iPhone, iOS 26)

1. **IAP broken (P0):** subscribe "viacmenej nefunguje" — Apple password sheet completes, purchase never gets marked as paid, paywall re-prompts for password/subscribe again. "neni tam odozva alebo neni spravne spracovany nakup." Consumable pack also appears not purchased. Ask: "sprav review, najdi chyby a oprav spravne."
2. **Voice commands still don't work** for him — after both the 2026-07-11 asset-install fix and the by-design-windows diagnosis (memory `project-voice-commands-diagnosis`).
3. **Hide "Image questions"** toggle on Home — "tie este nebudeme zobrazovat".
4. **Big display texts must not wrap to 2 lines** — named: "GO UNLIMITED", "NAILED IT", "MISSED IT"; audit for others ("pripadne dalsie"). Wrapped hero texts waste space.
5. **Quiz screen bottom buttons** sit needlessly high / side padding too large — reduce.
6. **Design parity is bidirectional:** Pencil is behind the app in places (named example: quiz-screen bottom buttons in Pencil ≠ the shipped state); the app is missing some parts designed in Pencil. ⚠️ Verbatim guard: "daj si velky pozor, aby si zbytocne nezavadzal nove layouty pripadne upravy ktore nie su ziadane" — NO unrequested layouts or changes.
7. "inak zvysok funguje" — everything else works.

## Locked scope decisions (founder Q&A, 2026-07-12)

| # | Decision |
|---|---|
| 1 | Parity depth = **functional differences + copy only**; no pixel-perfection sweep |
| 2 | #95 custom packs: "should be done — check; build if not" → **verified NOT built (client half), build it** (S5) |
| 3 | Auth **#88 + #89 in scope** (backend); #91 stays out |
| 4 | Post-answer context playback (#72 follow-up) **OUT** of this round |
| 5 | Ship as **Trubbo** — #92 S2 (.pen + docs) + S3 (TestFlight) in scope; **ASC name already saved by founder** (availability gate cleared 2026-07-12) |
| 6 | Pencil copy 100/mo → 30/mo (the existing `[~]` TODO line) folds into S4 |

## Recon snapshot (verified in the 2026-07-12 planning session)

- **#95 status:** Session 1 (backend reachability, admin order path, account linkage, cost capture) DONE + **deployed to prod 2026-07-12**. Sessions 2 (iOS order flow) + 3 (play the pack) NOT built — zero references to `/v1/orders` in `apps/ios-app`. Plan: [issue-95-custom-pack-client.md](issue-95-custom-pack-client.md).
- **App inventory (Explore agent):** all major screens exist and are backend-wired (Home, Question MCQ+voice, AnswerConfirm, Result, Completion, Settings incl. account, Paywall + offline variant, Onboarding 4-page, Minimized widget, Error). No custom-pack UI. No stats screen (by design, #84). Dead legacy views exist (`LanguagePickerView`, `AudioRoutePickerWrapper`, orphaned pre-redesign `Views/Components/*`) — cleanup NOT in scope (guard #6). Known theme drift: `AudioDevicePickerView` + parts of `LiveTranscriptView` still on old `Theme` (purple) — visual-only, report in S0, only fix if founder approves the A-list row.
- **CmdListenBar** (voice-command listening indicator) exists ONLY in Pencil (component `s49sd`, #77 task 77.12) — never implemented in iOS. Founder complaint #2 is partly discoverability: no visible cue when the command listener is armed.
- **Pencil file:** 37 top-level frames. Key IDs: Home `rJ7dB` · Settings `Jjcs5` · Quiz-Complete `NPlqf` · Result-Correct `X4o4l` · Result-Incorrect `31AzE` · Q-MultiChoice `b8zObz` · Q-TrueFalse `WCaT6` · Q-Listen `f9csl` · Q-Capture `uGhZg` · Q-TypedAnswer `P4YdP` · Q-Error `w8s5Mj` · Answer-Confirm `ddusv` · Onboarding `gkeCn`/`hTdkE`/`haWJM`/`COHnz` · Paywall `u2ySy` / offline `PouwN` / subscription `z8TS6` · Auth `YRDc8`/`aXW2d`/`ZZ98A`/`I1LcyP`/`WAIEy` · Settings-SignedOut `taml6` / SignedIn `JB9Oi` / DeleteConfirm `PmJ3A` · Minimized `AAEkz` · components `EZhqr` AnswerOption, `s49sd` CmdListenBar.
- **.pen git state:** modified on disk, uncommitted; some editor saves were founder-gated (⌘S pending from #94 + bug batch). S4 must reconcile FIRST: founder ⌘S → commit baseline → then edit.
- **IAP context:** #93 backend live in prod (webhook smoke-tested 2026-07-11); PaywallView synced to z8TS6 (#94: plan picker, pack card, dynamic CTA); RevenueCat adopted; ASC products READY_TO_SUBMIT. The founder's sandbox purchase = the one #93 leg that was never verified — and it failed (feedback #1).

## Sessions

### S0 — Parity audit (read-only; workflow fan-out per screen-group)
Compare each Pencil frame ⇄ SwiftUI implementation. Classify every gap:
- **A app-gap** — designed, missing in app → candidate to implement
- **B pen-stale** — app has the shipped founder-approved state, pen is behind → update pen
- **C copy** — texts/values differ
Pre-seeded rows — B: quiz bottom controls (audio strip #83/#85), replay-link removal (2026-07-11 bug batch replaced it with tap-to-replay); C: 100/mo → 30/mo (Home free-plan card + paywall frames). A: CmdListenBar (owned by S2). Exclude: #95 UI (S5); pure visual drift → report-only per decision 1.
Output: gap table appended to this file, each row = frame id + file:line evidence + class.
**Founder gate: approve the A-list before S3 implements it** (guard #6 — no unrequested changes).
Acceptance: all screen frames covered; table in this file; founder ping with the A-list.

### S1 — IAP purchase flow: review + root-cause fix (P0; payment path ⇒ #93 maker≠checker rail)
Symptoms: see feedback #1. Diagnose first (workflow, multi-lens): (a) iOS purchase completion path — StoreManager/PurchaseService → RevenueCat purchase call → entitlement refresh → AppState premium flag; (b) RevenueCat dashboard events + TestFlight-sandbox specifics for the founder's 2026-07-12 attempts; (c) backend webhook → server entitlement → `/usage` response; (d) UI observation — PaywallView dismiss/refresh on entitlement change. Pull Sentry via /check-crashes.
Fix the root cause (no patches — feedback_proper_solutions), add regression tests per #93 conventions, run an adversarial review leg on every payment-path change, deploy backend if touched (auto-deploy OK; migrations/secrets need founder).
Acceptance: sim StoreKit-config e2e green for BOTH products (subscribe → entitlement active → paywall dismisses → Home shows Unlimited; pack → credits added); regression tests in; founder re-tests sandbox on the S7 build.

### S2 — Voice commands: make them observable, then fix what's real
Respect memory `project-voice-commands-diagnosis` — EN-only vocab + narrow arming windows are BY DESIGN; do NOT re-diagnose from scratch. Escalation path (already agreed in that memory):
1. Implement **CmdListenBar** from pen `s49sd` (77.12) in both question modes — visible cue exactly when the listener is armed, showing the valid word(s).
2. Promote recognizer health diagnostics out of `#if DEBUG` into a release-visible Settings row (asset state, last recognized command); mirror recognizer/asset failures to Sentry.
3. Verify the 2026-07-11 launch-time AssetInventory install actually completed on the founder's device (Sentry breadcrumb/event).
4. Only if evidence shows a real defect → root-cause fix.
Acceptance: indicator shows in sim during armed windows; diagnostics row present in TestFlight builds; Sentry events wired; S7 checklist gets a 5-line usage cheat-sheet (which words, in which moments).

### S3 — Founder UI corrections + approved A-list (iOS)
- Hide Home "Image questions" toggle (keep wiring; UI hidden until image content ships).
- Single-line hero texts: `lineLimit(1)` + `minimumScaleFactor` on the Anton display call-sites — "GO UNLIMITED" (paywall), "NAILED IT"/"MISSED IT" (result) + audit all `hangsDisplay*` usages; no copy rewrites.
- Quiz bottom controls: reduce horizontal padding / vertical footprint; before/after screenshots for founder.
- Implement the founder-approved A-list from S0. Nothing beyond it (guard #6).
Acceptance: targeted suites green + on-sim visual pass light+dark on touched screens; screenshots attached.

### S4 — Pencil sync + #92 S2 (design side)
Pre-step `[HUMAN]`: founder ⌘S current editor state → commit .pen baseline.
In the editor (pencil MCP): apply B-list (pen ← shipped app state, incl. quiz bottom audio strip), C-list copy (30/mo), #92 S2 — wordmark/brand text → trubbo across frames + living docs (CONTEXT.md, README, PRD titles).
End `[HUMAN]`: founder ⌘S again → commit .pen + docs.
Acceptance: pen matches shipped app for all B/C rows; screenshot-diff shows no other frames touched.

### S5 — #95 client half (iOS order flow + play the pack)
Execute issue-95 **Sessions 2 + 3 exactly as planned there** (entry point OUTSIDE PaywallView; OrderPackView 10–1000-char prompt + language picker; OrderProgressView polling 1 Hz; quiz-agent session-start `pack_id` filter — deterministic, no hot-path LLM; My-packs list from `GET /v1/orders`; delivered pack playable; custom packs bypass the 30/mo quota).
Open detail to resolve in-session (with founder if needed): how the founder-only admin order path authenticates from the app — the admin key must NOT ship in the binary (e.g. Settings-entered key or DEBUG-gated entry).
Acceptance: per issue-95 — order → progress → delivered → play the full pack e2e against prod, founder-only visibility.

### S6 — Auth fixes #88 + #89 (backend)
Per [issue-88](issue-88-refresh-lost-response-signout.md) + [issue-89](issue-89-grace-null-subject-quota-bypass.md). Autonomous fix + deploy per standing delegation (memory feedback-auth-security-autonomy). Backend suite green ×2, /deploy with smoke checks.
Acceptance: #88 — dropped-response replay of the just-used refresh token re-issues the unused successor, does NOT revoke the family (test-covered); #89 — null-subject sessions rejected or counted, quota gates un-skippable; both deployed.

### S7 — Verify + TestFlight as Trubbo (#92 S3)
Full HangsTests + both backend suites; RS smoke; /verify-api if models changed; then /testflight.
Post-build founder checklist (on-device): sandbox sub + pack purchase (S1) · voice commands with indicator + cheat-sheet (S2) · image toggle hidden, single-line texts, quiz paddings (S3) · custom pack order→play e2e (S5) · re-checks from the 2026-07-11 batch (silent switch, background mic).

## References

- [issue-95-custom-pack-client.md](issue-95-custom-pack-client.md) · [issue-92-rename-trubbo.md](issue-92-rename-trubbo.md) · [issue-93-subscription-iap-packs.md](issue-93-subscription-iap-packs.md) (payment rails) · [issue-88](issue-88-refresh-lost-response-signout.md) / [issue-89](issue-89-grace-null-subject-quota-bypass.md)
- Memory: project-voice-commands-diagnosis · project_93_subscription_backend_done · project_95_custom_pack_decisions · project_concurrent_sessions_same_checkout
- [handoff-2026-07-12-1815.md](../handoffs/handoff-2026-07-12-1815.md) — repo state before this plan
