# App Store release — Fable orchestration runbook

**Created:** 2026-07-11 (founder request: prepare all release-blocking issues for autonomous, Fable-orchestrated execution). **This file is the launch document** — it supersedes `execution-queue-2026-07.md` as the entry point; that file's Q-prompts remain the payload for the sessions that reference them.

## How to launch

Open a fresh Claude Code session on **Fable** and paste:

```
You are the release orchestrator. Read docs/issues/release-orchestration-2026-07.md and execute it per its ## Orchestrator rails. Start at the first unticked session in ## Status whose dependencies are met, and keep going until every agent-runnable session is done or blocked on a [HUMAN] gate — then report the founder checklist state.
```

## Orchestrator rails (Fable)

1. **Fable coordinates, never implements.** One subagent per session (Agent tool, `model` per the Session table), fed that session's self-contained fenced prompt from the named source file. Fable reads reports, not raw project files — keep bulk reading inside subagents.
2. **Sequential in this checkout.** Never two agents mutating the same checkout concurrently (memory: `project_concurrent_sessions_same_checkout` — a past parallel run fabricated a test result). Worktree isolation only if a row explicitly says so.
3. **Model routing:** **opus** = code implementation + adversarial reviews · **sonnet** = docs, metadata, Pencil, sim verification, instrumentation, scripted ops · **haiku** = trivial hygiene. Fable takes no session itself.
4. **maker≠checker** on rows marked `review: opus`: after the maker's `Done =` gate is green, spawn a **fresh-context opus adversarial reviewer** to disprove the diff (the #93 pattern — its reviews caught 4 real bugs). Tick only on `Done ✅` **and** `Reviewed ✅`; a reviewer defect becomes a fix task for a fresh maker.
5. **Durable state:** update `## Status` here after every session (and the source file's own tracking). Never tick on red; retry within the prompt's budget, then stop and surface. On a `[HUMAN]` gate: halt that wave, continue other unblocked waves, and surface the gate in the end-of-run report.
6. ⚠️ **Deploy freeze (quiz-agent):** main carries the **undeployed #93 entitlement gate** — a prod deploy now, without migration `0005` + RevenueCat secrets, breaks question serving (gate reads tables that don't exist in prod) and silently flips the free tier 100→30. **Until the F2 deploy event, every backend session commits + pushes only — ignore the older "fly deploy" line inside Q1/Q3/Q4 prompts.** F2 then ships everything accumulated on main at once.
7. **Fail loud, report at product level.** The founder reads done/blocked, not dev-logs.

## What changed since the Q-queue (verified first-hand 2026-07-11)

- **#93 backend is DONE on main** (Sessions A–D + adversarial reviews; ASC leg of Session 0 done — all 3 IAP products READY_TO_SUBMIT). Remaining: RC account (founder) → RC provisioning → Session E (iOS) → sandbox + founder-gated deploy.
- **#90 CLOSED — fully subsumed** by #93 Session B: `record_question` re-derives the path atomically (`tracker.py:130-132`), credit debit under `pg_advisory_xact_lock` (`tracker.py:210-225`), concurrent regression test exists (`test_entitlement.py:240`). **Q2 struck from the queue.**
- **#89 NOT subsumed** — `identity.py` unchanged; #93's default-deny covers only the new subscription/credit reads, not the `if usage_tracker and session.user_id:` bypass. **Q4 stands as written.**
- **Q1 (#88) and Q5 (#79) anchors hold exactly.** Q3 (#91) drift only: `/usage` now `misc.py:70-78` (typed `UsageResponse`, still trusts the path param), admin key compares `misc.py:92` + **`app/api/admin.py:45`** (not `routes/admin.py`), `/auth/apple` exchange `auth.py:328-331` / merge `:357` / 409 raise `:468`. All 6 items still open.
- **ASC API key already wired** (`apps/ios-app/Hangs/fastlane/.env`, CI secrets) → #50's agent-side metadata work is unblocked today.
- **ASC app name save UNCONFIRMED** — the app record (6762482437) is referenced as "Trubbo" in the 2026-07-10 handoff but no doc records the Name-field save. R13 verifies via the ASC API before anything ships.

## Session table

Order within a wave = run order. `Prompt source` = where the subagent's fenced prompt lives. Waves are independent unless a dependency is named; respect rail 2 (sequential).

| # | Wave | Session | Model | Review | Prompt source | Depends on |
|---|---|---|---|---|---|---|
| R0 | 0 founder-unblock | Author step-by-step `[HUMAN]` guides for the founder | sonnet | — | §Prompts R0 | — |
| R1 | 1 security | #88 refresh reuse-grace (HIGH) | opus | **opus** | queue **Q1** (skip its deploy step — rail 6) | — |
| R2 | 1 security | #89 null-subject grace guard | opus | — | queue **Q4** (skip deploy — rail 6) | R1 |
| R3 | 1 security | #91 low-severity sweep (6 items) | opus | — | queue **Q3** + anchor corrections above | R2 |
| R4 | 2 #93 | RevenueCat provisioning via API (agent leg) | sonnet | — | §Prompts R4 | **F1** |
| R5 | 2 #93 | Session E — iOS RevenueCat + paywall | sonnet | — | `issue-93-execution-prompts.md` §Session E | R4 |
| — | 2 #93 | **F2 deploy event** (migration 0005 + secrets + deploy incl. Wave-1 fixes; sandbox purchase check) | — | — | §Founder checklist | R5, R1–R3 |
| R6 | 3 iOS fixes | #79 typed×voice double-submission race | opus | — | queue **Q5** | — |
| R7 | 3 iOS fixes | #78 Apple Sign-In name loss (backend deploy waits for F2) | opus | — | queue **Q7** (ignore its Q6 precondition — Q6 replaced by R18) | R6 |
| R8 | 3 iOS fixes | #45 45.7-wire MCQ select-then-confirm | opus | — | queue **Q8** (re-grep anchors after R6) | R6 |
| R9 | 3 iOS fixes | #45 45.13 snapshot baselines re-record | sonnet | — | queue **Q9** | R8 |
| R10 | 3 iOS fixes | #45 45.11 light/dark delta vs `.pen` | sonnet | — | queue **Q10** | — |
| R11 | 4 verification | #59 RS-11/12/13/15/16 sim legs | sonnet | — | queue **Q11** | wave 3 done |
| R12 | 4 verification | #56 localization reconcile + close-out | sonnet | — | queue **Q12** | — |
| R13 | 5 brand/listing | #92 S2 — ASC-name verify + `.pen` + living docs | sonnet | — | `issue-92-rename-trubbo.md` §Session 2, **prepended by §Prompts R13-pre** | — |
| R14 | 5 brand/listing | #50 agent leg — store metadata SK/CZ/EN + deliver wiring + privacy-label draft | sonnet | — | §Prompts R14 | R13 |
| R15 | 5 brand/listing | #92 S3 — TestFlight ship | sonnet | — | `issue-92-rename-trubbo.md` §Session 3 | R5, R13, wave 3 |
| R16 | 6 analytics | 51.3 backend event instrumentation | sonnet | — | §Prompts R16 | **F5** |
| R17 | 6 analytics | 51.4 iOS instrumentation + 51.5 e2e verify | sonnet | — | §Prompts R17 | R16 |
| R18 | 7 content | `/prepare-issue` post-answer context playback (= 75.6 first live run) | opus | — | §Prompts R18 | — |
| R19 | 7 content | Corpus swap: document resume state → finish 100 → prod archive+import | sonnet | — | §Prompts R19 | **F6** |
| R20 | 8 hygiene | #55 docs-drift commit pass | haiku | — | queue **Q13** | best after waves 1–7 |
| R21 | 8 hygiene | #71 GitHub Issues mirror refresh | haiku | — | queue **Q14** | R20 |
| R22 | 9 release gate | #48 Stage 0 — UX/UI release-readiness review | sonnet | — | §Prompts R22 | waves 2–5 done |
| R23 | 9 release gate | #48 Stage 1 — architecture review | opus | — | §Prompts R23 | R22 |
| R24 | 9 release gate | #48 Stage 2 — security review | opus | — | §Prompts R24 | R23 |
| — | 9 release gate | **F7** `/code-review ultra` + go/no-go (founder-triggered, billed) | — | — | §Founder checklist | R24 |

Remediation sessions from R22–R24 findings are created ad hoc (opus), one per confirmed blocker, and appended to ## Status.

## Prompts (sessions with no existing fenced prompt)

### R0 — founder `[HUMAN]` guides

```
Author step-by-step founder guides (docs-only session). Create docs/setup/founder-human-gates-2026-07.md with one numbered, zero-prior-knowledge section per pending [HUMAN] gate: (1) RevenueCat company-account creation + secret API v2 key + where to paste it (from issue-93-execution-prompts.md §Human prerequisites steps 2a/2e + handoff-2026-07-10-1632.md); (2) #93 sandbox purchase check on device; (3) 77.15 in-car voice-command test (from issue-77 plan); (4) #61 Apple sign-in device verify (SK) + App Store privacy nutrition label; (5) 59.1 device TTS check (SK, AirPods); (6) 67-A phone-call interruption recovery check; (7) #51 gate 51.2 — skim docs/product/analytics-events.md; (8) F2 deploy-event approval (what ships: migration 0005, RC secrets, free tier 100→30, Wave-1 auth fixes); (9) corpus-swap go (OpenRouter credit + prod import). Each section: why it matters (one line), exact steps, what to tell the agent afterwards. ≤200 lines total. Commit + push; add a TODO.md pointer on the existing "Prepare step-by-step [HUMAN] guides" line and tick it.
```

### R4 — RevenueCat provisioning (agent leg, after F1)

```
Issue #93 Session 0, RC leg (founder has created the RevenueCat account and pasted a secret API v2 key into the session or apps/quiz-agent/.env as REVENUECAT_SECRET_API_KEY). Read docs/issues/issue-93-execution-prompts.md §Human prerequisites (steps 2a–2e) + docs/handoffs/handoff-2026-07-10-1632.md §Next steps. Via the RC REST API: create/verify the project + App Store app (bundle com.missinghue.hangs), entitlement `unlimited` with com.carquiz.unlimited.monthly + .annual attached, com.carquiz.pack.questions100 as a plain product, offering `default` with the three packages. Dashboard-only steps (ASC shared-secret paste, webhook URL + Authorization secret) — give the founder exact clicks and STOP until confirmed. Then record which secrets exist where (never print values), update the Session 0 row in issue-93-execution-prompts.md ## Status, commit + push. Do NOT set Fly secrets (F2, founder-gated).
```

### R13-pre — ASC name verify (prepend to #92 Session 2)

```
Before #92 Session 2 work: verify the App Store Connect app name first-hand. Using the ASC API key in apps/ios-app/Hangs/fastlane/.env (pattern: docs/handoffs/handoff-2026-07-10-1632.md — app id 6762482437), GET the app record's name. If it is "Trubbo": record the [HUMAN] name gate as DONE in issue-92 + TODO. If it is still "Hangs" or anything else: try PATCH name=Trubbo via API; if the API path fails, STOP and hand the founder the 4-step manual save from issue-92 Session 3 — do not proceed to Session 3 later without this gate green. Then continue with the Session 2 task list from docs/issues/issue-92-rename-trubbo.md (.pen text nodes via pencil MCP, CONTEXT.md, README, product docs, naming addendum, grep verify). The .pen edit ends with the [HUMAN] ⌘S note for the founder (F3).
```

### R14 — #50 store metadata (agent leg)

```
Issue #50 agent leg (ASC API key already wired — apps/ios-app/Hangs/fastlane/.env; app record 6762482437 "Trubbo" exists with IAP products READY_TO_SUBMIT). Read docs/issues/issue-50-app-store-connect-setup.md + docs/artifacts/asc-setup-instructions-2026-06-09.html (founder steps context) + CONTEXT.md (product truth). Deliverables: (1) fastlane deliver metadata structure under apps/ios-app/Hangs/fastlane/metadata/ with SK + EN (+ CZ if a cs locale is supported for the store) name/subtitle/description/keywords/promotional text — derived from the real app (voice-first trivia for driving, Trubbo brand, subscription €4.99 + packs), never invented features; (2) privacy nutrition label DRAFT as a doc (docs/product/privacy-nutrition-label.md) mapping actual data flows (auth identifiers, usage counts, Sentry crash data, no tracking) — founder enters it in ASC ([HUMAN], #61 tail); (3) verify which founder [HUMAN] steps from the issue remain (agreements/availability) and list them crisply in the issue file. No screenshots this session. Done = deliver-lint passes on the metadata dir (fastlane deliver --verify_only if available, else structural check), docs committed + pushed, issue-50 + TODO/INDEX updated (agent leg done, founder tail listed).
```

### R16 — 51.3 backend analytics

```
Issue #51 task 51.3 (founder gate 51.2 is ticked — verify in issue-51 before starting; if unticked, STOP). Read docs/issues/issue-51-product-analytics.md + docs/product/analytics-events.md (9 events; its file:line anchors are stale — re-grep every trigger point fresh). Implement the backend-truth events via the existing sentry_sdk init (apps/quiz-agent/app/main.py) as structured events/breadcrumbs per the taxonomy: answer evaluated (correctness, category, question type), transcription failure, quota hit. No new SDK, no PII beyond the taxonomy, events mockable in tests (patch the emitter, not sentry). Tests: one per event proving trigger + payload shape. Done = cd apps/quiz-agent && uv run --no-sync pytest tests/ -v green. Commit + push (deploy rides F2 or later). Tick 51.3 in issue-51 + TODO.
```

### R17 — 51.4 iOS analytics + 51.5 verify

```
Issue #51 tasks 51.4 + 51.5 (51.3 merged). Read docs/issues/issue-51-product-analytics.md + docs/product/analytics-events.md (re-grep stale anchors). iOS: AnalyticsClient protocol + Sentry-backed implementation (existing sentry-cocoa SDK — no new dependency), injected + mocked in tests, hooked into QuizViewModel phase transitions for the client-side events in the taxonomy. Tests: ViewModel emits the expected events on the right transitions. 51.5: run a local e2e smoke (backend running, sim quiz round) and verify events arrive in Sentry (org missinghue, project carquiz — /check-crashes skill shows the query pattern); create/document the dashboard queries in the issue. Done = targeted iOS suites green + e2e events verified first-hand (screenshot/query output in the issue changelog). Commit + push. Tick 51.4/51.5; #51 → done in TODO/INDEX if nothing remains.
```

### R18 — post-answer context playback prep

```
Run /prepare-issue on the "Post-answer context payoff — app/serving playback" TODO line (#72 follow-up, founder ask 2026-07-10). Facts verified 2026-07-11: `explanation` already flows into evaluation payloads (apps/quiz-agent/app/quiz/flow.py:161-162,189-190) and iOS decodes it (Question/Evaluation models) — but backend TTS never speaks it (_generate_feedback_audio flow.py:346-359 uses only the correctness message) and no iOS View/ViewModel consumes it. Scope for the plan: speak/play the explanation after the answer reveal in BOTH voice and MCQ modes, driving-safe (short, interruptible by next/skip), settings toggle TBD by plan. This is also issue #75 task 75.6's first live end-to-end run of the orchestrator skill — record skill bugs found + fixed in issue-75 and tick 75.6 if the run completes (note: the large-issue /split-issue branch counts as exercised only if this issue splits into sessions). Output: a ready issue file (next free number) with both gate verdicts + atomic tasks; do NOT implement. Its impl sessions get appended to release-orchestration-2026-07.md ## Status afterwards (impl sequencing = founder call, per the TODO line).
```

### R19 — corpus swap resume (after F6)

```
#72 follow-up: finish the prod corpus swap (founder has topped up OpenRouter credit and given the prod-import go — F6; verify both before mutating anything). State verified 2026-07-11: generation stopped at 46/100 (local apps/quiz-pack-api/data/generation-2026-07-10/parts/part01..05.json, gitignored; driver gen100_driver.py same dir), tooling shipped in d7753cf (import_questions_json.py + archive_questions.py + migration 7a2c91d40b1e), stop reason undocumented. Steps: (1) FIRST write the missing resume-state note into docs/handoffs/ (46/100, driver, credit exhaustion) so the state is durable; (2) resume the driver for topics 6+ to 100 total with the standard enforce-flag config (Opus 4.8 gen per #72 close-out); (3) local validation pass (the #72 objective-metrics harness); (4) prod: alembic migration, archive_questions.py (dry-run → founder-visible summary → --execute), import_questions_json.py, verify counts + a served sample first-hand; (5) update TODO #72-swap line + memory-worthy state. Money + prod mutation = stop at any surprise. Done = prod serves the new corpus (spot-check via API), old corpus archived not deleted, handoff written.
```

### R22 — #48 Stage 0 UX review

```
Issue #48 Stage 0 — iOS UX/UI release-readiness review (report-only, no code changes). Read docs/issues/issue-48-pre-release-review-gauntlet.md Stage 0 scope. Drive the sim via the ios-ui-driver subagent through: onboarding, full voice-question loop, full MCQ loop, error paths (network off, at-capacity), results, settings, paywall — light + dark. Apply the review-ui skill per screen + a HIG pass. Output: docs/testing/runs/release-ux-review-<date>.md — ranked findings (blocker / should-fix / polish) with screenshots referenced, and an explicit go/no-go recommendation line. No fixes this session; blockers become ad-hoc remediation sessions in the runbook Status.
```

### R23 — #48 Stage 1 architecture review

```
Issue #48 Stage 1 — architecture review (report-only). Use the improve-codebase-architecture skill over apps/quiz-agent, apps/quiz-pack-api, packages/shared (read CONTEXT.md first). Focus: release-risk items only — coupling that will break under App Store load, missing seams for the freemium/entitlement path, config/deploy fragility (Dockerfile drift memory), NOT nice-to-have refactors. Output: findings ledger in docs/issues/issue-48-pre-release-review-gauntlet.md (Stage 1 section) — each finding file:line + release-blocking yes/no + one-line fix. Blockers → ad-hoc remediation sessions.
```

### R24 — #48 Stage 2 security review

```
Issue #48 Stage 2 — security review (report-only, the human-judgment release gate feeds on this). Spawn the security-reviewer agent over the full release surface: auth (JWT/refresh/SIWA/App Attest), freemium + entitlement gate + RC webhook (#93 — new code, highest risk), admin endpoints, rate limiting, secrets handling, Fly exposure, GDPR endpoints. Cross-check the #88/#89/#91 fixes landed (Wave 1). Output: findings in issue-48 Stage 2 section, severity-ranked, each with exploit scenario + fix; explicit statement of what is release-blocking. Founder makes the block/defer calls (surface, don't decide monetization-risk acceptance).
```

## Founder checklist (`[HUMAN]` — R0 writes the detailed guides)

| Gate | What | Unblocks |
|---|---|---|
| **F1** | RevenueCat company account + secret API v2 key (paste in-session) | R4 → R5 → whole #93 tail |
| **F2** | Deploy event: approve migration `0005` + RC Fly secrets + quiz-agent deploy (ships Wave-1 auth fixes, free tier 100→30) + sandbox purchase check on device | unfreezes all backend deploys |
| **F3** | Pencil ⌘S after R13's `.pen` edits | #92 S2 commit |
| **F4** | #50 founder tail: ASC agreements/availability confirm + enter privacy nutrition label (draft from R14) | listing submission |
| **F5** | 51.2 — 5-min skim of `docs/product/analytics-events.md` | R16, R17 |
| **F6** | OpenRouter credit top-up + prod corpus-import go | R19 |
| **F7** | Trigger `/code-review ultra` (billed) + final go/no-go | submission |
| device | 77.15 in-car commands · #61 SK sign-in · 59.1 TTS (SK, AirPods) · 67-A interruption recovery | closing #77/#61/#59/#67 |

## Out of the release path (not scheduled here)

#62 (post-MVP) · #63 (founder-in-the-loop audit) · #64 (umbrella) · #30/#74/#76 tails (generation scale-up, post-swap) · #57 Track F (loop infra) · #67-B barge-in (founder: post-MVP) · Hetzner migration · web-ui removal + doc refresh + debt fixes (TODO lines, run opportunistically as haiku/sonnet sessions if a wave stalls).

## Status

`Done` = session's own gate green · `Reviewed` = adversarial review where required (else n/a).

| # | Session | Done | Reviewed | Box |
|---|---|---|---|---|
| R0 | founder guides | ⬜ | n/a | ⬜ |
| R1 | #88 reuse-grace | ⬜ | ⬜ | ⬜ |
| R2 | #89 null-subject | ⬜ | n/a | ⬜ |
| R3 | #91 sweep | ⬜ | n/a | ⬜ |
| R4 | RC provisioning | ⬜ | n/a | ⬜ |
| R5 | #93 Session E | ⬜ | n/a | ⬜ |
| F2 | deploy event | ⬜ | n/a | ⬜ |
| R6 | #79 race | ⬜ | n/a | ⬜ |
| R7 | #78 name loss | ⬜ | n/a | ⬜ |
| R8 | 45.7-wire | ⬜ | n/a | ⬜ |
| R9 | 45.13 snapshots | ⬜ | n/a | ⬜ |
| R10 | 45.11 light/dark | ⬜ | n/a | ⬜ |
| R11 | #59 RS legs | ⬜ | n/a | ⬜ |
| R12 | #56 close-out | ⬜ | n/a | ⬜ |
| R13 | #92 S2 + name gate | ⬜ | n/a | ⬜ |
| R14 | #50 metadata | ⬜ | n/a | ⬜ |
| R15 | #92 S3 TestFlight | ⬜ | n/a | ⬜ |
| R16 | 51.3 backend | ⬜ | n/a | ⬜ |
| R17 | 51.4/51.5 iOS | ⬜ | n/a | ⬜ |
| R18 | playback prep | ⬜ | n/a | ⬜ |
| R19 | corpus swap | ⬜ | n/a | ⬜ |
| R20 | #55 docs commit | ⬜ | n/a | ⬜ |
| R21 | #71 mirror | ⬜ | n/a | ⬜ |
| R22 | #48 Stage 0 | ⬜ | n/a | ⬜ |
| R23 | #48 Stage 1 | ⬜ | n/a | ⬜ |
| R24 | #48 Stage 2 | ⬜ | n/a | ⬜ |
