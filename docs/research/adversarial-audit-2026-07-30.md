# Adversarial Multi-Agent Audit — 2026-07-30

**Method:** 40-agent workflow: 9 adversarial finders (per app/area), 5 test-quality auditors, 2 mutation probes (isolated worktrees, 8 deliberate semantic bugs each, measured against the real suites), 24 adversarial verifiers (one skeptic per finding, instructed to refute). Raw findings: 59 → 24 verified → **21 confirmed, 3 refuted**. 35 lower-severity findings left unverified (appendix). The 2026-07-30 question-generation deep review's known findings were excluded by prompt.

**Disposition:** 13 confirmed findings fixed in-session (commits on main); 5 iOS findings + test-debt deferred to [issue #133 — audit deferred fixes + test debt](../issues/issue-133-audit-deferred-fixes.md); 35 unverified findings queued there for triage.

## Confirmed findings (21)

| # | Where | Finding | Sev (verified) | Disposition |
|---|-------|---------|-----|-------------|
| 1 | ios `ElevenLabsSTTService.swift:50` | App-lifetime shared STT `AsyncStream` permanently killed by any consumer cancellation (feedback-sheet stop, backgrounding, watchdog) → all voice answers dead until app restart; 3rd failure auto-skips questions against quota. Same bug class as #77 StreamChannel P0; this service was never converted. | **critical** | fixed |
| 2 | backend `evaluator.py:223` | LLM verdict fallback: "incorrect" contains "correct" → any punctuated/prose negative verdict scored as correct (1.0). Parsing ladder had zero tests. | medium | fixed |
| 3 | backend `account_service.py:195` | GDPR delete carries only *today's* usage onto the device anon; quota is calendar-month → delete+re-signin = fresh 30 (30/month becomes 30/day). Guard predates #87 monthly model. | medium | fixed |
| 4 | backend `fly.toml:20` | `translations.db` + `ratings.db` live on container-local `/app/data`, not the `/data` volume → ratings/calibration data + persisted sessions wiped every deploy; opus-5 translation cache re-paid every deploy. Confirmed on live prod machine. | high | fixed |
| 5 | qp `fact_verifier.py:311` (+`logical_verifier.py:104,134`) | Judge failure (429/timeout/non-JSON) returns confidence 0.3 with `held_for_review=False` → transient error silently deletes the question, violating the module's own RC-9 hold policy. Logical verifier deletes every lateral puzzle on judge failure. | medium | fixed |
| 6 | qp `examples.py:32` | Deployed image ships no `data/examples` → gold-standard + anti-pattern injection silently dead in prod/staging; hardcoded fallbacks teach *banned* shapes (imperial units, language-dependent wordplay). | medium | fixed |
| 7 | qp `sweep.py:70` | Stuck-order sweep matches freshly re-queued orders (`queued` not excluded, `updated_at` stale by design, no arq `_job_id` dedup) → double paid pipeline for one order. | medium | fixed |
| 8 | backend `flow.py:396` | English MCQ sessions announce the bare option letter ("b") as the correct answer — 19/31 approved prod questions affected. Key→text helper existed but was wired only into the translation path. | high | fixed |
| 9 | shared `sync_pgvector_store.py:60` | Question retrieval blocks the event loop on a synchronous OpenAI embedding HTTP call at 4 hot-path call sites (`voice.py` already had the `to_thread` fix; the others didn't). | medium | fixed (call sites) |
| 10 | backend `flow.py:329` | TTS prefetch hashes the un-normalized stem; the audio route hashes the number-normalized stem → cache never hit for digit-containing sk/cs questions; double ElevenLabs spend + cold serve. | low | fixed |
| 11 | backend `flow.py:216` | `preference_change` handler reads key `topic` the parser never emits → every in-quiz preference command silently dropped while the user hears "applied"; empty string appended to preferred topics pollutes retrieval. | medium | fixed |
| 12 | backend `question_retriever.py:318` | All three fallback queries rebuild filters from scratch → category filter and `pack_id IS NULL` (paid-pack privacy boundary) vanish. Live path with 31-question corpus. | medium | fixed |
| 13 | backend `manager.py:216` | Session read-modify-write with no per-session serialization → overlapping submits double-burn quota and desync `current_question_id`. | medium | fixed (per-session lock) |
| 14 | ios `QuizViewModel.swift:1361` | `skipQuestion` has no state/single-flight guard and ignores its rejected transition. | medium | fixed |
| 15 | ios `QuizViewModel.swift:1644` | `handleQuizResponse` commits stats/tallies/recap/session before an unchecked transition → half-committed state on rejection. | high | fixed |
| 16 | ios `AuthService.swift:351` | Refresh rejection on a signed-in account re-aliases RevenueCat to the anon id → active subscription hidden, duplicate purchase invited. | high | fixed |
| 17 | ios `TransientRetry.swift:37` | Submits retried on `timedOut`/`networkConnectionLost` — errors that don't prove the request never arrived; backend submit is not idempotent → double-count. | medium | → #133 (needs idempotent submit API) |
| 18 | ios `MCQTranscriptMatcher.swift:46` | Number words treated as positional directives even when the utterance IS an option's text → wrong MCQ answer auto-submitted without confirmation (numeric-answer trivia). | medium | → #133 |
| 19 | ios `RecordingCoordinator+Confirmation.swift:56` | Editing a Whisper transcript re-submits to a session the server already advanced → graded against the next unseen question, second quota unit burned. | medium | → #133 (same root: idempotent submit API) |
| 20 | ios `SilenceDetectionService+Engine.swift:29` | `startListening()` re-entrancy across the audio-format suspension → orphaned SpeechAnalyzer + second AVAudioEngine. | medium | → #133 |
| 21 | ios `EntitlementReconciler.swift:137` | Post-purchase/restore usage check joins a *pre-sync* in-flight `/usage` fetch → successful recovery reports "nothing to restore" (the exact #102-3 bug it was built to prevent). | medium | → #133 |

Refuted by verifiers (3): qp `tasks.py:153` post-delivery flip to failed (guarded upstream), backend `rc_service.py:531` sync resurrecting revoked sub (fail-closed in code), qp `fact_verifier.py:122` judge 404 in direct mode (endpoint exists).

## Mutation probes (empirical test-suite strength)

- **quiz-agent + shared: 8/8 mutations caught** (full 484-test suite, green baseline 29 s). Evaluator routing, session expiry, retriever expiry, quota boundary, entitlement direction, rate-limit key, phase table, `Question.is_expired` — all killed. Strong core.
- **quiz-pack-api: 7/8 caught.** The survivor: **`storekit/verifier.py:151` — inverted subscription-expiry check passed the whole 685-test suite.** No test referenced `expires_date`/`JWSExpired` at all. A lapsed subscriber would keep premium; a paying one could be rejected. **Closed in-session: expiry tests added.** (Known pre-existing flake noted: `test_order_sse_reconnect` under full-suite load.)

## Test-suite verdicts (5 auditors; full details in #133)

- **quiz-agent (484 tests): unusually strong** — money paths DB-backed with out-of-order webhook coverage, crypto paths verify real signatures. Weakness concentrated in answer evaluation: 15 MCQ tests exercise a test-local copy of the production method (survive deleting the real code); LLM parsing ladder + partial-credit weights had zero tests (parsing now covered by fix #2's tests).
- **quiz-pack-api unit (~497): well-motivated**, but a large slice of prompt tests assert wording, not behavior; several tautologies (constants vs their own literals).
- **quiz-pack-api integration (177): StoreKit crypto layer genuinely well defended** (self-minted chain actively attacked). Above it: the money-path `process_order` module is entirely non-strict xfail (3 tests that can neither fail nor meaningfully pass), `test_order_e2e_full` fails deterministically in-dir, sweep tests are order-fragile.
- **iOS logic tests: unusually strong** for what matters (real forced races, URLProtocol-level network tests). Pockets of tautology (MockAudioService contract suite, fixture-only audio tests).
- **iOS view layer: ViewInspector tests carry real protection; the snapshot layer is entirely false confidence** — all 8 baselines are view-model property dumps (`.dump`/`.stableDump` never renders `body`), so no view change can fail them; plus two unmodified Xcode template stubs asserting nothing.

## Appendix — unverified findings (35, not yet adversarially verified)

See `docs/issues/issue-133-audit-deferred-fixes.md` §3 for the triage list (9 low, 26 medium). Notable candidates: `headline_answer` reported as having no storage column (two independent finders — deferred-reveal recap payload would be permanently empty), StoreKit revocation never checked, RC TRANSFER events dropped, `translate_feedback` caching unvalidated LLM output durably.
