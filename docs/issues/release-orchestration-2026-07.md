# App Store release — Fable orchestration runbook

**Created:** 2026-07-11 · **Reality-audit + rewrite: 2026-07-14** (12-agent workflow audit: every row verified first-hand against code, docs and git; founder re-decided order + gates in-session). This file stays the launch document. `execution-queue-2026-07.md` Q-prompts remain the payload where referenced, **but every dispatch must first apply the session's ## Anchor deltas block below** — #93/#96 churn drifted most file:line anchors, including the ones this runbook itself "verified" on 2026-07-11.

## How to launch

Open a fresh Claude Code session on **Fable** and paste:

```
You are the release orchestrator. Read docs/issues/release-orchestration-2026-07.md and execute it per its ## Orchestrator rails. Start at the first unticked session in ## Status whose dependencies are met, and keep going until every agent-runnable session is done or blocked on a founder gate — then report the founder checklist state.
```

## What the 2026-07-14 reality audit changed

- **#96 (all 7 phases + TestFlight as Trubbo) delivered waves 1/2/5 out-of-band**: R1+R2 (#88/#89 via `1c2eff7`, incl. adversarial review), R4+R5+F1+F2-mechanics (#93 prod-live `c6c05b5`, 2026-07-11), R13+R15+F3 (#92 S2/S3 via `a9ec437`+`386e6ac`, `.pen` committed `99ca8fb`). Moved to §Completed — never re-schedule them.
- **Deploy freeze LIFTED** (old rail 6 deleted): migration 0005 + RC secrets live in prod since 2026-07-11. Backend sessions commit+push+**deploy autonomously** again per standing founder delegation; new migrations/secrets stay founder-gated.
- **#91 is 5/6 open**, not 6/6: item 2 (/usage IDOR) closed incidentally by #96 P1 — `/usage/me` is bearer-only, the path-param endpoint was deleted (`misc.py:71-88`).
- **TestFlight gap**: shipped build (run 29255778835 @ `386e6ac`) predates the 2026-07-14 iOS review fixes `1808036` (voice-indicator reactivity, order-poll resilience) — exactly the flows the founder must re-test. N1 ships a fresh build FIRST.
- **Corpus swap**: generation 100/100 done + validated (`8f5e0d2`); old R19 steps 1–3 are moot. **Founder GO for prod import granted in-session 2026-07-14** → N3 is agent-runnable now.
- **Founder decisions 2026-07-14**: order = build → fixes → verification/listing → analytics → reviews; **analytics stays pre-release** with gate 51.2 done **interactively in-chat** (see rail 6); **blind-rating reduced to a ~10-question sample**; **pen dynamic-state rows WILL be synced** (N4). Stray `.claude/rules/*.md` trims committed 2026-07-14 (were ownerless WIP since ~07-12).
- **Doc-state debt** folded into R20: issue-88/89 Acceptance + TODO #88/#89 lines still untick despite being live; INDEX rows #92–#96 show pre-completion states.

## Orchestrator rails (Fable)

1. **Fable coordinates, never implements.** One subagent per session (Agent tool, `model` per the table), fed the session's fenced prompt (source column) **plus its Anchor-deltas block**. Fable reads reports, not raw project files.
2. **Sequential in this checkout.** Never two agents mutating the same checkout concurrently (memory: `project_concurrent_sessions_same_checkout`). Worktree isolation only if a row says so.
3. **Model routing:** opus = code implementation + adversarial reviews · sonnet = docs, metadata, Pencil, sim verification, instrumentation, scripted ops · haiku = trivial hygiene. Fable takes no session itself.
4. **maker≠checker** on rows with `review: opus` (auth/payment surface): after the maker's gate is green, a fresh-context opus reviewer tries to disprove the diff. Tick only on Done ✅ + Reviewed ✅.
5. **Durable state:** update ## Status here after every session (+ the source issue's own tracking). Never tick on red; retry within budget, then stop and surface. On a founder gate: halt that wave, continue unblocked waves, surface the gate in the report.
6. **Interactive founder gates run in the MAIN session.** G2 (51.2 analytics approval) is asked by the orchestrator live in-chat (question prompt, full context — the 10 events summarized) BEFORE dispatching R16; workers never ask the founder. Founder decision 2026-07-14: interactive in-chat beats "go read a doc and tick it".
7. **Deploys:** backend sessions deploy to Fly autonomously on green (standing delegation); new migrations or secrets = stop and ask. N3 mutates prod DATA — its GO is already granted, but it must still stop on any surprise (counts mismatch, unexpected schema state).
8. **Fail loud, report at product level.** The founder reads done/blocked, not dev-logs.

## Session table — remaining work only (2026-07-14)

Order within a wave = run order. Waves respect rail 2 (sequential). Wave 5 rows are code-free and may interleave anywhere.

| # | Wave | Session | Model | Review | Prompt source | Depends on |
|---|---|---|---|---|---|---|
| N1 | 0 ship | Fresh TestFlight build (carries `1808036` iOS review fixes) | sonnet | — | §Prompts N1 | — |
| R0 | 0 ship | Founder-gate guides doc (narrowed scope) | sonnet | — | §Prompts R0 | — |
| R3 | 1 fixes | #91 auth low-severity sweep — **5 remaining items** | opus | **opus** | queue **Q3** + deltas | — |
| R6 | 1 fixes | #79 typed×voice double-submission race | opus | — | queue **Q5** + deltas | — |
| R7 | 1 fixes | #78 Apple Sign-In name loss (deploy on green) | opus | — | queue **Q7** + deltas | R6 |
| R8 | 1 fixes | #45 45.7-wire MCQ select-then-confirm | opus | — | queue **Q8** + deltas (re-grep after R6) | R6 |
| R9 | 1 fixes | #45 45.13 snapshot baselines (premise fixed) | sonnet | — | queue **Q9** + deltas | R8 |
| R10 | 1 fixes | #45 45.11 light/dark delta vs `.pen` | sonnet | — | queue **Q10** + deltas | — |
| R11 | 2 verify | #59 RS-11/12/13/15/16 sim legs (patch RS-12 spec first) | sonnet | — | queue **Q11** + deltas | R6, R8 |
| R12 | 2 verify | #56 close-out + xcstrings resync (added step) | sonnet | — | queue **Q12** + deltas | — |
| R14 | 3 listing | #50 store metadata SK/CZ/EN + privacy-label draft | sonnet | — | §Prompts R14 (held from 07-11) | — |
| R16 | 4 analytics | 51.3 backend events — **G2 interactive approval first** | sonnet | — | §Prompts R16 | G2 |
| R17 | 4 analytics | 51.4 iOS instrumentation + 51.5 e2e verify | sonnet | — | §Prompts R17 + deltas | R16 |
| N2 | 5 content | Blind-rating sample prep (~10 q, 5 Opus / 5 glm) | haiku | — | §Prompts N2 | — |
| N3 | 5 content | Corpus prod import (ex-R19 steps 4–5; **GO granted**) | sonnet | — | §Prompts N3 | — |
| R18 | 5 content | `/prepare-issue` post-answer context playback (75.6 live run) | opus | — | §Prompts R18 (held; 1-line delta) | — |
| N4 | 5 content | Pencil dynamic-state rows sync (founder-approved) | sonnet | — | §Prompts N4 | — |
| R20 | 6 hygiene | #55 docs-drift commit + doc-state reconciliation + INDEX regen | sonnet | — | queue **Q13** + deltas | best after waves 1–5 |
| R21 | 6 hygiene | #71 GitHub Issues mirror refresh | haiku | — | queue **Q14** | R20 |
| R22 | 7 gate | #48 Stage 0 UX review (**scope += #95 pack flow**) | sonnet | — | §Prompts R22 | waves 1–4 done |
| R23 | 7 gate | #48 Stage 1 architecture review | opus | — | §Prompts R23 | R22 |
| R24 | 7 gate | #48 Stage 2 security review (**new-surface targets**) | opus | — | §Prompts R24 | R23, R3 |
| — | 7 gate | **G6** `/code-review ultra` + go/no-go (founder-triggered, billed) | — | — | §Founder checklist | R24 |

Remediation sessions from R22–R24 findings are created ad hoc (opus), one per confirmed blocker, appended to ## Status.

## Anchor deltas (verified first-hand 2026-07-14) — apply before dispatching

- **R3/Q3:** item 2 = DONE, skip (tick its box in issue-91: "satisfied by #96 P1 `bd0f4e7`"). Item 1 `AuthService.swift:428-430` (SecRandomCopyBytes result still discarded). Item 3 `misc.py:102` + `app/api/admin.py:45` (both plain `!=`, no hmac import). Item 4 `sessions.py:132/:134`, `quiz.py:97-100/:179-181` (`quiz.py:142` stays untouchable). Item 5 `auth.py` exchange `:328-331`, merge `:357`, 409 `:468`. Item 6 unchanged — no pruning anywhere.
- **R6/Q5:** `resubmitAnswer` QuizViewModel.swift:785-831 · `transition()` :322 · `isProcessingResponse` :363 (guards :1033-1038, :1238) · `handleCommittedTranscript` +Recording.swift:190-244 · `confirmAnswer` +Recording.swift:465-483 · `cancelProcessing` :541-556 · `submitTypedAnswer` QuestionView.swift:589-595 · `counterString` QuestionView :139-142 / ResultView :298-299. Race confirmed still live (streaming STT default). The 07-11 claim "Q5 anchors hold exactly" is false.
- **R7/Q7:** `AuthTokenResponse` deps.py:251-264 · `apple_sign_in` auth.py:283-368 (return :363-368) · `completeAppleSignIn` AuthService.swift:462-533 (construction :507-514) · SettingsView :399. Strike the "backend deploy waits for F2" caveat — deploy on green.
- **R8/Q8:** sheet wiring QuestionView :52-68 holds · `mcqBody` :305-374, onSelect :331-334 · MCQ voice branch +Recording.swift:216-233 · `confirmAnswer` +Recording.swift:465-483 **but `resubmitAnswer` = QuizViewModel.swift:785 — different file, don't grep one range** · `QuizState` :22-30 holds · transition table :322 · `mcqVoiceMatchedKey` :392 (read :333) · `submitMCQAnswer` :761.
- **R9/Q9:** paths hold; premise fix — **no MCQ baseline exists to "re-record"**. Step 1 = confirm none, then decide whether R8's select-state makes one snapshot-worthy (add new, don't hunt for old). #96 P3 (`a6fdfe7`) + Trubbo wordmark already re-recorded 7 baselines — diff against those, not June's.
- **R10/Q10:** component path is `Components/Hangs/AnswerOption.swift`. Before step 1, confirm `.pen` node `vAXMX` still resolves via pencil MCP (`99ca8fb` archived 5 frames; `EZhqr` confirmed current).
- **R11/Q11:** RS-11/13/15/16 specs hold. **RS-12 must be amended first** (regression-scenarios.md:343-347): `c50ffc1` added the conditional CmdListenBar row into the exact VStack RS-12 probes — pin/record `commandListenerHint` identically across both snapshots, else the y-origin assert is confounded.
- **R12/Q12:** add step — **resync Localizable.xcstrings against `a6fdfe7`'s hero renames** (drop orphaned `NAILED\nIT.`/`MISSED\nIT.` keys, add the 3 single-line strings). `.claude/rules/ios.md` anchors now :27 and :37-44.
- **R16/R17:** backend anchors verified near-exact (`flow.py:140` evaluate inside `process_answer` :93 · `transcriber.py:249` · `voice.py` except-block :189). iOS anchors in analytics-events.md are all stale — corrected: `startNewQuiz` :499 (`.startingQuiz` :505) · `.finished` :1185 · `resetToHome` :945 · `.askingQuestion` :569 + :1199 **+ new third site :732 in `retryLastOperation` — EXCLUDE it from `question_presented`** (same question re-asked after an error; counting it would inflate the voice-reliability denominator) · `.processing` +Recording :240/:328 · `resubmitAnswer` QuizViewModel.swift:785.
- **R18:** premise holds exactly (`flow.py:161-162,:189-190` explanation in payload; `_generate_feedback_audio` now :347-360 still ignores it).
- **R20/Q13:** untracked categories hold (volume grew ~30→45 files, no new category). Drop the "design/quiz-agent.pen modified" clause from the done-bar (committed `99ca8fb`); the stray `.claude/rules` edits were committed 2026-07-14 — no longer pending. ADD: tick issue-88/issue-89 Acceptance + TODO #88/#89 + INDEX #88/#89 (evidence `1c2eff7`), and regenerate stale INDEX rows #92–#96 via `/triage`.

## Prompts (new or rescoped sessions)

### N1 — TestFlight refresh

```
Ship a fresh TestFlight build from current main so the founder's on-device checklist runs against the fixed app (shipped run 29255778835 predates 1808036: voice-indicator reactivity + order-poll fixes — exactly the P2/P5 flows he retests). Steps: verify main is clean and pushed; run the /testflight skill; confirm the workflow run goes green and the build reaches TestFlight processing; record run id + build number in issue-96 (P7 note) and docs/todo/TODO.md #96 line. No code changes. If the build fails, fix ONLY pipeline/signing issues (memory: project_ios_capability_profile_regen) and surface anything needing founder action.
```

### R0 — founder gate guides (narrowed 2026-07-14)

```
Author docs/setup/founder-human-gates-2026-07.md (docs-only). Cover ONLY what nothing else documents — one numbered, zero-prior-knowledge section each: (1) G1: redo the #96 P7 on-device checklist on the NEW TestFlight build from N1 (point to issue-96's own checklist + voice-command cheat-sheet; note the old build predates the fixes); (2) G3: blind-rate the ~10-question sample N2 prepares (where the file is, how to record verdicts); (3) G4/#50 tail: ASC steps — confirm Paid Apps Agreement, availability SK/CZ/EN, enter the privacy nutrition label from R14's draft (exact clicks); (4) G5: Pencil ⌘S after N4; (5) G6: how to trigger /code-review ultra and what go/no-go means; (6) the 4 device gates (77.15 in-car commands, #61 SK sign-in + privacy label, 67-A interruption recovery, 59.1 TTS — note 59.1 is likely satisfiable by ticking from 2026-07-12 real-device usage, founder's call). Do NOT re-document F1/F2/F3 (done) or 51.2 (handled interactively in-chat by the orchestrator). ≤150 lines. Commit + push; tick the TODO "Prepare step-by-step [HUMAN] guides" line.
```

### R14 — #50 store metadata (unchanged from 07-11, still never run)

```
Issue #50 agent leg (ASC API key wired — apps/ios-app/Hangs/fastlane/.env; app record 6762482437 "Trubbo" exists, IAP products READY_TO_SUBMIT). Read docs/issues/issue-50-app-store-connect-setup.md + docs/artifacts/asc-setup-instructions-2026-06-09.html + CONTEXT.md. Deliverables: (1) fastlane deliver metadata structure under apps/ios-app/Hangs/fastlane/metadata/ with SK + EN (+ CZ if a cs locale is supported) name/subtitle/description/keywords/promotional text — derived from the real app (voice-first trivia for driving, Trubbo brand, €4.99 sub + packs), never invented features; (2) privacy nutrition label DRAFT at docs/product/privacy-nutrition-label.md mapping actual data flows (auth identifiers, usage counts, Sentry crash data, no tracking); (3) list crisply in issue-50 which founder steps remain (agreements/availability — NOT confirmed anywhere, don't assume). Done = deliver --verify_only (or structural check) passes; docs committed + pushed; issue-50 + TODO/INDEX updated.
```

### R16 — 51.3 backend analytics (G2 asked in-chat first)

```
Issue #51 task 51.3. PRECONDITION: the orchestrator has just obtained the founder's interactive in-chat approval of the 10-event taxonomy (G2) and ticked 51.2 in issue-51 — verify the tick exists; if not, STOP. Read docs/issues/issue-51-product-analytics.md + docs/product/analytics-events.md (its iOS anchors are stale — use the runbook's R16/R17 delta block; backend anchors verified 2026-07-14). Implement backend-truth events via the existing sentry_sdk init (apps/quiz-agent/app/main.py) as structured events/breadcrumbs: answer evaluated (correctness, category, question type), transcription failure, quota_hit. No new SDK, no PII beyond the taxonomy, emitter patched in tests (not sentry). Tests: one per event proving trigger + payload shape. Done = cd apps/quiz-agent && uv run --no-sync pytest tests/ -v green. Commit, push, deploy (rail 7). Tick 51.3.
```

### R17 — 51.4 iOS analytics + 51.5 verify (delta-corrected)

```
Issue #51 tasks 51.4 + 51.5 (51.3 merged). Read docs/issues/issue-51-product-analytics.md + analytics-events.md, then OVERRIDE its iOS anchors with the runbook's R16/R17 delta block (QuizViewModel rewritten since; note the third .askingQuestion site at :732 retryLastOperation is EXCLUDED from question_presented). iOS: AnalyticsClient protocol + Sentry-backed impl (existing sentry-cocoa, no new dependency), injected + mocked, hooked into QuizViewModel phase transitions. Tests: ViewModel emits expected events on the right transitions. 51.5: local e2e smoke (backend running, sim quiz round), verify events arrive in Sentry (org missinghue, project carquiz; /check-crashes shows the query pattern); document dashboard queries in the issue. Done = targeted iOS suites green + events verified first-hand. Commit + push. Tick 51.4/51.5; #51 → done if nothing remains.
```

### N2 — blind-rating sample prep (founder decision 2026-07-14: ~10 q, not 54)

```
Prepare the founder's model-pick blind test at reduced scope. From apps/quiz-pack-api/data/generation-2026-07-10/ (the 54 resumed questions: 27 Opus 4.8 / 27 glm-5.2; batch_review.md exists), build docs/testing/runs/corpus-blind-sample-2026-07.md with ~10 randomly selected questions (5 per model, shuffled, model identity hidden in the doc but recorded in a separate answer-key section at the bottom or a companion file). Rating instructions: founder marks each fun/flat per his rubric (memory: project_question_quality_founder_calibration). Outcome (G3) sets the default GENERATION_MODEL for future volume generation (#30/#95); it does NOT block N3 (this batch's 1:1 split is locked). Commit + push; add a TODO line pointing at the sample.
```

### N3 — corpus prod import (ex-R19 steps 4–5; founder GO granted in-session 2026-07-14)

```
Finish the #72 corpus swap in prod. Steps 1–3 (resume note, 100/100 generation, local validation) are DONE (07de4c1, 8f5e0d2) — do NOT redo. Input = apps/quiz-pack-api/data/generation-2026-07-10/batch.json (100 q, assembled 2026-07-12; NOT parts01-05). Read docs/handoffs/handoff-2026-07-12-1330.md + memory project_quiz_pack_prod_state first. Steps: (1) check prod's CURRENT alembic revision first-hand — migration 7a2c91d40b1e is very likely already applied (it is the parent of #95's deployed 4d8e2b7c1f0a); never blind-apply; (2) archive_questions.py dry-run → include the summary in your report; (3) --execute archive (old corpus archived, never deleted), then import_questions_json.py from batch.json; (4) verify counts + fetch a served sample first-hand via the API; (5) update TODO #72-swap line + write a short handoff. GO is granted, but STOP at any surprise: unexpected revision, count mismatch, serving errors. Prod data mutation only — no code, no LLM spend.
```

### R18 — post-answer context playback prep (held; 1-line delta)

```
Run /prepare-issue on the "Post-answer context payoff — app/serving playback" TODO line (#72 follow-up, founder ask 2026-07-10). Facts re-verified 2026-07-14: `explanation` flows into evaluation payloads (apps/quiz-agent/app/quiz/flow.py:161-162,189-190) and iOS decodes it — but backend TTS never speaks it (_generate_feedback_audio flow.py:347-360 uses only the correctness message) and no iOS View consumes it. Scope for the plan: speak/play the explanation after the answer reveal in BOTH voice and MCQ modes, driving-safe (short, interruptible by next/skip), settings toggle TBD by plan. This is also #75 task 75.6's first live run of the orchestrator skill — record skill bugs found+fixed in issue-75, tick 75.6 if the run completes. Output: a ready issue file (next free number) with both gate verdicts + atomic tasks; do NOT implement. Impl sequencing stays a founder call (per the TODO line).
```

### N4 — Pencil dynamic-state sync (founder approved 2026-07-14)

```
Sync the dynamic-state rows #96 P4 deferred into design/quiz-agent.pen via pencil MCP (get_editor_state + get_guidelines first; never Read/Grep the .pen). Rows (from issue-96-ios-mvp-completion.md P4 deferred list): quiz timer chip/speaker variants, Answer-Confirm progress/processing states, Result auto-advance controls, Quiz-Complete upsell card, Auth-sheet states. Match the SHIPPED app (screenshots via ios-ui-driver where needed) — design documents reality, no invented styling. End with the [HUMAN] note: founder must ⌘S in Pencil (G5) before the .pen commit. Update issue-96's deferred-rows note + TODO.
```

### R22 — #48 Stage 0 UX review (scope extended 2026-07-14)

```
Issue #48 Stage 0 — iOS UX/UI release-readiness review (report-only, no code changes). Read docs/issues/issue-48-pre-release-review-gauntlet.md Stage 0. Drive the sim via the ios-ui-driver subagent through: onboarding, full voice-question loop, full MCQ loop, error paths (network off, at-capacity), results, settings, paywall (#93/#94 — plan picker, upsell entries), AND the #95 custom-pack flow (OrderPackView order → poll → MyPacksView → play the pack) — light + dark. Apply review-ui per screen + a HIG pass. Output: docs/testing/runs/release-ux-review-<date>.md — ranked findings (blocker / should-fix / polish) + explicit go/no-go recommendation. Blockers become ad-hoc remediation sessions in ## Status.
```

### R23 — #48 Stage 1 architecture review

```
Issue #48 Stage 1 — architecture review (report-only). Use improve-codebase-architecture over apps/quiz-agent, apps/quiz-pack-api, packages/shared (read CONTEXT.md first). Focus: release-risk only — coupling that breaks under App Store load, seams for the freemium/entitlement path (#93 gate + RC webhook + #95 pack serving are the newest, least-reviewed surface), config/deploy fragility (Dockerfile drift memory). Output: findings in issue-48 Stage 1 section — file:line + release-blocking yes/no + one-line fix. Blockers → ad-hoc remediation sessions.
```

### R24 — #48 Stage 2 security review (targets + cross-check corrected 2026-07-14)

```
Issue #48 Stage 2 — security review (report-only; feeds the go/no-go). Spawn security-reviewer over the full release surface: auth (JWT/refresh/SIWA/App Attest), freemium + entitlement gate, admin endpoints, rate limiting, secrets, Fly exposure, GDPR endpoints. EXPLICIT priority targets (a real HIGH IDOR was already found+fixed ad hoc here — 1ac2900 — strong signal of more): apps/quiz-agent/app/api/routes/{webhooks,entitlements,sessions}.py, app/usage/{rc_service,subscription_state,tracker}.py, and quiz-pack-api's order/delivery endpoints. Cross-check landed fixes: #88+#89 via #96 P6 (1c2eff7), #91 five items via R3 (verify actually merged), pack-ownership 1ac2900. Output: findings in issue-48 Stage 2, severity-ranked, exploit scenario + fix, explicit release-blocking statement. Founder makes block/defer calls.
```

## Completed & superseded (evidence — do not re-schedule)

| Row | What | Evidence |
|---|---|---|
| R1 | #88 refresh reuse-grace | `1c2eff7` (#96 P6) — refresh.py:174-234 + 4 tests; adversarial review inside P6 caught+fixed a HIGH → Reviewed ✅ |
| R2 | #89 null-subject reject | `1c2eff7` — identity.py:116-135 + sessions.py:96-101 guard + test |
| R4+R5 | RC provisioning + #93 Session E | `9118564`, `407f421` |
| F1+F2 | RC account · deploy event (migration 0005 + secrets + deploy) | `c6c05b5` prod-verified 2026-07-11; sandbox retest lives on as **G1** (#96 P7 checklist, on the N1 build) |
| R13+R15+F3 | #92 S2/S3 + `.pen` ⌘S | `a9ec437`, `386e6ac` (run 29255778835), `99ca8fb`; ASC name gate closed by founder confirmation 2026-07-12 — accepted, no API re-read needed |
| — | #94 paywall z8TS6 sync | `748a320` |
| — | #96 review-pass fixes | backend `1ac2900` DEPLOYED; iOS `1808036` ships via **N1** |
| Q2 | #90 quota TOCTOU | struck 2026-07-11 — subsumed by #93 Session B |
| — | #95 Session 4 (end-user IAP pack payments) | post-MVP, parked — not in this release |

## Founder checklist

| Gate | What | When |
|---|---|---|
| **G1** | On-device #96 P7 checklist on the **N1 build (#22, run `29334191671`)**: sandbox sub + pack purchase retest, voice commands in practice, custom-pack order→play e2e | after N1 ✅ ready |
| **G2** | 51.2 — interactive in-chat approval of the 10 analytics events (incl. `quota_hit`, founder-approved 2026-07-14) (orchestrator asks you; ~2 min) | before R16 |
| **G3** | Blind-rate the ~10-question sample (5 Opus / 5 glm) → default generation model | after N2 |
| **G4** | #50 tail: ASC agreements + availability + enter privacy label (R14's draft; R0 writes the steps) | after R14 |
| **G5** | Pencil ⌘S after N4's `.pen` edits | after N4 |
| **G6** | Trigger `/code-review ultra` (billed) + final go/no-go | after R24 |
| device | 77.15 in-car commands · #61 SK sign-in + privacy label · 67-A interruption recovery · 59.1 TTS (recommend: tick from 2026-07-12 real usage) | any time |

Retired gates: F1/F2/F3 done (see §Completed) · F5 → G2 (interactive) · F6 → GO granted 2026-07-14 (N3 runs without further ask) · F7 → G6.

## Out of the release path

#62 (post-MVP) · #63 (founder-in-the-loop audit) · #64 (umbrella) · #30/#74/#76 tails (generation scale-up — pick up after G3's model verdict) · #57 Track F · #67-B barge-in · #95 Session 4 · Hetzner migration · web-ui removal (opportunistic haiku/sonnet if a wave stalls).

## Status

`Done` = session gate green · `Reviewed` = adversarial review where required (else n/a).

| # | Session | Done | Reviewed | Box |
|---|---|---|---|---|
| N1 | TestFlight refresh | ✅ | n/a | ✅ |
| R0 | founder guides | ⬜ | n/a | ⬜ |
| R3 | #91 sweep (5 items) | ⬜ | ⬜ | ⬜ |
| R6 | #79 race | ⬜ | n/a | ⬜ |
| R7 | #78 name loss | ⬜ | n/a | ⬜ |
| R8 | 45.7-wire | ⬜ | n/a | ⬜ |
| R9 | 45.13 snapshots | ⬜ | n/a | ⬜ |
| R10 | 45.11 light/dark | ⬜ | n/a | ⬜ |
| R11 | #59 RS legs | ⬜ | n/a | ⬜ |
| R12 | #56 close-out | ⬜ | n/a | ⬜ |
| R14 | #50 metadata | ⬜ | n/a | ⬜ |
| R16 | 51.3 backend (after G2) | ⬜ | n/a | ⬜ |
| R17 | 51.4/51.5 iOS | ⬜ | n/a | ⬜ |
| N2 | blind-rating prep | ⬜ | n/a | ⬜ |
| N3 | corpus prod import | ⬜ | n/a | ⬜ |
| R18 | playback prep | ⬜ | n/a | ⬜ |
| N4 | pen dynamic sync | ⬜ | n/a | ⬜ |
| R20 | #55 + doc reconcile | ⬜ | n/a | ⬜ |
| R21 | #71 mirror | ⬜ | n/a | ⬜ |
| R22 | #48 Stage 0 | ⬜ | n/a | ⬜ |
| R23 | #48 Stage 1 | ⬜ | n/a | ⬜ |
| R24 | #48 Stage 2 | ⬜ | n/a | ⬜ |
