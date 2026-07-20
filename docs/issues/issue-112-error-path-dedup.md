# Issue 112: Error-path dedup — one quota/429 handler + generic NetworkService request

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 9. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 9 + dimension 7. Link, don't restate.

## Why

The quota/429 → resync → paywall logic lives in **three diverged copies** instead of the one canonical `handleError` (`QuizViewModel.swift:700`): `startNewQuiz`'s inline catch (`QuizViewModel.swift:646–663`) and `submitVoiceAnswer`'s quota branch (`QuizViewModel+Recording.swift:408–433`) each reimplement it. The copies have already drifted, and one divergence is **behavioral, not cosmetic**: `submitVoiceAnswer` omits `audioService.deactivateSession()`, so a mid-answer quota block leaves the audio session live behind the paywall (Research, divergence 2). Error handling that only *looks* uniform is the class of latent bug that multiplies as the file grows.

Underneath, `NetworkService`'s 12 endpoint methods each hand-roll the same pipeline — build request → breadcrumb → `sendAuthorized` → `HTTPURLResponse` guard → error-decode → decode — so the guard is copied 12× and the 429/quota branch verbatim in three of them (`:225/:395/:458`). Every new endpoint (#97 CarPlay, #95 pack play) re-pastes it.

This is a prerequisite, not a parallel effort: **#113 — Decompose the QuizViewModel god object** moves these same methods. Collapsing three error copies into one and twelve request bodies into one generic **shrinks #113's surface** before it starts; doing it after means decomposing duplicated code. Run this first.

## Scope

**In scope**
- Route `startNewQuiz`'s and `submitVoiceAnswer`'s quota/429 catches through the canonical `handleError(_:context:fallbackMessage:)` — delete both reimplementations, pass each site's `context` (`.initialization` / `.submission`).
- Extract one generic `performRequest<T: Decodable>(_ request: URLRequest, endpointPath:) -> T` **+ a `Void` variant** in `NetworkService`; route the **11** JSON/Void endpoints through it — 6 decode (`createSession`, `startQuiz`, `submitVoiceAnswer`, `submitTextInput`, `getUsage`, `fetchElevenLabsToken`), 5 Void (`endSession`, `extendSession`, `rateQuestion`, `flagQuestion`, `syncEntitlements`). `endSession`'s 404→`sessionNotFound` stays a caller-side hook.
- Add a **submit-path error hook** to `MockNetworkService` (it has `createSessionError`/`endSessionError`/`syncEntitlementsError` but none for submit) + a `QuizViewModel`-level test pinning copy C (`submitVoiceAnswer`) through `handleError` — the currently VM-untested path.

**Out of scope**
- Any behavior *redesign* of the quota/paywall/resync flow — the #102 outcome-check, single-flight reconcile, and 401-refresh are preserved verbatim (Research, "Must preserve").
- **#113**'s QuizViewModel decomposition — this only removes duplication in place.
- Backend changes — quota-gate placement verified correct as-is (decision 2).

## Resolved design decisions

1. **Canonical behavior = `handleError`'s, `deactivateSession()` at every quota site included — adding it to `submitVoiceAnswer` is a deliberate behavior FIX.** `handleError` and `startNewQuiz` deactivate the audio session before the paywall; `submitVoiceAnswer` does not. Routing all three through `handleError` closes that gap — name it in the commit as an intentional fix (fail-loud), don't let it ride silently as "just a refactor."
2. **Unify 429→`quotaLimitReached` parsing across all POSTs, `createSession` included — behavior-preserving, verified.** The generic keeps the existing **body-discriminated** parse (`:225–231`): decode `QuotaLimitErrorWrapper` (requires nested `detail: QuotaLimitError`, `:643`) → `.quotaLimitReached`; anything else → `.serverError(429)`. Backend grep confirms the quota 429 fires **only** at start/input/voice-submit (`quiz.py:61–76/:216`, `voice.py:183`) and **never** at `create_session` (`sessions.py:72–134`, deferred by design, comment `:94`). So `createSession`'s only bare 429 is its `@limiter.limit("10/minute")` rate-limit (`sessions.py:75`), whose body won't decode as a quota wrapper → cannot false-trigger a paywall. Net: `createSession` gains correct-and-dormant quota handling, zero behavior change today, future-proof if the backend ever gates earlier. *(How to re-confirm: `grep -rn "quota_limit_reached\|check_limit" apps/quiz-agent/app/api/routes` — expect hits in quiz.py/voice.py, none in sessions.py.)*
3. **Uniform breadcrumbs on all 11 endpoints via the generic — deliberate net-positive.** Today `extend`/`rate`/`flag`/`token`/`usage`/`sync` emit no `breadcrumbRequest`/`breadcrumbResponse`; centralizing the pipeline adds them uniformly (metadata-only, no bodies — the existing idiom). Named here so the gate reads it as intended observability, not scope creep.
4. **Per-endpoint specifics stay at the caller, passed *into* the generic via a pre-built `URLRequest`.** Multipart body (`submitVoiceAnswer`), per-endpoint timeouts (voice 120s / text 60s / token·usage·download 10s / sync 15s), and the `@MainActor` iso8601 decode (`decodeQuizResponse`; `createSession`→`QuizSession`) are all set by the caller before handing the request to `performRequest`. The generic owns only the shared middle: breadcrumb → `sendAuthorized` → guard → 429-parse → `decode(T)`. MainActor decode is preserved by the caller performing the decode or by making the generic `@MainActor` — Phase 4 picks the mechanism.
5. **`downloadAudio` stays bespoke — no `performDataRequest` abstraction.** It returns raw `Data`, bypasses cache, resolves relative/absolute URLs, and runs a Content-Length integrity check — none modeled by the Decodable generic. A second generic for a single caller is a single-use abstraction (CLAUDE.md #1). Leave it as-is.

**Founder decision needed — "just synced" retry wording (non-blocking).** After a successful resync the copies show two strings: `startNewQuiz`'s quiz-specific *"…please try starting the quiz again."* vs the generic *"…please try again."* used by `handleError` + `submitVoiceAnswer`. **Default (recorded, executable now):** adopt the **generic** *"please try again."* — context-agnostic and already the majority (2 of 3). Surface to the founder as a one-line wording call; do **not** block the refactor on it (swapping one localized string later is trivial).

**Second-order lens.** (a) This lands **before #113** on the same files — dedup first means #113 decomposes one error path + one request method, not three + twelve. (b) `performRequest` becomes the **seam every future endpoint reuses**: #97 CarPlay and #95 pack play inherit auth + 429-parse + breadcrumbs for free instead of re-pasting the guard. The generic is the durable payoff; the dedup is the immediate one.

## Research (Phase 1, 2026-07-20)

**Anchor drift:** none — all cited anchors accurate. `startNewQuiz` = 134 lines (549–682); quota catch 646–663. `submitVoiceAnswer` 344–471; quota branch 408–433 (review's 410 lands inside it). NetworkService 429 copies at 225 (startQuiz), 395 (submitVoiceAnswer), 458 (submitTextInput); 12 protocol endpoints confirmed. Canonical `handleError(_:context:fallbackMessage:)` = **private async**, `QuizViewModel.swift:700–723`; already used by submitAnswer/resubmit/skip (`:942/1009/1040`). `startNewQuiz` and `submitVoiceAnswer` reimplement it instead of calling it.

**The 3 quota/429 copies — actual divergences** (all do: resync → confirmed?→"synced, retry" via `setError`; else `quotaLimitError`+`showPaywall`+`transition(.idle)`):
1. **User-facing copy** — startNewQuiz says *"…please try starting the quiz again."*; handleError + submitVoiceAnswer say *"…please try again."* → **PRODUCT question below.**
2. **`audioService.deactivateSession()`** — present in startNewQuiz + handleError, **absent in submitVoiceAnswer** (leaves audio session live at paywall). Behavioral, not cosmetic.
3. **`context`** — startNewQuiz hardcodes `.initialization`, submitVoiceAnswer `.submission`, handleError is parameterized → unifying via `handleError(context:)` loses nothing. submitVoiceAnswer also wraps in `MainActor.run` (runs inside a detached `Task`); the other two are on-actor.

**Must preserve:** the #102 outcome-check — `resyncBeforePaywallIfLocallyEntitled()` returns Bool and **skips the paywall when the resync confirms entitlement** (`:863`, uses injected `isLocallyEntitled`); single-flight `reconcileEntitlements`/`syncEntitlementsWithRetry` (3-attempt backoff, Sentry-warn on give-up); `sendAuthorized` 401 single-flight refresh+retry; per-endpoint timeouts (voice 120s, text 60s, token/usage/download 10s, sync 15s); MainActor iso8601 decode + detailed decode-error logging (`decodeQuizResponse`); breadcrumb idiom (`breadcrumbRequest`/`breadcrumbResponse`/`logHTTPError`, metadata-only, no bodies).

**NetworkService endpoint map (12) → performRequest fit:**
- **JSON-decode fit** (build req → breadcrumb → sendAuthorized → guard → 429-parse → decode): `createSession`(→QuizSession, MainActor decode), `startQuiz`, `submitTextInput`, `submitVoiceAnswer`(multipart body), `getUsage`(→UsageInfo), `fetchElevenLabsToken`(nested `{token}`). Caller pre-builds `URLRequest` (body/content-type/timeout); generic takes request + endpointPath label.
- **Void fit** (no decode → `performRequest` returning `Void`/`EmptyResponse`): `endSession`(+404→`sessionNotFound` hook), `extendSession`, `rateQuestion`, `flagQuestion`, `syncEntitlements`.
- **Does NOT fit the Decodable generic:** `downloadAudio` — raw `Data`, cache-bypass, relative/absolute URL, Content-Length integrity check; keep bespoke or a separate `performDataRequest`.
- **Note (surface for plan):** the 429→`quotaLimitReached` parse exists on only 3 of the mutating POSTs — **`createSession` lacks it** (a real 429 there → `invalidResponse`, not paywall). VM 429 tests inject via the mock so this is untested in the real path. Extracting the generic naturally unifies 429 handling; confirm backend gates quota at `startQuiz`/submit (not session-create) so behavior is preserved. Breadcrumbs are likewise missing on extend/rate/flag/download/token/usage/sync — the generic would add them uniformly (net-positive behavior change).

**Test seams:** `NetworkServiceTests.swift` (StubURLProtocol, process-wide static handler, `makeService()`) — 14 tests lock per-endpoint contract incl. 429→quotaLimitReached (via submitTextInput only), malformed-429, download integrity, 401 refresh-retry; these are the regression net for the generic extraction (startQuiz/submitVoiceAnswer 429 not directly unit-tested here). `EntitlementReconcileTests.swift:170–216` locks VM-level quota→resync→paywall/skip — but **only via the startNewQuiz path** (`createSessionError` hook). `MockNetworkService` (ships in prod target, `Hangs/Services/Mocks/`) has `createSessionError`/`endSessionError`/`syncEntitlementsError` hooks but **no submit-path hook** → copies B (handleError-via-submitAnswer) and C (submitVoiceAnswer) are VM-untested; dedup should add a submit error hook + test to pin the third copy before/after merge. `AppErrorModelTests` covers quotaLimitReached→goHome CTA (unaffected).

**Build-vs-adopt:** internal dedup — no library. Route all 3 quota copies through the existing canonical `handleError`; extract one in-repo generic `performRequest<T: Decodable>` (+ Void/data variants) in NetworkService. No new dependency.

**Web pass skipped:** pure internal refactor, no external API/library research needed.

**PRODUCT question:** which "just synced" copy wins — the quiz-specific *"please try starting the quiz again."* or the generic *"please try again."*? Recommend the generic (context-agnostic, reused across all 3 sites); flag for founder since it's user-facing wording.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | Why/Scope/Resolved-decisions written; `createSession` 429-unification verified behavior-preserving (backend quota-gates at start/submit only, `sessions.py` never); founder wording call recorded with executable default. **Next: Phase 3.** |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.90 |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 (Phase 2 complete) · **Next:** Phase 3 (dual gate: ready-check · design-soundness) · **Gate attempts:** P3 0/3 · P5 0/3
