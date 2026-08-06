# Issue 148: Type the answer-submit contract — shared exception taxonomy across voice/text plus Pydantic evaluation and audio payloads

**Triage:** bug · fixed (agent-side), awaiting deploy
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a
**Created:** 2026-08-06

## Context

Answer submit is the money path: by the time a response comes back, the question has been served, the freemium quota has been charged, and a verdict has been graded. Two routes run over one shared flow — voice (`POST /sessions/{id}/voice-input`) and text (`POST /sessions/{id}/input`) — and today neither the error surface nor the graded payload is typed. The result is one flow with two contradictory error contracts (the same server-side data fault is a client 400 on voice and a paging 500 on text, and the retryable-503 envelope iOS relies on exists only on the text route), and a graded payload that is an untyped dict on the server but a non-optional Swift struct with a strict enum on the client — invisible to OpenAPI and to `/verify-api`. Both are the same defect: the submit contract is implicit. Typing the exceptions and typing the payload touch the same files in one pass.

## Confirmed findings

Both findings were adversarially verified against the code (2026-08-06); neither is tracked elsewhere and neither is covered by a decided constraint.

### 1. Same flow, two different error taxonomies (serious, confirmed)

`apps/quiz-agent/app/api/routes/voice.py:209-214` catches bare `ValueError` around the shared `quiz_flow.process_answer` call (voice.py:166) and turns it into a **400 with the raw internal message**, commented "Constructed validation text (format/size) — client-safe by design". The intent is real (`transcriber.py:169,180` format/size validation), but the catch is far wider than the intent: the same shared flow raises `ValueError("Current question not found")` (`apps/quiz-agent/app/quiz/flow.py:175`) and `ValueError("Re-submitted question not found")` (`apps/quiz-agent/app/quiz/resubmission.py:192`) — server-side data faults. The identical exception from the identical call falls into the text route's generic handler (`routes/quiz.py:275-279`) and becomes a **500 plus `sentry_sdk.capture_exception`**.

The resubmission case is genuinely reachable: it fetches `previous.question_id`, a different id from the one voice.py:95 already validated.

The mirror half is stronger: `_TRANSIENT_INFRA_ERRORS` → 503 exists **only** on the text route (`routes/quiz.py:52-57` and `266-274`). `apps/ios-app/Hangs/Hangs/Utilities/TransientRetry.swift:1-16` explicitly names voice submit as the regression the retryable 503 was introduced for (only 502/503 pass `isTransient`), so on the voice route a backend DB blip cannot engage the shipped client retry at all — the #131 Track A fix is half-applied.

**Impact:** two clients of one flow disagree on what is retryable and what is the user's fault. A missing question row tells the voice client "your input was bad" (no retry, no Sentry alert) while paging on the text path; a transient Postgres error during a voice submit is never retried despite iOS having the logic. Error contracts that drift per route make later incident triage expensive.

### 2. `InputResponse.evaluation` and `.audio` are untyped dicts (serious, confirmed)

`apps/quiz-agent/app/api/deps.py:127-133` types `current_question: Optional[PublicQuestion]` but leaves `evaluation: Optional[Dict[str, Any]]` (deps.py:128) and `audio: Optional[Dict[str, Any]]` (deps.py:132). Both dicts are hand-built — evaluation at `app/quiz/flow.py:372-388` (answer) and `flow.py:402-415` (skip), audio at `flow.py:452-470` plus a second producer in `routes/quiz.py:194` — and pass through `flow_to_response` (`deps.py:483-495`) unvalidated. `packages/shared/quiz_shared/models/session.py:34-35` stores the same untyped dict as `LastEvaluation.evaluation`, "replayed verbatim".

`apps/quiz-agent/tests/test_question_openapi_visibility.py` states the intent — the point of `PublicQuestion` is that `/verify-api` and the iOS Codable diff can see the payload in the schema — but asserts only `current_question` (test line 65). `.claude/skills/verify-api/SKILL.md` diffs Pydantic models against Swift structs, so with no Pydantic evaluation model there is nothing to diff.

Client side: `apps/ios-app/Hangs/Hangs/Models/Evaluation.swift:11-14` declares `userAnswer`, `result`, `points`, `correctAnswer` non-optional, and `EvaluationResult` (Evaluation.swift:50-56) is a bare `String`-backed enum with **no** custom `init(from:)` — unlike `Question.QuestionType` (`Models/Question.swift:150-160`, commented "so old app versions don't crash") and unlike `OrderSnapshot.status` (`PackOrder.swift:110`, kept raw deliberately). `AudioInfo.format` (`Models/AudioInfo.swift:15`) is likewise non-optional.

**Impact:** the one response the whole money path runs through has no schema and a client that throws on any unknown verdict string. This failure mode already happened once at the value level: `flow.py:355-361` documents a null `user_answer` that "killed the decode of the WHOLE response, losing a verdict the player had already been charged for" — patched at the producer rather than structurally. Adding a sixth evaluator result, or dropping `format` from an audio branch, reproduces it, and neither OpenAPI nor any test flags it beforehand.

**Verification correction (keep scope honest):** the audio half is the weaker one — every producer sets `format` unconditionally and audio is not on the money path. The load-bearing half is the evaluation payload plus the non-defensive enum. Severity is serious, not critical, because backend and client verdict sets are in sync today (5 for 5) and drift requires a deliberate backend change — but a shipped binary with a strict enum cannot be fixed retroactively post-GA.

## Proposed approach

Conceptual, one session, no behavioral change beyond the contract:

1. **Typed flow exceptions.** Give the shared quiz flow a small exception family for the conditions it actually has: question unavailable (server-side data fault), invalid submission (client-supplied audio/text that failed format or size validation), and the already-existing question mismatch. Raise these from `flow.py` / `resubmission.py` instead of bare `ValueError`.
2. **One shared mapping.** Map that family to HTTP status once — a single handler or dependency used by both routes — so voice and text answer identically: data faults become server errors with Sentry capture, genuine client input problems become 400s, transient infra becomes the retryable 503 on **both** routes. Stop catching bare `ValueError` in `voice.py`.
3. **Typed payloads.** Promote the evaluation dict to a Pydantic model built at the producers in `flow.py`, and the audio dict to a model built at both its producers; reference them from `InputResponse` so they appear in OpenAPI as `$ref`s. Keep the shared `LastEvaluation` replay working against the typed model.
4. **Defensive client enum.** Give `EvaluationResult` the same unknown-value fallback `QuestionType` already carries, so an unrecognised verdict degrades instead of discarding an already-charged evaluation.
5. **Lock it with the existing contract test.** Extend `test_question_openapi_visibility.py` from one field to the whole submit response.

Do not change status codes the clients already depend on (409 question mismatch, the 400 for a non-answer intent) and do not widen the evaluation payload's field set in this pass.

## Done criteria

- [x] `voice.py` no longer catches bare `ValueError`; grepping the submit paths shows no route mapping an untyped exception to a status code. — both routes funnel every flow exception through `app/api/submit_errors.py:submit_http_error`; the only `raise HTTPException` left on either submit path are direct preconditions (phase, no-speech, no-answer-intent, quota).
- [x] A test asserts that the *same* flow condition (question not found) yields the *same* status code and the same Sentry behaviour on both `/input` and `/voice-input`. — `tests/test_submit_error_contract.py::test_missing_question_pages_identically_on_both_routes`, parametrized over both routes (500 + one Sentry capture, internal ids never in the body).
- [x] A test asserts a transient DB error during a **voice** submit returns 503, and that `TransientRetry` classifies it as retryable. — `test_transient_db_error_is_a_retryable_503_on_both_routes`; the iOS half already existed and stays green: `SubmitRetryTests.onlyTransientErrorsRetry` (503 ⇒ transient) + `voiceSubmitRetriesTransient503`.
- [x] A test asserts a client-side audio format/size rejection still returns 400 on the voice route. — size: `test_voice_rejects_an_oversized_upload_with_a_400`; format: the pre-existing `test_route_error_detail_leaks.py::test_voice_submit_unsupported_format_stays_400`, unchanged and still green through the new `InvalidSubmission` path.
- [x] `curl /openapi.json` shows `InputResponse.evaluation` and `InputResponse.audio` as `$ref`s to named schemas, not free-form objects. — both are `anyOf[$ref → Evaluation | AudioInfo, null]`; each resolves to its wire schema, same convention as `PublicQuestion`.
- [x] `test_question_openapi_visibility.py` fails if either payload regresses to an untyped dict. — two new tests pin the `$ref` *and* the exact property/required sets, so widening the verdict payload or dropping `format` breaks the build.
- [x] iOS decodes an unknown `result` string without throwing (unit test), and `/verify-api` runs clean against the new models. — `EvaluationResult` gained `.unknown` + the `QuestionType`-style `init(from:)`; `NetworkDecodingTests."Evaluation survives a verdict this build does not know"`. `/verify-api`: clean for `Evaluation` / `AudioInfo` / `InputResponse`.
- [~] Backend suite green (`cd apps/quiz-agent && pytest tests/ -v`); targeted iOS ViewModel/Codable tests green; deployed to prod. — 624 backend tests green; 55 iOS tests across 6 touched suites green first run. **Deploy still open** (rides the same quiz-agent deploy as #144 / #151).

## Implementation notes (2026-08-06)

- **Exception family** — `apps/quiz-agent/app/quiz/errors.py`: `QuizFlowError` base, `QuestionUnavailable` (server data fault, carries `question_id` + `stage`), `InvalidSubmission` (client audio/text), `QuestionMismatch` (moved verbatim from `resubmission.py`). `flow.py` and `resubmission.py` raise these instead of `ValueError`; `voice/transcriber.py` raises `InvalidSubmission` for its format/size checks.
- **One mapping** — `apps/quiz-agent/app/api/submit_errors.py` owns 409 / 400 / 503 / 500-with-capture and the `TRANSIENT_INFRA_ERRORS` tuple (moved off `routes/quiz.py`). Route-specific wording survives as `fallback_detail`.
- **Typed payloads** — `packages/shared/quiz_shared/models/submit.py`: `Evaluation` + `AudioInfo`, both with a `model_serializer(mode="plain")` wire TypedDict so optional keys are still *omitted* rather than emitted as null — the JSON bytes are unchanged. `FlowResult`, `LastEvaluation.evaluation` and `InputResponse` are now typed end to end. `result` stays a plain `str`: a verdict the backend has not seen before must not fail validation on a response the player was already charged for; degrading it is the client's job.
- **Not done, deliberately** — the evaluation field set was not widened, and 409 / 400-non-answer-intent are byte-identical.
