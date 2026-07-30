# Issue #133 — Audit 2026-07-30: deferred fixes + test debt

**Triage:** ready-for-prep
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

## 2. Test debt (from the 5-auditor test-quality review; worst first)

**quiz-pack-api money path:**
- [ ] Un-xfail `tests/worker/test_process_order.py` (3 non-strict xfail tests = the real `process_order` state machine has NO passing test) and fix `test_order_e2e_full` failing deterministically under in-dir runs; de-fragile the sweep tests (global call-list asserts on a whole-table scan).
- [ ] Route-level StoreKit authorization tests: POST /v1/orders with invalid/tampered JWS → 401, wrong bundle → 403; direct tests for `app/storekit/jws_cache.py::verify_jws_cached` (zero today).

**quiz-agent evaluation (the #2 defect class):**
- [ ] Rewire the 15 MCQ evaluator tests off the test-local `_evaluate_mcq`/`normalize_text` copies onto the production method (they currently survive deleting the real code).
- [ ] Assert partial-credit weights (0.5 / 0.25) somewhere; fix the two self-asserting dict tests in `test_session_manager.py::TestEvaluationQuestionId` and the inverted/self-recomputing assertions in `test_translation_validation.py`.
- [ ] Make the 4 DB suites that roll their own `pytest.skip` honor `REQUIRE_DB_TESTS=1` (`test_pgvector_store.py`, `test_question_monitor.py`, `db/test_pack_ownership.py`, `test_alembic_migration_drift.py`); isolate `test_question_monitor.py` from ambient table content.

**iOS — why main CI is red (state 2026-07-30, run 30540373427: 886/896 pass, 10 fail, none from the audit):**
- [ ] 6 stale `.stableDump` snapshot baselines (Home idle/stats, QuestionView asking/recording, ResultView NAILED/MISSED/SKIPPED) from the 2026-07-28/29 UI commits — byte-identical with today's changes stashed. **Founder re-record sign-off needed** (ios.md: re-record signal, never silently fix). Note: xcpretty swallows Swift Testing failures, so CI logs showed only the UI-test failure — use the xcresult artifact.
- [ ] 4 wall-clock-flaky usage/entitlement retry tests (usageLoadState .failed/.recovery/backoff) — the known EntitlementReconcile flaky suite (green in isolation, documented 2026-07-28). Deterministic clock injection belongs with the flaky-test cleanup below.

**iOS:**
- [ ] Snapshot layer replacement: all 8 baselines are `.dump`/`.stableDump` view-model property dumps — zero rendered-view coverage, pure false confidence + the recorded "breaks on every new @Published" pain. Replace with ViewInspector assertions (the layer that already works) or real image snapshots; delete `HangsUITests/HangsUITests.swift::testExample` and `HangsUITestsLaunchTests` (template stubs, assert nothing).
- [ ] RS-correct regression scenario is verdict-blind (asserts only `result.continue` exists) — assert the verdict; nothing anywhere asserts a CORRECT answer renders the correct verdict end-to-end.
- [ ] Tautological suites to cull or repoint: `AudioFixtureTests` (no production code), `MockAudioServiceContractTests` (asserts the mock), palette-constant "color" tests in 4 files (compare constants to themselves, not token→view binding).
- [ ] Named gaps: `QuizViewModel.transition` illegal-transition rejection; `KeychainTokenStore` (zero tests, swallows errors); quota-exhausted → paywall → purchase → restored loop.

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
