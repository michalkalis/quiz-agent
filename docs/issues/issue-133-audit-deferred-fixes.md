# Issue #133 — Audit 2026-07-30: deferred fixes + test debt

**Triage:** DONE (agent run 2026-07-30 on mba, branch i133 → main; close-out block at end of file)

**Founder decisions (2026-07-30, in-chat):**
- 1b precedence: **option-text match wins**; positional/letter directives apply only when no unique value match exists.
- 1e migration: run may implement + commit the Alembic migration and fix, but must **NOT deploy quiz-pack-api** — deploy waits for founder OK (migrate-before-deploy gate).
- iOS snapshot baselines: **do not re-record** — founder sign-off required (ios.md rule); park that item.
**Source:** [Adversarial multi-agent audit 2026-07-30](../research/adversarial-audit-2026-07-30.md) — 21 confirmed findings; 13 fixed in-session, these 5 + test debt remain. All 5 were adversarially verified (confirmed real); they are deferred because they are product-behavior-sensitive or need a cross-service API change, not because they are doubtful.

## 1. Deferred confirmed defects (iOS + one cross-service design)

### 1a. Structural: question-scoped idempotent answer submit (covers two findings)

Three independent findings share one root cause: the answer-submit API is not question-scoped and not idempotent, while clients retry/re-submit.

- `apps/ios-app/Hangs/Hangs/Utilities/TransientRetry.swift:37` — `isTransient` retries `timedOut`/`networkConnectionLost` around three non-idempotent submit calls, violating the file's own contract ("only failures that PROVE the request never reached application code"). Tunnel scenario: server processed, response lost → retry double-counts quota and answers the *next* question.
- `apps/ios-app/Hangs/Hangs/ViewModels/RecordingCoordinator+Confirmation.swift:56` — editing a Whisper transcript throws away the completed evaluation (`pendingResponse = nil`) and re-POSTs the text to a session the server already advanced → graded against the next unseen question, second quota unit burned. Same hazard from the 30 s client timeout vs 120 s request timeout.

**Fix direction (structural, not patches):** client sends the evaluated `question_id` with every voice/text submit; backend rejects-or-replays a submission whose `question_id != current_question_id` (server-side per-session lock landed in-session; this completes it). Then `TransientRetry` may keep its retry classes, and the edit flow either becomes re-record-only or uses an explicit re-evaluate endpoint. API change → `/verify-api` + iOS Codable sync required.

### 1b. `apps/ios-app/Hangs/Hangs/Utilities/MCQTranscriptMatcher.swift:46` — number words beat option-text match

Tier-1 positional scan (`numberWords`) short-circuits before the Tier-2 value match, so speaking the answer TEXT "štyri" on a numeric-options question submits option 4's value via the no-confirmation MCQ fast path. Fix: unique exact/contained value match first; positional/letter directives only when no unique value match. Product check with founder: desired precedence when an utterance is *both* a number answer and a position ("dva" with options containing "Dva").

### 1c. `apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService+Engine.swift:29` — startListening re-entrancy

`audioEngine == nil` guard is not re-entrancy-safe across the `bestAvailableAudioFormat` suspension → orphaned SpeechAnalyzer + a second AVAudioEngine deallocated under a running one. Fix: single-flight guard around the whole async start (state flag set before first await). Verifier confidence medium — re-verify the interleave on current code before fixing.

### 1d. `apps/ios-app/Hangs/Hangs/ViewModels/EntitlementReconciler.swift:137` — post-sync usage check joins pre-sync fetch

`refreshUsage()` single-flight joins an in-flight pre-sync `/usage` request, so `notifyPremiumPurchased()`/restore report "nothing to restore" after a *successful* recovery (re-introduces #102 finding 3 for pack buyers on cold Fly starts). Fix: force/epoch mode — post-sync callers must issue a fetch that *starts after* the sync. Verifier confidence medium.

### 1e. quiz-pack-api sweep: pending-branch double-enqueue window (needs migration → founder gate)

The in_progress branch was fixed in-session (`updated_at` onupdate + deterministic arq `_job_id`), but the **pending** branch measures `GenerationOrder.created_at` — ancient for any requeued order — so a sweep tick landing in the ~50 ms between "park at pending" and "enqueue" can still double-enqueue. Clean fix = order-level `enqueued_at` column → **Alembic migration (founder-gated)**. Deliberately not hacked around in-session.

## 2. Test debt (from the 5-auditor test-quality review; worst first) — ALL DONE 2026-07-30

**quiz-pack-api money path:**
- [x] Un-xfail `tests/worker/test_process_order.py` + fix `test_order_e2e_full` standalone (root cause = TWO unmigrated DBs) + de-fragile sweep tests → `5bb57095` (full suite 728×2 identical, later 739).
- [x] Route-level StoreKit authorization tests (tampered → 401, wrong bundle → 403 — spec matched, no app change) + `verify_jws_cached` unit tests incl. poisoned-cache guard → `5bb57095`.

**quiz-agent evaluation (the #2 defect class):**
- [x] 15 MCQ evaluator tests rewired onto production `_evaluate_mcq`/shared `normalize_text`, local copies deleted, mutation-checked → `65c2a3d5`.
- [x] Partial-credit weights pinned to the production score_map (incl. off-table→0.0 default + MCQ no-partial-credit rule); `TestEvaluationQuestionId` self-asserting dicts → real flows; `test_translation_validation` inverted asserts fixed with literal expected values → `65c2a3d5`.
- [x] `REQUIRE_DB_TESTS=1` now actually gates all 4 self-skipping DB suites (one shared conftest helper; CI had the env set but it was silently ineffective); `test_question_monitor` isolated onto per-test scratch DBs → `65c2a3d5`.

**iOS — why main CI was red (run 30540373427: 886/896, 10 fail):** RESOLVED —
- [x] 6 stale `.stableDump` baselines: RETIRED via the sanctioned snapshot-layer replacement below (not re-recorded; the founder decision parked re-recording, and the layer replacement supersedes it — per-baseline replacement table in `7099abdc` + the run report for founder review in lieu of sign-off).
- [x] 4 wall-clock-flaky usage/entitlement retry tests: deterministic sleep seams + schedule assertions (`backoff.delays == [0.2, 0.4]`), the traced `foregroundReconciles` wait-for-unwind fix, plus a LATENT vacuous pass exposed and fixed → `21445cd0`. Full HangsTests target 912×2 green in ~29 s.

**iOS:**
- [x] Snapshot layer replaced: 8 VM-dump baselines → `ScreenStateContractTests` (ViewInspector, Verification-Altitude asserts); swift-snapshot-testing dep dropped; template stubs deleted — `HangsUITestsLaunchTests` turned out to be the ROOT CAUSE of the `testRSPackNavStart` order-dependency (rotated the sim landscape) → `7099abdc`.
- [x] RS-correct now asserts the verdict surface ("NAILED IT." via `result.verdict`) → `21445cd0`.
- [x] Tautological suites culled (`AudioFixtureTests`, `MockAudioServiceContractTests`, palette constant-vs-self in 4 files; real binding coverage already lives in the pixel/resolution suites) → `7099abdc`. `MockAudioServiceInterruptionTests` left = next-pass candidate.
- [x] Named gaps covered: illegal-transition rejection (+side-effect suppression), `KeychainTokenStore` first tests (incl. swallow contract + self-repair), quota→paywall→purchase→restored money loop wired as AppState wires it → `21445cd0`.

## 3. Unverified findings triage (35 raw, NOT yet adversarially verified — verify before acting)

Notable clusters (full list: audit research doc + workflow journal):
- **Money/entitlement:** StoreKit verifier never checks revocation (`verifier.py:151`); RC TRANSFER events dropped (`rc_service.py:404`); pack-credit double-grant on missing transaction_id (`rc_service.py:300`); order idempotency SELECT-then-INSERT race 500s (`orders.py:230`); verified purchase with unmapped product_id leaves no record (`orders.py:219`); paid STT/TTS endpoints unmetered (`voice.py:29`).
- **Data/contract:** `headline_answer` allegedly has NO storage column (two independent finders: `db/models/question.py:152`, `pgvector_client.py:324`) → deferred-reveal recap payload would be empty; `PublicQuestion` ships `headline_answer` pre-answer (`question.py:516`); `evaluation.user_answer` JSON null vs iOS decoding (`flow.py:164`).
- **Caching/translation:** `translate_feedback` durably caches unvalidated LLM output (`translator.py:494`); skipped-feedback hardcoded English (`feedback_messages.py:178`).
- **Flagged during the in-session preference_change fix:** a `preference_change` intent arriving *alone* (no answer in the same utterance) is parsed correctly but then discarded — the ghost-question guard returns before `update_session`. Fix alongside 1a's flow work.
- **iOS audio/flow:** overlapping `playOpusAudio` orphans continuation → countdown never armed (`AudioService.swift:1068`); no config-change observer kills mid-answer mic (`AudioService.swift:425`); `rerecordAnswer` doesn't cancel in-flight submit (`+Confirmation.swift:91`); "Play Again" bypasses beginQuizStart (`CompletionView.swift:177`); PackOrderService never refreshes expired bearer (`PackOrderService.swift:151`).
- **Flagged during the in-session AuthService fix:** Apple credential *revocation* → `dropToFreshAnon()` still re-aliases RevenueCat to the fresh anon (same subscription-hiding effect the fixed refresh-rejection path had) — related to the `AuthService.swift:735` single-flight finding above; assess together.
- **Generation:** MCQ paths never set `question_type` so MCQ gold bias never activates (`generation.py:221`); TopUp round has no error isolation (`topup.py:78`); best-of-N critique KeyError can kill a paid order (`advanced_generator.py:464`).

Suggested next step: one verification pass (same adversarial-verifier pattern) over the money/entitlement + headline_answer clusters, then fix what survives.

## Run log — 2026-07-30 agent run (branch i133; interim, finalized at run end)

**Section 1:** 1a ✅ COMPLETE — backend `ea7fd286` + iOS `dec4fe8a` (question_id on all 4 submit paths, 409 → "Quiz out of sync"/goHome, /verify-api PASS; lone preference_change persists — HTTP still 400, status flip = founder call) · 1b ✅ `1eb554e0` (value-first + word↔digit bridge) · 1c ✅ `39706c71` (single-flight startListening) · 1d ✅ `c081a21d` (refreshUsage(force:), red-pre-fix proven) · 1e ✅ `3f5e488e` (migration `a3f7c81d92be` committed, NOT deployed — founder gate).

**Later commits:** V2+V3 ✅ `51d1f69e` (RC TRANSFER handled, NULL-txn grant blocked) · §2 pack-api test debt ✅ `5bb57095` (728×2 identical) · V6 ✅ `05ac6df3`+`2637261a` (dead /voice/transcribe deleted; re-grade cap 3 + replay-on-cap; /tts/synthesize + /elevenlabs/token LIVE, anon-under-grace = founder decision) · V9 ✅ `2637261a` (null user_answer coerced + parser 500 guard) · structural: flow.py 751→565 + app/quiz/resubmission.py (further cuts = follow-up: audio/TTS group ~85 lines, non-answer intents ~45).

**Section 3 verdicts (adversarial, on current code):**
- V1 verifier revocation: CONFIRMED — full fix needs App Store Server Notifications v2 (ASC console config = founder) → deferred with design; cheap revocationDate/Reason check in verify() planned this run.
- V2 RC TRANSFER dropped: CONFIRMED — fix in progress. V3 NULL-txn double-grant: CONFIRMED — fix in progress (sync-path-mirror guard, no migration; partial-unique-index alternative noted).
- V4 idempotency race → 500: CONFIRMED empirically (live 2-request probe; loser 500s, winner + enqueue correct = support noise, self-healing) → fix queued (catch IntegrityError → re-SELECT → 200; regression test must use per-request sessions — shared-session test client masks it). V5 unmapped product_id after verification: CONFIRMED empirically — stronger than claimed: zero log/Sentry/access-line for a charged transaction (same blind window covers the :227 guards' 422) → fix queued (explicit log+Sentry trail on the whole post-verification reject window; "record-first rejected-order row" boundary = follow-up design note, retry-lifecycle semantics deserve design). V6/V9 (STT/TTS metering, user_answer null): verification running.
- V7 headline_answer never persisted: CONFIRMED (milder than claimed — gist→correct_answer fallback masks it; real loss when both fields emitted). V8 PublicQuestion pre-answer leak: CONFIRMED-unreachable (moot only BECAUSE of V7). Must land together, V8-strip first. Fix queued behind pack-api test-debt task.
- V10 unvalidated feedback-translation cache: CONFIRMED → ✅ `1ba3e10a`. V11 skip-path English: REFUTED as stated; narrow template gap → ✅ `a6063cc5`.
- V12 playOpusAudio orphaned continuation: CONFIRMED (narrower window) → fix queued. V13 route-change observer missing: REFUTED (observer exists, self-healing ≤15 s; in-place engine recovery = optional hardening, not done).
- V14 rerecord vs in-flight submit: CONFIRMED-partial (stale sheet + auto-confirm can grade rejected answer) → fix queued. V15 Play Again bypasses beginQuizStart: REFUTED (it initializes nothing); real residual = untracked Task races resetToHome (TTS on Home) → 1-line fix queued.
- V16 PackOrderService no 401-refresh: CONFIRMED → fix queued. V17 revocation re-alias hides subscription: CONFIRMED (refresh-rejection sibling was fixed, revocation path wasn't) → fix queued; signOut same pattern = founder call, not touched.
- V18 MCQ gold bias dormant: CONFIRMED → ✅ `4aecde7b`. V19 TopUp isolation: REFUTED (fail-loud is by design; latent ctx.questions restore noted, inert). V20 critique KeyError kills order: REFUTED (fully guarded, .get()-based).
- V21 lone preference_change discarded: CONFIRMED first-hand → ✅ in `ea7fd286`.

**Section 2:** quiz-pack-api ✅ `5bb57095` · quiz-agent eval ✅ `65c2a3d5` (REQUIRE_DB_TESTS=1 was silently ineffective for 4 suites — closed) · iOS part 1 (snapshot-layer replacement + tautology culls) running, part 2 (clock injection + named gaps) queued.

**All section-3 fixes now committed:** V1-partial `8b208b60` · V4+V5 `8aeedf47` · V7 `8aa4364a` · V8 `34cae6b6` · V12 `4d055ec3` · V14 `b58f847f` · V15-residual `05a4394d` · V16+V17 `bd941a2c`. Branch pushed to origin/i133 at `8aa4364a` checkpoint.

## CLOSE-OUT — 2026-07-30 (final)

**Section 1: 5/5 ✅** (1a backend+iOS+/verify-api; 1b; 1c; 1d; 1e committed-not-deployed). **Section 2: 11/11 ✅** (checkboxes above). **Section 3: 21/21 triaged** — 16 confirmed→fixed (V1 partial, V2, V3, V4, V5, V6, V7, V8, V9, V10, V12, V14, V16, V17, V18, V21) · 5 refuted with evidence (V11-as-stated→narrow gap fixed, V13, V15-as-stated→residual fixed, V19, V20). Every fix red-proven or mutation-checked where feasible.

**End gates (all green):** quiz-agent 605 passed (REQUIRE_DB_TESTS=1) · quiz-pack-api 739 passed + 1 pre-existing skip (LLM_GATEWAY=direct, re-runnable ×2) · iOS full HangsTests target 912 passed ×2 (~29 s; was 886/896 + minutes of sleeps on main) · HangsUITests build-for-testing clean (RS runs are on-demand sim-driving, not a CI gate).

**Founder decisions / gates left open (in priority order):**
1. ✅ **DONE 2026-07-31 (founder-approved in-chat):** both migrations applied to prod `quiz_pack`, staging `quiz_pack_staging`, and the local dev `quiz_pack_test`; quiz-pack-api deployed (health 200); pgvector column shim deleted (`55ff2cc4`) and quiz-agent prod redeployed (health 200).
2. ✅ **Code DONE 2026-07-31 — two founder actions left.** Full StoreKit revocation pipeline shipped in quiz-pack-api: `POST /v1/appstore/notifications` (App Store Server Notifications V2 consumer, auth = the Apple JWS signature + bundle match, no key), `revoked_transactions` table (migration `e3c81b0a7f45`, additive), every purchase-authorising call site now awaits `storekit.revocation.assert_not_revoked`, and the jws_cache 60 s local-decode window is closed (revocation is checked per call against the DB on both cache branches, never cached). Founder actions: **(a)** App Store Connect → App Information → App Store Server Notifications V2 URL = `https://quiz-pack-api.fly.dev/v1/appstore/notifications` (set the Sandbox URL too — this deploy serves Sandbox); **(b)** ~~apply the migration~~ ✅ DONE 2026-07-31: `e3c81b0a7f45` applied to prod + staging + local test DB, quiz-pack-api deployed (health 200). Only (a) the ASC URL remains — delegated to a founder-side Claude browser session 2026-07-31. Known limit, by design: a REFUND on a *subscription* revokes nothing here (that entitlement lives in quiz-agent via RevenueCat, which gets its own refund webhook) — it is recorded, denied forever at this service, and reported to Sentry for reconciliation.
3. ✅ **DONE 2026-07-31 (founder OK'd in-chat — sole user, breakage acceptable):** `LEGACY_USER_ID_GRACE=off` set on prod quiz-agent-api; health 200, anon POST /tts/synthesize now 401. — Anon reachability of `/tts/synthesize` + `/elevenlabs/token` during the legacy grace window** (V6 residual): flip `LEGACY_USER_ID_GRACE` off once installed clients are confirmed bearer-clean.
4. ✅ **RESOLVED 2026-07-31 by REMOVAL (founder decision):** the in-quiz voice preference_change intent is out of MVP scope — parser + flow handling removed (`9de9db69`); session preference fields kept (read by retrieval/API).
5. ✅ **DONE 2026-07-31 (founder decision):** signOut releases the RC identity before re-linking the fresh anon id (`df6f622c`) — subscription stays with the signed-out account, no stale premium UI, post-sign-out purchases still map (#96 P1 window closed). On-device check: sign out → free plan immediately; sign back in → premium without Restore.
6. **Snapshot replacement review:** the 6 stale baselines were retired by the sanctioned layer replacement, not re-recorded — review the per-baseline table in `7099abdc` if you want to veto any encoded UI state.

**Non-decision follow-ups (hygiene, filed for visibility):** NetworkService's private sendAuthorized = dedupe candidate vs the new protocol-default · V14 failure/error completion branches still ungated (guard convention exists) · flow.py 565 lines — next honest cuts = audio/TTS group + non-answer intents · V19 latent `ctx.questions` restore in TopUp finally · record-first rejected-order lifecycle (V5 note) · orphaned audio fixture resources in HangsTests/Resources · vacuous `isDisabled()` pattern in pre-existing `PaywallViewInspectorTests.idleRendersSubscribeCTA`.

**Deploys this run:** quiz-agent → **prod deployed + verified** (health 200, docs up; code-only, no migration; V8 strip + pgvector shim make any deploy order safe). quiz-agent **staging NOT deployed** — mba's fly keyring auth is gone and `.env` FLY_API_TOKEN is scoped to the prod app only (staging → unauthorized). Founder fix, either: (1) on mba run `flyctl auth login`, then `cd ~/code/quiz-agent && fly deploy -c apps/quiz-agent/fly.staging.toml`; or (2) mint a staging deploy token (`fly tokens create deploy -a quiz-agent-api-staging`) and add it to `.env` as a second var. quiz-pack-api → NOT deployed (gate above). No TestFlight build (per policy).

**2026-07-31 addendum:** quiz-agent staging deployed from laptop (health 200) and a staging deploy token installed on mba `.env` as `FLY_API_TOKEN_STAGING` — the staging fly-auth blocker is gone. mba i133 worktree/branch cleaned up, mba on main.
