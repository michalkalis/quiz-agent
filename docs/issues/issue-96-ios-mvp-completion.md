# Issue #96 — iOS MVP completion: founder-feedback batch + design parity + TestFlight

**Triage:** umbrella (bug+enhancement) · ready-for-agent (ONE autonomous session, phases P1–P6)
**Status:** Planned 2026-07-12; **S0 parity audit executed 2026-07-12/13 with founder in-session** (gap table below, all founder gates resolved). Restructured 2026-07-13 from 8 sessions to one autonomous session at founder request. Execution of P1–P6 NOT started.

**How to run:** paste into a fresh session: *"Vykonaj autonómnu session z docs/issues/issue-96-ios-mvp-completion.md (fázy P1–P6)"*. One checkout, never parallel agents (memory project_concurrent_sessions_same_checkout). Use /workflows fan-out for the analysis-heavy IAP diagnosis (P1). Commit + push at every phase boundary (durable checkpoints — a fresh context must be able to resume from the TODO/issue state). The ONLY human touchpoint mid-run is the ⌘S save in P4; if the founder is unavailable, finish the pen edits, ping, and continue with P5 — the .pen commit can trail.

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
| 2 | ~~#95 client half in scope (S5)~~ **REVERSED 2026-07-13:** founder wants custom packs as a proper end-user feature (not admin-key-gated founder tooling) → **#95 client = post-MVP, OUT of this round**, to be re-planned for regular users (payments via IAP), developed on a separate branch |
| 3 | Auth **#88 + #89 in scope** (backend); #91 stays out |
| 4 | Post-answer context playback (#72 follow-up) **OUT** of this round |
| 5 | Ship as **Trubbo** — #92 S2 (.pen + docs) + S3 (TestFlight) in scope; **ASC name already saved by founder** (availability gate cleared 2026-07-12) |
| 6 | Pencil copy 100/mo → 30/mo — audit found it ALREADY resolved in pen; nothing to do |
| 7 | **A-list verdicts (2026-07-13):** APPROVED — Settings "Voice commands" master toggle (P2) + Onboarding-2 command-education card content adopted app-side (P2). REJECTED (→ update pen to app state) — Answer-Confirm question-echo/counter/mute, "Try this question again" retry link |
| 8 | **Superseded pen frames → rename `ARCHIVED_…`, keep in file** (old paywall `u2ySy`, Auth Welcome `YRDc8`, Keep-Going `aXW2d`, Account `ZZ98A`, All-Set `I1LcyP`; wake-word row removed from Settings frame) |
| 9 | Pre-P4 .pen baseline: founder ⌘S done, committed as d507d3e |

## Recon snapshot (verified in the 2026-07-12 planning session)

- **#95 status:** Session 1 (backend reachability, admin order path, account linkage, cost capture) DONE + **deployed to prod 2026-07-12**. Sessions 2 (iOS order flow) + 3 (play the pack) NOT built — zero references to `/v1/orders` in `apps/ios-app`. Plan: [issue-95-custom-pack-client.md](issue-95-custom-pack-client.md).
- **App inventory (Explore agent):** all major screens exist and are backend-wired (Home, Question MCQ+voice, AnswerConfirm, Result, Completion, Settings incl. account, Paywall + offline variant, Onboarding 4-page, Minimized widget, Error). No custom-pack UI. No stats screen (by design, #84). Dead legacy views exist (`LanguagePickerView`, `AudioRoutePickerWrapper`, orphaned pre-redesign `Views/Components/*`) — cleanup NOT in scope (guard #6). Known theme drift: `AudioDevicePickerView` + parts of `LiveTranscriptView` still on old `Theme` (purple) — visual-only, report in S0, only fix if founder approves the A-list row.
- **CmdListenBar** (voice-command listening indicator) exists ONLY in Pencil (component `s49sd`, #77 task 77.12) — never implemented in iOS. Founder complaint #2 is partly discoverability: no visible cue when the command listener is armed.
- **Pencil file:** 37 top-level frames. Key IDs: Home `rJ7dB` · Settings `Jjcs5` · Quiz-Complete `NPlqf` · Result-Correct `X4o4l` · Result-Incorrect `31AzE` · Q-MultiChoice `b8zObz` · Q-TrueFalse `WCaT6` · Q-Listen `f9csl` · Q-Capture `uGhZg` · Q-TypedAnswer `P4YdP` · Q-Error `w8s5Mj` · Answer-Confirm `ddusv` · Onboarding `gkeCn`/`hTdkE`/`haWJM`/`COHnz` · Paywall `u2ySy` / offline `PouwN` / subscription `z8TS6` · Auth `YRDc8`/`aXW2d`/`ZZ98A`/`I1LcyP`/`WAIEy` · Settings-SignedOut `taml6` / SignedIn `JB9Oi` / DeleteConfirm `PmJ3A` · Minimized `AAEkz` · components `EZhqr` AnswerOption, `s49sd` CmdListenBar.
- **.pen git state:** modified on disk, uncommitted; some editor saves were founder-gated (⌘S pending from #94 + bug batch). S4 must reconcile FIRST: founder ⌘S → commit baseline → then edit.
- **IAP context:** #93 backend live in prod (webhook smoke-tested 2026-07-11); PaywallView synced to z8TS6 (#94: plan picker, pack card, dynamic CTA); RevenueCat adopted; ASC products READY_TO_SUBMIT. The founder's sandbox purchase = the one #93 leg that was never verified — and it failed (feedback #1).

## The autonomous session (phases P1–P6, sequential; S0 already done)

Standing rules for the whole run: commit+push at each phase boundary; update the TODO `[~]` marker per phase; a failed phase does NOT block later independent phases (P5 is independent of P1–P4) — fail loud in the final report instead. Order rationale: P4 (pen sync) runs AFTER P2/P3 so the pen captures the final app state.

### P1 — IAP purchase flow: review + root-cause fix (P0; payment path ⇒ #93 maker≠checker rail)
Symptoms: see feedback #1. Diagnose first (workflow, multi-lens): (a) iOS purchase completion path — StoreManager/PurchaseService → RevenueCat purchase call → entitlement refresh → AppState premium flag; (b) RevenueCat dashboard events + TestFlight-sandbox specifics for the founder's 2026-07-12 attempts; (c) backend webhook → server entitlement → `/usage` response; (d) UI observation — PaywallView dismiss/refresh on entitlement change. Pull Sentry via /check-crashes.
Fix the root cause (no patches — feedback_proper_solutions), add regression tests per #93 conventions, run an adversarial review leg on every payment-path change, deploy backend if touched (auto-deploy OK; migrations/secrets need founder).
Acceptance: sim StoreKit-config e2e green for BOTH products (subscribe → entitlement active → paywall dismisses → Home shows Unlimited; pack → credits added); regression tests in; founder re-tests sandbox on the P6 build.

### P2 — Voice commands: make them observable, then fix what's real
Respect memory `project-voice-commands-diagnosis` — EN-only vocab + narrow arming windows are BY DESIGN; do NOT re-diagnose from scratch. Escalation path (already agreed in that memory):
1. Implement **CmdListenBar** from pen `s49sd` (77.12) in both question modes — visible cue exactly when the listener is armed, showing the valid word(s).
2. Promote recognizer health diagnostics out of `#if DEBUG` into a release-visible Settings row (asset state, last recognized command); mirror recognizer/asset failures to Sentry.
3. Verify the 2026-07-11 launch-time AssetInventory install actually completed on the founder's device (Sentry breadcrumb/event).
4. Only if evidence shows a real defect → root-cause fix.
5. Approved A-list additions (decision 7): Settings "Voice commands" master toggle (pen `gEPhB`, wired to the existing Config default); Onboarding-2 features card adopts the pen `hTdkE` command-education content (Say "start" / five simple words / English, always / Buttons always work).
Acceptance: indicator shows in sim during armed windows; diagnostics row present in TestFlight builds; Sentry events wired; toggle + onboarding card in; P6 checklist gets a 5-line usage cheat-sheet (which words, in which moments).

### P3 — Founder UI corrections (iOS)
- Hide Home "Image questions" toggle (keep wiring; UI hidden until image content ships).
- Single-line hero texts: `lineLimit(1)` + `minimumScaleFactor` on the Anton display call-sites — "GO UNLIMITED" (paywall — NOTE: currently hardcoded two-line "GO\nUNLIMITED", PaywallView.swift:114), "NAILED IT"/"MISSED IT" (result) + audit all `hangsDisplay*` usages; no copy rewrites.
- Quiz bottom controls: reduce horizontal padding / vertical footprint; before/after screenshots for founder.
- Nothing beyond this list (guard #6 — the rest of the A-list was rejected, decision 7).
Acceptance: targeted suites green + on-sim visual pass light+dark on touched screens; screenshots saved for the final report.

### P4 — Pencil sync + #92 S2 (design side; baseline d507d3e already committed)
In the editor (pencil MCP), against the gap table below:
- **B-list:** pen ← shipped app state for all B rows (quiz audio strip, Home free-plan card, Settings rows, Answer-Confirm extras, Result auto-advance, Completion upsell, sign-in sheet states, Offline-paywall wordmark) + P2/P3 outcomes (CmdListenBar placements stay as designed; quiz bottom paddings; onboarding card only if copy changed direction).
- **Rejected-A rows** (decision 7): update pen to app state — remove Answer-Confirm question-echo/counter/mute, remove "Try this question again" link.
- **C-list:** copy rows from the table (skip pen-leads Onboarding-2 — handled app-side in P2; skip data-driven low-confidence rows).
- **Archive** (decision 8): rename `u2ySy`, `YRDc8`, `aXW2d`, `ZZ98A`, `I1LcyP` → `ARCHIVED_…`; remove wake-word row from Settings `Jjcs5`.
- **#92 S2:** wordmark/brand text → trubbo across frames + living docs (CONTEXT.md, README, PRD titles).
End `[HUMAN]` (the run's only human touchpoint): ping founder for ⌘S → commit .pen + docs. If unavailable, proceed to P5 and leave the commit flagged in the report.
Acceptance: pen matches shipped app for all B/C rows; screenshot-diff shows no other frames touched.

### P5 — Auth fixes #88 + #89 (backend)
Per [issue-88](issue-88-refresh-lost-response-signout.md) + [issue-89](issue-89-grace-null-subject-quota-bypass.md). Autonomous fix + deploy per standing delegation (memory feedback-auth-security-autonomy). Backend suite green ×2, /deploy with smoke checks.
Acceptance: #88 — dropped-response replay of the just-used refresh token re-issues the unused successor, does NOT revoke the family (test-covered); #89 — null-subject sessions rejected or counted, quota gates un-skippable; both deployed.

### P6 — Verify + TestFlight as Trubbo (#92 S3)
Full HangsTests + both backend suites; RS smoke; /verify-api if models changed; then /testflight.
Post-build founder checklist (on-device): sandbox sub + pack purchase (P1) · voice commands with indicator + cheat-sheet + Settings toggle (P2) · image toggle hidden, single-line texts, quiz paddings (P3) · re-checks from the 2026-07-11 batch (silent switch, background mic).

### Dropped from this round
- **#95 client half** (decision 2): post-MVP, re-plan as an end-user feature (IAP-priced orders, no admin key in the flow) on a separate branch; issue-95 Sessions 2+3 plan stays as raw material.

## S0 gap table (audit 2026-07-12, 5-agent workflow, all 27 screen frames covered)

Class: **A** app-gap (designed, missing in app) · **B** pen-stale (app leads, update pen) · **C** copy. `(low)` = low confidence.

### A — app-gaps (founder gate)

| Frame | Gap | Evidence |
|---|---|---|
| Home `rJ7dB` · Q-Listen `f9csl` · Answer-Confirm `ddusv` · Result `X4o4l`/`31AzE` | CmdListenBar `s49sd` instances ("LISTENING FOR COMMANDS" + valid words per screen) — nowhere in app. Owned by voice-commands phase. | HomeView.swift:50-70; QuestionView.swift:367-445; ResultView.swift:218-256 |
| Settings `Jjcs5` | "Voice commands" master toggle in voice group — app has none (only DEBUG diagnostics). | SettingsView.swift:148-194,573 (pen `gEPhB`) |
| Settings `Jjcs5` | "Wake word: hey hangs" row — feature doesn't exist anywhere in app (aspirational). | SettingsView.swift:148-194 (pen `lHJkD`/`sZjyg`) |
| Answer-Confirm `ddusv` | Pen echoes the question text + "03 / 10" counter under the heard answer; app sheet shows transcript only. | AnswerConfirmationView.swift:52-104 (pen `jNNdP`,`oZiZr`) |
| Answer-Confirm `ddusv` | Mute button in confirm audio strip — app sheet has no mute control. | AnswerConfirmationView.swift:106-134 (pen `A3Fpl`) |
| Answer-Confirm `ddusv` | (low) Pen = full screen with quiz chrome; app = medium modal sheet (shipped founder-reviewed flow). | QuestionView.swift:52-67 |
| Q-TypedAnswer `P4YdP` | (low) Pen hides Record + disables Skip while typing; app keeps action row + adds send button (2026-07-12 batch likely supersedes pen). | QuestionView.swift:410-434,523-550 |
| Result-Incorrect `31AzE` | "Try this question again" ghost link under Next — no retry control in app. | ResultView.swift:218-256 (pen `HDBrA`) |
| Auth Welcome `YRDc8` | (low) Whole guest-welcome screen only in pen; app routes onboarding → Home (likely superseded by #58 contextual sign-in). | ContentView.swift:41-69 |
| Auth All-Set `I1LcyP` | (low) Post-sign-in confirmation screen only in pen; shows streak pill removed in #84 (likely intentionally dropped). | ContextualSignInSheet.swift:219-221 |

### B — pen-stale (pen ← shipped app state; S4/pen phase)

| Frame | Gap | Evidence |
|---|---|---|
| Q-MCQ `b8zObz`/TF `WCaT6`/Typed `P4YdP` | Pre-seeded #83/#85 confirmed: app adds ANSWER timer chip, muted speaker variant, tap-question-to-replay + speaker glyph (replay link gone). | QuestionView.swift:189-244 |
| Home `rJ7dB` | Free-plan card in app is tappable paywall entry with "Upgrade >" (#93); pen card has neither. | HomeView.swift:90-96,132-140 (pen `j04Lk`) |
| Home `rJ7dB` | (low) Categories: pen inline checklist vs app native multi-select Menu + all-clear option. | HomeView.swift:252-290 (pen `UPUnq`) |
| Settings all 3 frames | App voice group adds Auto-record, Auto-confirm, Microphone picker rows — missing in pen. | SettingsView.swift:150-173 |
| Settings all 3 frames | App subscription group ("Plan" row → paywall) missing in pen (#94 ⌘S-pending). | SettingsView.swift:494-518 |
| Settings `taml6`+`JB9Oi` | Old "Audio mode: Call Mode >" picker + footnote; app (and `Jjcs5`) has Call Mode toggle + inline subtitle. | SettingsView.swift:182-193 |
| Settings `Jjcs5` | (low) Call Mode toggle sits in pen "audio feedback" group vs app "voice" group. | SettingsView.swift:182-193 |
| Answer-Confirm `ddusv` | App adds edit-transcript affordance, auto-confirm progress bar, processing state ("Transcribing…" + Cancel) — none in pen. | AnswerConfirmationView.swift:57-85,180-235 |
| Result `X4o4l`+`31AzE` | App auto-advance controls (#81): "Next in Ns" countdown bar, "Stay here", "Resume auto-advance" — none in pen. | ResultView.swift:181-213,241-252 |
| Quiz-Complete `NPlqf` | #94 quota upsell card ("Running low…" + "Go Unlimited") missing in pen (⌘S-pending?). | CompletionView.swift:132-166 |
| Minimized `AAEkz` | (low) App state rows (Recording…/Processing…/Review) + End Quiz confirm alert (#81); pen shows one state + plain link. | MinimizedQuizView.swift:72-127 |
| Paywall `u2ySy` | Whole frame = pre-#93 one-time-unlock design, superseded by `z8TS6`; no SwiftUI view implements it. | PaywallView.swift:5-10 |
| Paywall-Offline `PouwN` | Wordmark "hangs." vs app "trubbo."; rest matches exactly. | HangsChrome.swift:20 (pen `g3uPZ`) |
| Auth Keep-Going `aXW2d` | (low) Pen gates quota exhaustion on sign-in; shipped #93 shows paywall, sign-in grants nothing — contradicts approved flow. | PaywallView.swift:140 |
| Auth Account `ZZ98A` | Standalone account screen superseded: account lives in Settings (2026-06-29), Restore purchases on paywall (2026-07-11). | SettingsView.swift:323-326,487-506 |
| Auth sheet `WAIEy` | App adds failed state (error banner + "Later…" ghost) and signing-in progress state; pen has idle only. | ContextualSignInSheet.swift:111-185 |

### C — copy

| Frame | Gap | Evidence |
|---|---|---|
| Brand rows: `gkeCn` `hTdkE` `haWJM` `COHnz` `YRDc8` `ZZ98A` + subtitle `gkeCn`/`haWJM` | "hangs." / "Hangs …" → app ships "trubbo." / "Trubbo …" (folds into #92 S2 wordmark sweep). | HangsChrome.swift:20; OnboardingView.swift:51,99 |
| Onboarding-2 `hTdkE` | Features card content differs entirely; **pen likely LEADS** (post-diagnosis command education: Say "start" / five words / English-always / buttons always work) vs app's generic Auto-Record/Answer-Anytime/… | OnboardingView.swift:290-297 |
| Settings `taml6`+`JB9Oi` | "Current language" → app "Quiz language" (`Jjcs5` already updated). | SettingsView.swift:207 |
| Answer-Confirm `ddusv` | Pen "we heard" vs app "YOU SAID". | AnswerConfirmationView.swift:55 |
| Result-Correct `X4o4l` | Pen "+ 1 point" vs app "+1 points" (always plural, can be fractional). | ResultView.swift:325 |
| Result `X4o4l`+`31AzE` | (low) T/F badge letters: pen T/F vs app data-driven A/B keys. | AnswerOption.swift:93 |
| Paywall-Sub `z8TS6` | (low) Countdown pill "…IN 21 DAYS" vs app compact "12D 4H" format. | PaywallView.swift:457,487 |
| Error `Fwafe` | (low) Pen body copy not in AppErrorModel variants (plausibly sample data). | AppErrorModel.swift:125-146 |

Notes: pre-seeded 100/mo→30/mo is ALREADY resolved in pen (Home card + both paywall frames read 30) — no C row. Visual-only notes (report-only per decision 1): Settings nav chrome, listening-pill styling, result hero sizes/label case, transcript label case, confirm button icon/heights, `z8TS6` hero hardcoded two-line "GO\nUNLIMITED" in app (conflicts with founder no-wrap rule — handled by UI-corrections phase) + wordmark color.

## References

- [issue-95-custom-pack-client.md](issue-95-custom-pack-client.md) · [issue-92-rename-trubbo.md](issue-92-rename-trubbo.md) · [issue-93-subscription-iap-packs.md](issue-93-subscription-iap-packs.md) (payment rails) · [issue-88](issue-88-refresh-lost-response-signout.md) / [issue-89](issue-89-grace-null-subject-quota-bypass.md)
- Memory: project-voice-commands-diagnosis · project_93_subscription_backend_done · project_95_custom_pack_decisions · project_concurrent_sessions_same_checkout
- [handoff-2026-07-12-1815.md](../handoffs/handoff-2026-07-12-1815.md) — repo state before this plan
