# Execution queue — Opus session prompts (2026-07-07)

> **⚠️ 2026-07-11 — superseded as the entry point by [`release-orchestration-2026-07.md`](release-orchestration-2026-07.md)** (Fable-orchestrated release run; model routing + deploy freeze + [HUMAN] gates live there). The Q-prompts below remain the payload for the R-sessions that reference them. Deltas: **Q2 struck** (#90 fully subsumed by #93 Session B — atomic gate + advisory-lock debit + concurrent test, verified 2026-07-11); **Q1/Q4/Q5 anchors re-verified, hold**; **Q3 anchor drift** (see the runbook §What changed); **Q6 replaced** by the runbook's R18 (75.6 live run on the playback issue); ⚠️ **deploy freeze** — ignore the "fly deploy" step in Q1/Q3/Q4 until the F2 deploy event (main carries the undeployed #93 gate + migration 0005).

**Created:** 2026-07-07 by the backlog session-split pass (14-agent workflow: every open agent-runnable issue verified against today's code, sanity-checked, and cut into single-session tasks). **How to use:** open a fresh Claude Code session on **Opus**, paste one fenced block, go. One session at a time, always in this checkout — **never run two sessions in parallel** (see `project_concurrent_sessions_same_checkout`).

> Sanity-check outcomes folded in: **#70 CLOSED** (already fixed by `649b1b9`), **#89 downgraded to latent** (grace already off in prod), **#88's plan mechanism corrected** (hash-only storage), **#51 blocked on a 5-min founder gate**, four duplicate issue drafts deleted. Details in each issue file.

## Session table

| # | Issue | Session | Size | Depends on | Deploy |
|---|---|---|---|---|---|
| Q1 | #88 | Refresh reuse-grace (lost-response sign-out, HIGH) | M | — | Fly (auto) |
| Q2 | #90 | Atomic monthly-quota enforcement | M | — | Fly (auto) |
| Q3 | #91 | Auth low-severity sweep (6 items) | M | — | Fly (auto) |
| Q4 | #89 | Null-subject grace guard (latent) | S | — | Fly (auto) |
| Q5 | #79 | Typed×voice double-submission race (iOS) | M | — | — |
| Q6 | #75 | 75.6 `/prepare-issue` dry-run (guinea pig: #78) | M | — | — |
| Q7 | #78 | Apple Sign-In name loss fix | S | Q6 preferred, standalone OK | Fly (auto) |
| Q8 | #45 | 45.7-wire: MCQ select-then-confirm | M | run after Q5 (same file) | — |
| Q9 | #45 | 45.13: snapshot baselines re-record | S | Q8 | — |
| Q10 | #45 | 45.11: light/dark delta vs `.pen` | S | — | — |
| Q11 | #59 | RS-11/12/13/15/16 sim regression legs | S | — | — |
| Q12 | #56 | Localization close-out (see prompt) | S | — | — |
| Q13 | #55 | Docs-drift commit pass + `.obsidian` gitignore | S | best last-but-one | — |
| Q14 | #71 | GitHub Issues mirror refresh | S | after Q13 | — |

Q1–Q4 all touch `apps/quiz-agent` auth/usage — keep that order, deploy after each. Q5 and Q8 both edit `handleCommittedTranscript` — Q8 must re-grep its anchors after Q5 lands.

## Founder-only items (no agent session possible)

- **#51 gate 51.2 — ~5 min:** skim `docs/product/analytics-events.md` (9 events), confirm no conflict with #50 privacy labels, tick 51.2 in issue-51. This is the ONLY thing blocking analytics instrumentation (51.3/51.4 become two agent sessions after).
- Known device gates (unchanged): 77.15 in-car voice-command test · #61 SK sign-in + privacy label + security review · 59.1 device TTS (SK, AirPods) · 67-A interruption recovery · #50 ASC portal steps · #76/#72 paid generation runs at un-park.

---

## Q1 — #88 refresh reuse-grace (HIGH)

```
Fix issue #88 (HIGH): a lost /auth/refresh response permanently revokes the token family and silently signs a SIWA user out. Backend-only, apps/quiz-agent.

Read first: docs/issues/issue-88-refresh-lost-response-signout.md (incl. the 2026-07-07 Correction block — it overrides the original "return that successor" wording), apps/quiz-agent/app/auth/refresh.py, app/config.py, tests/test_auth_refresh.py, app/api/routes/auth.py (context only — do NOT change it; RefreshReuseDetected already maps to 401 and recovery returns a normal RotationResult).

Scope: only refresh.py + config.py + tests/test_auth_refresh.py. NO iOS change, NO db/models.py change, NO Alembic migration.

Build:
1. config.py: add refresh_retry_grace_seconds: int = 60 (+ REFRESH_RETRY_GRACE_SECONDS env override); thread into RefreshTokenStore via build_refresh_store (refresh.py:192-199) as a timedelta.
2. rotate() (refresh.py:131-189), inside the `if row.used_at is not None:` branch (:155-167), BEFORE revoking: SELECT ... FOR UPDATE the successor = same family_id, smallest issued_at strictly > row.issued_at (no-migration lookup; rotation stamps successor.issued_at == row.used_at).
3. GRACE path — only if ALL hold: successor exists, successor.used_at IS NULL, successor.revoked_at IS NULL, (now - row.used_at) <= grace. Then revoke the dangling successor (never delivered), mint a FRESH row from the presented row via _new_token_row (same family_id, same family-deadline clamp as :172-181), return RotationResult(refresh=issued, anon_id=row.anon_id). Raw tokens are hash-only-stored — the existing successor can NEVER be handed back.
4. REVOKE path unchanged for everything else (successor missing/used/revoked, or outside grace — this covers older-ancestor replay too): keep family-revoke + RefreshReuseDetected exactly as today.
5. Keep the whole decision under the existing with_for_update on the presented row (:143) + FOR UPDATE on the successor, so honest retry and attacker replay serialize.
6. Add 4 tests (style: db_sessionmaker fixture, manual timestamp manipulation as in test_family_absolute_age_cap_is_enforced), docstrings say WHY (lost-response recovery vs theft containment): (a) rotate A→B, discard B, replay A within grace → fresh pair, B revoked, family alive, subject unchanged; (b) replay A after successor used → family revoked; (c) ancestor replay after A→B→C → family revoked; (d) replay A outside grace → family revoked.

Risk to watch: the grace path must not become a theft bypass — a second replay of A must fail (grace successor check sees a revoked row).

Done = cd apps/quiz-agent && uv run --no-sync pytest tests/test_auth_refresh.py -v all green (existing reuse/rotation tests untouched and passing + 4 new). Then full backend suite, commit (fix(backend): #88 — ...), push, fly deploy (auth security = founder-delegated, autonomous; no migration, no new required secret). Tick #88 in docs/todo/TODO.md + docs/issues/INDEX.md + issue file Acceptance, and mark Q1 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q2 — #90 atomic quota enforcement

```
Fix issue #90: freemium monthly quota is check-then-write (TOCTOU) — concurrent starts at count 99 can exceed the 100/month cap. Backend-only, apps/quiz-agent.

Read first: docs/issues/issue-90-quota-toctou.md, app/usage/tracker.py (record_question :97-141 — today a bare unconditional upsert, no limit logic), app/api/routes/quiz.py (~:60-75, :147-148), app/quiz/flow.py (~:245, :285), tests/test_usage_tracker.py, tests/conftest.py.

Scope: make record_question the atomic, authoritative gate; check_limit stays as cheap UX pre-flight. Do NOT touch #89's grace path or #87's monthly-window/premium semantics (calendar-month sum of daily rows stays).

Build:
1. In record_question: add .returning(DailyUsage.questions_count) to the existing on_conflict_do_update upsert; read the new today-count in the same transaction.
2. Sum prior month days separately (rows strictly before today are not written concurrently — no extra locking).
3. total = prior_sum + new_today_count. If not premium and total > monthly limit: roll back (increment never lands) and signal rejection. NB: there is NO existing QuotaLimitError class (plan text is wrong) — the 429 quota_limit_reached response is an inline HTTPException/dict at both call sites; pick the smallest-diff contract (return None or a small tracker exception).
4. Update the call sites (quiz.py, flow.py) so a record_question rejection raises the same 429 quota_limit_reached shape already used; keep check_limit as-is for the common case.
5. Tests in tests/test_usage_tracker.py: (a) seed limit-1, fire 5 concurrent record_question via asyncio.gather with separate sessions from db_sessionmaker → exactly one succeeds, final sum == limit; (b) premium unaffected under concurrency; (c) existing #87 monthly-window tests pass unmodified.
6. If the error contract shape changed at all, run /verify-api against iOS Codable structs.

Done = cd apps/quiz-agent && uv run --no-sync pytest tests/test_usage_tracker.py -v green + full suite green. Commit, push, fly deploy (monetization enforcement = founder-delegated, autonomous; no migration/secret). Tick #90 in TODO/INDEX/issue Acceptance; mark Q2 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q3 — #91 auth low-severity sweep

```
Fix issue #91: six independent low-severity auth hardening items, one sweep, one commit per item. Read first: docs/issues/issue-91-auth-low-severity-bundle.md (item 4 was corrected 2026-07-07: quiz.py:142 is NOT a leak — only quiz.py:99, quiz.py:180, sessions.py:69 are).

Items (anchors verified 2026-07-07):
1. iOS AuthService.swift:390-393 generateRawNonce(): guard SecRandomCopyBytes == errSecSuccess, abort sign-in on failure (no all-zero nonce).
2. Backend GET /usage/{user_id} (app/api/routes/misc.py:65-73): derive subject from bearer (same pattern as identity.py's bearer derivation); path param only as legacy fallback gated on LEGACY_USER_ID_GRACE. Do NOT touch POST /usage/{user_id}/premium (admin-key-gated, out of scope).
3. hmac.compare_digest for both admin-key checks (misc.py:87, admin.py:45), matching apple.py:124's pattern; guard unset/None key before comparing.
4. sessions.py:69 + quiz.py:99 + quiz.py:180: generic 500 detail, log the real str(e) with exc_info. Leave quiz.py:142 alone.
5. /auth/apple 409-after-code-exchange (auth.py ~:348-349, :459-462): either move exchange_authorization_code after the merge-conflict check, or catch the 409 and return a recoverable error the client can retry with a fresh authorization (code is single-use, ~5-min window). Smallest change wins; record the choice in the commit message — this is the one item with real design judgment.
6. Bounded pruning of expired used attest_challenges + used/revoked refresh_tokens (app/auth/attest_challenge.py, refresh.py): inline delete-where-expired on write or reuse an existing background-task pattern — no new scheduler infra.

Tests: extend targeted pytest for items 2-6 alongside each fix; item 1 rides existing AuthService tests (add one if none asserts nonce failure).

Done = cd apps/quiz-agent && uv run --no-sync pytest tests/ -v all green; grep confirms no str(e) in 500 details of sessions.py/quiz.py and compare_digest in both admin checks; targeted iOS auth suite builds+passes (not full HangsTests). Commit per item, push, fly deploy (autonomous; no migration/secret). iOS part ships with next TestFlight, not this session. Tick #91 in TODO/INDEX/issue; mark Q3 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q4 — #89 null-subject grace guard (latent)

```
Fix issue #89 (LATENT hardening — grace is already OFF in prod, see the 2026-07-07 correction in the issue): while LEGACY_USER_ID_GRACE=on, a request with no bearer AND no user_id yields subject None → every quota gate skipped. Backend-only.

Read first: docs/issues/issue-89-grace-null-subject-quota-bypass.md (incl. the Decision block: REJECT, don't mint), app/auth/identity.py (:94-123 resolve_session_subject, :126-137 grace warning), app/api/routes/sessions.py (:44-50), tests/test_auth_identity.py.

Scope: grace no-bearer path only. Do NOT touch the bearer path, grace-off path, require_bearer_or_grace (sync sibling), or anything from #90/#91.

Build:
1. identity.py resolve_session_subject: when grace is on and body_user_id is falsy → raise HTTPException(401, same detail string as the grace-off branch at :117). No grace-passthrough log for this case (nothing legitimate to log).
2. Verify _log_grace_passthrough still fires for the surviving legacy case (truthy user_id).
3. sessions.py create_session: defensive fail-loud guard — if subject.subject_id is None, raise before session_manager.create_session (unreachable after fix #1; protects the invariant).
4. Tests in test_auth_identity.py (reuse existing grace fixtures): grace ON + no bearer + no user_id → 401, no session; grace ON + no bearer + valid user_id → unchanged (session created, legacy registered, WARNING fires). Plus one null-subject-cannot-reach-questions guard test if none exists.

Done = cd apps/quiz-agent && uv run --no-sync pytest tests/test_auth_identity.py tests/test_require_auth.py -v green + full suite green. Commit, push, fly deploy (autonomous). Tick #89 in TODO/INDEX/issue Acceptance; mark Q4 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q5 — #79 typed×voice double-submission race (iOS)

```
Fix issue #79: typed-answer submission racing a committed voice transcript can double-submit and leave a stale confirmation sheet. iOS-only. NB: the plan's line anchors are stale — use these verified ones (2026-07-07).

Read first: docs/issues/issue-79-typed-answer-voice-race.md, QuizViewModel.swift (resubmitAnswer :706-752, transition() :299-330, isProcessingResponse guard :954-959), QuizViewModel+Recording.swift (handleCommittedTranscript :181-235 — its :182 quizState guard runs before the first await and does NOT close the race; confirmAnswer :456-474, cancelProcessing :531-549), QuestionView.swift (submitTypedAnswer :544-550, counterString :138-141), ResultView.swift (counterString :288-290), docs/design/ui-proposals-2026-07-decisions.md decision 12 (preserve tap-to-edit).

Scope: submission race + counter display only. Do NOT touch AudioService.interruptionTeardown, STT connect/reconnect, or MCQTranscriptMatcher.

Build:
1. Add submissionEpoch: Int to QuizViewModel, incremented at the start of every answer-submission entry point (resubmitAnswer first).
2. handleCommittedTranscript: snapshot epoch at entry, re-check after EVERY await suspension (sttService disconnect, before MCQ-submit/showAnswerConfirmation branches); bail silently if changed.
3. resubmitAnswer: set showAnswerConfirmation = false + clear transcribedAnswer/pending state (mirror cancelProcessing) before proceeding — no stale sheet.
4. Honor transition(to:)'s Bool return at the race-relevant call sites — bail on rejected transition instead of proceeding.
5. Unify QuestionView vs ResultView counterString convention (one convention, adjust snapshots only if the display value is the intended fix).
6. Tests in HangsTests/QuizViewModelTests.swift: gated-mock interleaving (handleCommittedTranscript suspended at disconnect await, resubmitAnswer runs, resume → exactly one submission, sheet false) + rejected-transition bail test.

Done = xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' green incl. new tests; tap-to-edit flow untouched (grep + existing tests). Commit, push. Recommended (non-gating): quick sim click-through of the confirmation sheet tap-to-edit via ios-ui-driver. Tick #79 in TODO/INDEX/issue; mark Q5 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q6 — #75.6 `/prepare-issue` end-to-end dry-run

```
Run issue #75 task 75.6: first live end-to-end exercise of the /prepare-issue orchestrator + /split-issue's untested large-issue branch. Docs + .claude/skills only — NO app runtime code.

Read first: docs/issues/issue-75-prep-orchestrator.md, docs/issues/issue-78-apple-signin-name-lost.md (the guinea pig), .claude/skills/prepare-issue/SKILL.md, .claude/skills/design-soundness/SKILL.md, .claude/skills/split-issue/SKILL.md, .claude/skills/ready-check/SKILL.md, docs/issues/issue-61-execution-prompts.md (canonical split template).

Build:
1. Run /prepare-issue 78 to completion. If it pauses on a genuine product question, answer with #78's own recommended default and note the assumption. IMPORTANT: prepare only — do NOT implement #78's code fix (that's a separate session).
2. Verify the resulting issue-78 file: refreshed ## Prep progress, BOTH P3+P5 gate verdicts (/ready-check + /design-soundness) recorded, populated atomic ## Tasks + machine-evaluable ## Acceptance, correct final **Triage:** state.
3. Separately force /split-issue's LARGE-issue branch: run it standalone against a clearly multi-task ready issue (issue-61's own plan is a safe regression check — diff the generated execution-prompts.md structurally against the canonical issue-61-execution-prompts.md section order).
4. Fix any skill-prompt bugs either run surfaces (broken composition refs, malformed template, gate loop not looping, class-guard not firing) — only .claude/skills/*/SKILL.md edits allowed.
5. Update issue-75: tick 75.6, dated note of findings/fixes; update INDEX #75 row + TODO #75 line (issue → done if 75.6 was the last item).

Done = 75.6 [x]; issue-78 carries recorded P3/P5 verdicts + a non-needs-triage Triage state; the large-issue split output structurally matches the issue-61 template; INDEX+TODO reflect it. Commit, push. Mark Q6 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q7 — #78 Apple Sign-In name loss

```
Fix issue #78 (root cause verified 2026-07-07): /auth/apple response omits full_name/email AND iOS unconditionally overwrites the stored accountName — so any re-sign-in (Apple sends the name only on FIRST authorization) wipes the displayed name. If Q6 ran /prepare-issue on #78, read its refreshed plan first and prefer its task list where it differs.

Read first: docs/issues/issue-78-apple-signin-name-lost.md, app/api/deps.py (AuthTokenResponse ~:212), app/api/routes/auth.py (apple_sign_in :273-361; return block :355-361), AuthService.swift (completeAppleSignIn :370-490; AuthTokens :35-95; construction site :469-476), SettingsView.swift (:369 name display), HangsTests/AppleAuthTests.swift.

Scope: additive optional fields + nil-safe merge. Do NOT touch anon-bootstrap/refresh response shape beyond the new OPTIONAL fields; do NOT touch checkAppleCredentialState's drop-to-anon (:496-518) — intentional identity reset, not this bug.

Build:
1. Backend: add optional full_name + email to AuthTokenResponse; populate in /auth/apple from the upserted user row (NOT the request's possibly-nil values). Backend already stores the name correctly on first auth — no store change.
2. Verify openapi.json, then add matching optional fields to iOS TokenResponse + CodingKeys; run /verify-api.
3. completeAppleSignIn merge: prefer non-nil live credential fullName/email, else server full_name/email, else existing store.load() values — a non-nil stored value must never become nil.
4. Test in AppleAuthTests: stored accountName set + completeAppleSignIn(fullName: nil, server full_name: nil) → accountName still non-nil. Watch privacy: don't send email when Apple hides it (private relay).

Done = backend uv run --no-sync pytest tests/ -v green; iOS xcodebuild test Hangs-Local (iPhone 17 Pro) green incl. new test; /verify-api match. Commit, push, fly deploy (additive, autonomous). [HUMAN] follow-up stays: real Apple-ID sign-out/sign-in check on device. Tick #78; mark Q7 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q8 — #45 45.7-wire: MCQ select-then-confirm

```
Implement issue #45 task 45.7-wire: route BOTH the MCQ tap path and the MCQ voice-match path through select → existing AnswerConfirmationView/confirmAnswer() → ResultView, instead of immediate submit. iOS-only. Re-grep all anchors first if Q5 (#79 epoch guard) landed — it edits the same function.

Read first: docs/issues/issue-45-ios-mcq-voice-and-redesign.md (45.7 + D4), QuestionView.swift (:52-67 sheet wiring; mcqBody :288-344, onSelect ~:309-315), QuizViewModel+Recording.swift (handleCommittedTranscript MCQ branch ~:211-224; confirmAnswer/resubmitAnswer :440-473), QuizViewModel.swift (QuizState :22-30, transition table ~:299, mcqVoiceMatchedKey :369, submitMCQAnswer :682, showAnswerConfirmation/transcribedAnswer :131-132), Components/MCQOptionPicker.swift, HangsTests/QuizViewModelMCQVoiceTests.swift (all 5 tests assert the OLD immediate-submit contract), docs/testing/regression-scenarios.md (RS-09 ~:253-273, RS-10 ~:282-300 — same stale assumption).

Scope: do NOT touch ResultView, T/F 80pt sizing (45.10 done), or add a new submitMCQAnswer call site — reuse the existing transcribedAnswer/showAnswerConfirmation/confirmAnswer→resubmitAnswer→submitTextInput plumbing (backend _evaluate_mcq matches by key or value, D2 — no backend change).

Build:
1. QuestionView.mcqBody onSelect: no network call — set mcqVoiceMatchedKey (drives the selected highlight), transcribedAnswer = value, showAnswerConfirmation = true, start the auto-confirm countdown the same way the voice path does.
2. handleCommittedTranscript: remove the auto-submit-on-match branch; matched voice transcript goes through the SAME select-then-confirm path; unmatched falls through unchanged.
3. Confirm confirmAnswer()/resubmitAnswer() need no change; remove any MCQ-specific branch in them if found.
4. Rewrite the 5 QuizViewModelMCQVoiceTests to the new contract (select sets state WITHOUT submitTextInput; confirmAnswer submits exactly once) + a tap-selects-without-submitting inspector test.
5. Update RS-09 + RS-10 specs in regression-scenarios.md to select→confirm→processing.
6. Run RS-09 + RS-10 end-to-end via the ios-ui-driver subagent; write fresh docs/testing/runs/RS-09/RS-10-<date>.md reports (VERDICT/VISUAL lines) superseding 2026-06-17.

Risk: confirm path is shared by voice/text/MCQ — verify a non-MCQ scenario (e.g. RS-05-style voice flow) still passes, not just RS-09/10.

Done = xcodebuild test Hangs-Local -only-testing QuizViewModelMCQVoiceTests + QuizViewModelTests green; build green; RS-09 + RS-10 fresh PASS reports. One commit. [HUMAN] after: founder eyeballs select→confirm on sim (45.7-signoff). Tick 45.7-wire in issue-45; mark Q8 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q9 — #45 45.13: snapshot baselines re-record

```
Issue #45 task 45.13: re-record the QuestionView/MCQ snapshot baselines invalidated by 45.8/45.9/45.10 and Q8's 45.7-wire flow change. Runs AFTER Q8.

Read first: HangsTests/Snapshots/QuestionViewSnapshotTests.swift (+ its __Snapshots__ dir), issue-45 changelog entries for 45.5 + 45.13, Models/Evaluation.swift (check whether the 2026-06-07 headlineAnswer drift still exists).

Build:
1. Run the snapshot suite first to establish which baselines are red and WHY — capture the diff; don't assume it's still the June drift.
2. Re-record only baselines red from real #45 UI changes (45.7-wire select-state, no-big-mic, pill position, T/F height) using the project's .dump record convention; hand-diff each new baseline vs old — only the intended change may move.
3. Baselines red from unrelated pre-existing drift: do NOT silently re-record — note which issue owns them in the commit message.
4. One commit with a short what/why note.

Done = xcodebuild test Hangs-Local -only-testing:HangsTests/QuestionViewSnapshotTests green, every touched baseline diff-reviewed (rule 6: snapshots must still assert the meaningful structure). Tick 45.13; mark Q9 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q10 — #45 45.11: light/dark delta vs `.pen`

```
Issue #45 task 45.11: delta-check (NOT a full re-audit — #52.17c already covered the screens) the off-flow states #52.17c never triggered: AnswerOption correct/incorrect states + ListeningPill capsule fill/stroke, light + dark, vs design/quiz-agent.pen nodes EZhqr and vAXMX.

Read first: docs/todo/TODO.md #52 line (what 52.17c covered), Components/AnswerOption.swift (correct/incorrect states — component-level only, not in live MCQ flow per D4), Components/Hangs/ListeningPill.swift. Use pencil MCP (get_editor_state, export_nodes/get_screenshot) for the .pen side — never Read/Grep the .pen file.

Build:
1. Export/screenshot EZhqr + vAXMX in light and dark from the .pen.
2. Render AnswerOption's correct/incorrect states via its SwiftUI preview on the sim (they're unreachable in live flow), screenshot via ios-ui-driver; compare token-for-token (border, badge fill, SF Symbol) per state × mode.
3. Verify ListeningPill's fill/stroke on a rendered question screen vs vAXMX both modes.
4. Fix confirmed drift only (small color/asset diff); re-run AnswerOptionInspectorTests + ListeningPillInspectorTests.
5. Close 45.11 with a few-line note in the issue-45 changelog (what was checked, outcome) — no new doc.

Done = both inspector test suites green; documented light+dark comparison (match, or a specific fixed drift) in the changelog. Commit. Mark Q10 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q11 — #59 regression sim legs

```
Issue #59 close-out: RUN (don't code) the outstanding sim legs RS-11, RS-12, RS-13, RS-15, RS-16 via the /regression skill against Hangs-Local on iPhone 17 Pro sim. The RS specs were sanity-checked 2026-07-07: RS-12's geometry assert is layout-agnostic and survives #83's top-bar rework; all referenced a11y-ids still exist.

Read first: docs/issues/issue-59-quiz-flow-bug-cluster.md (Part B + Acceptance), docs/testing/regression-scenarios.md (:306-501), .claude/rules/ios.md (drive the sim ONLY through the ios-ui-driver subagent — never from the main session; never run full HangsTests via MCP).

Build:
1. /regression scoped to RS-11, RS-12, RS-13, RS-15, RS-16; follow each scenario's Steps/Asserts exactly.
2. One report per scenario → docs/testing/runs/RS-NN-2026-07-DD.md, matching the RS-01..RS-08 format.
3. On any FAIL: capture detail in the report and STOP — no production-code fixes in this session.
4. All pass → tick the sim-leg lines in issue-59 Acceptance + update the TODO #59 line so only [HUMAN] 59.1 (device TTS, SK + AirPods) remains.

Done = five new PASS reports (or documented FAILs) under docs/testing/runs/; issue-59 + TODO updated. Commit reports + doc updates, push. Mark Q11 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q12 — #56 localization reconcile + close-out

```
Issue #56 close-out (REALITY CHECK 2026-07-07, verified first-hand): the catalog work is ALREADY DONE on main — Localizable.xcstrings is committed and populated (274 keys, 268 comments; main carries its own 56.x commits incl. 29a5d4e = the 56.6 catalog-populate), and the #80-#87 views are already routed through it. origin/ralph/overnight-20260613-1034 (9 commits) is a REDUNDANT duplicate — do NOT merge it. Remaining work = reconcile the contradictory tracking docs + a formal 56.5 verification on current main. Text/catalog + docs only; no app logic.

Read first: docs/issues/issue-56-ios-localization.md (§56.5, §56.6, plural list ~:104-113), docs/todo/TODO.md — the #56 line AND the separate "Review + merge mba-only #56 localization work" line (they CONTRADICT each other — one says the branch doesn't exist, the other says merge it; both are wrong), apps/ios-app/Hangs/Hangs/Localizable.xcstrings, .claude/rules/ios.md (:47-48 test command, :62-64 localization guardrail).

Build:
1. Confirm redundancy first-hand: git log --oneline main | grep -iE "#56|localiz" (main's own 56.x commits) vs git log main..origin/ralph/overnight-20260613-1034 --oneline (9 duplicates). 
2. Fix BOTH TODO.md lines: branch exists but is SUPERSEDED (main landed equivalent 56.1-56.6 independently); nothing to merge. Do NOT delete the remote branch yourself — deleting a branch the founder deliberately kept as backup is a destructive git op: ask in-session (one AskUserQuestion) whether to git push origin --delete it, and only then.
3. Sweep apps/ios-app/Hangs/Hangs/Views for un-routed literals: .accessibilityLabel(" / .accessibilityHint(" not wrapped in String(localized:), Text(bareVariable). Expected residue: only ScoreCard.swift:34 + StatsCard.swift:40 (documented word-free %@: %@). Wrap anything else per the ios.md guardrail.
4. OPTIONAL (skip if time-boxed): author plural variations by hand-editing the xcstrings JSON for the count-bearing keys in issue :104-113 (en one/other) — the catalog has 0 today, so "1 free questions" renders wrong; low value with no live users.
5. Formal 56.5: full suite via CLI xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' (NEVER the MCP test_sim worker — it hangs on the full suite). Gate on the known-flaky band (SilenceDetectionService timing + pre-existing snapshot drift), not an exact count — the issue's "394/12" baseline is stale.
6. Update issue-56: tick 56.5 with the actual result; note 56.6-populate done (29a5d4e); remaining = [HUMAN] pseudo-localization visual smoke only. Update TODO #56 line to [~] with only that gate. Also refresh the issue's obsolete header ("no catalog yet, ~130-150 strings" — long false).

Done = zero NEW localization failures in the full-suite run; views sweep returns only the two documented lines; issue/TODO reconciled (the two contradictory lines fixed). Commit, push. [HUMAN] after: pseudo-loc smoke (Double-Length Pseudolanguage scheme option, every screen). Mark Q12 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q13 — #55 docs-drift commit pass

```
Issue #55 residual: commit the accumulated untracked docs drift and gitignore the Obsidian vault config. Docs-only.

Read first: docs/issues/issue-55-repo-structure-cleanup.md, .gitignore, and run git status first — reconcile against reality, earlier sessions may have committed parts of the drift already.

Scope: do NOT touch docs/artifacts/ (section D stays deliberately deferred), design/quiz-agent.pen (live pending Pencil edit tied to #52 — leave modified), or resurrect part D.

Build:
1. Inventory untracked files: docs/handoffs/*.md + docs/handoffs/archive/*, docs/testing/runs/RS-*.md, docs/research/*, docs/.obsidian/.
2. Add docs/.obsidian/ to .gitignore (local vault config, not project content).
3. git add the handoff/testing/research files explicitly by path (never git add -A); commit as docs: commit accumulated handoff/testing/research drift.
4. Update the #55 line in TODO.md + INDEX.md: commit pass done; D + .pen relocation remain deferred.

Done = git status shows no untracked files under docs/handoffs, docs/testing/runs, docs/research; docs/.obsidian gone from status; only expected entries remain (design/quiz-agent.pen modified). Push. Mark Q13 ✅ in docs/issues/execution-queue-2026-07.md.
```

## Q14 — #71 GitHub Issues mirror refresh

```
Issue #71 (reduced scope): refresh the stale GitHub Issues mirror. Run LAST so the board picks up all queue outcomes.

Read first: scripts/ralph/mirror-issues.sh, docs/issues/INDEX.md. Do NOT resurrect the struck Ralph scope (founder 2026-07-05: no autonomous loops).

Build:
1. gh auth status (script is best-effort but verify anyway).
2. Run scripts/ralph/mirror-issues.sh; verify created/updated/closed/skipped counts in output.
3. Spot-check the GitHub board shows current states (e.g. #70 closed, #88-#91 open with labels).
4. Tick #71 in TODO.md + INDEX.md (issue fully done — everything else was struck/resolved).

Done = script exits 0 with logged counts; board reflects current INDEX. Commit doc ticks, push. Mark Q14 ✅ in docs/issues/execution-queue-2026-07.md.
```

---

## Not in the queue (why)

- **#92 rename Hangs → Trubbo** — arrived mid-pass (2026-07-07) already session-split: 3 Opus prompts live inside [`issue-92-rename-trubbo.md`](issue-92-rename-trubbo.md) itself. Run its `[HUMAN]` ASC name-availability gate first. Its Session 1 touches 2 String Catalog keys — no real conflict with Q12, either order works.
- **#51** — blocked on the 5-min founder gate 51.2 (taxonomy already done). After the tick: 51.3 backend + 51.4 iOS become two normal sessions (re-grep the stale anchors in analytics-events.md first).
- **#70** — CLOSED 2026-07-07 on verification: already fixed by `649b1b9`.
- **#72 / #74 / #30 / #76 tail** — parked until the founder un-park (paid generation runs).
- **#63 / #62 / #50 / #48 / #64** — ready-for-human / deferred / umbrella; no agent session exists.
- **#77 / #67 / #61 tails** — `[HUMAN]` device gates only.

## Status

| Session | State |
|---|---|
| Q1 #88 | ⬜ |
| Q2 #90 | ✂️ struck 2026-07-11 — subsumed by #93 Session B |
| Q3 #91 | ⬜ |
| Q4 #89 | ⬜ |
| Q5 #79 | ⬜ |
| Q6 #75.6 | ⬜ |
| Q7 #78 | ⬜ |
| Q8 #45 45.7-wire | ⬜ |
| Q9 #45 45.13 | ⬜ |
| Q10 #45 45.11 | ⬜ |
| Q11 #59 RS legs | ⬜ |
| Q12 #56 | ⬜ |
| Q13 #55 | ⬜ |
| Q14 #71 | ⬜ |
