# Issue 144: Session id is the only authorization on the text quiz path — bind the authenticated subject to session ownership

**Triage:** bug · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a (server-side only; iOS already sends the bearer)
**Created:** 2026-08-06

## Context

Creating a session is properly authenticated: the subject comes from the bearer token, and a `pack_id` is checked against the caller's owned packs before the session exists (`_require_pack_ownership`, the #96 — iOS MVP completion — broken-access-control fix). Everything *after* creation trusts the session id alone. That id is what serves a paid custom pack's private questions, spends the owner's freemium quota, and drives GPT-eval + TTS spend — so a session id that leaks (URLs, client logs, Sentry breadcrumbs, support screenshots) works as a bearer token for someone else's paid content. The #96 fix is therefore half-installed: ownership is verified once, then never again. This is one self-contained security workstream over `quiz.py` / `sessions.py` / `voice.py` and ships independently of every other audit finding.

## Confirmed findings

All findings below were re-read against the code on 2026-08-06 and independently verified (adversarial pass: confirmed, severity **serious** — not critical; see "Severity" below).

**1. No auth dependency on the text quiz path.**
`start_quiz` (`apps/quiz-agent/app/api/routes/quiz.py:62-70`), `submit_input` (`quiz.py:227-234`) and `get_current_question` (`quiz.py:297-301`) declare only service dependencies (`session_manager`, `quiz_flow`, `question_retriever`, `audio`) — no `Depends(require_auth_or_grace)`. Same for `get_session` (`sessions.py:138`), `delete_session` (`sessions.py:150`), `extend_session` (`sessions.py:161`), `rate_question` (`quiz.py:343`), `flag_question` (`quiz.py:382`), and the multiplayer pair `add_participant` (`sessions.py:179`) / `remove_participant` (`sessions.py:199`). Nothing compensates at a higher level: `app/main.py` adds only CORS, no auth middleware and no router-level `dependencies=`.

**2. Where the dependency exists, its result is thrown away.**
The voice twin of the exact same operation *is* gated — `voice.py:67` carries `_auth=Depends(require_auth_or_grace)` — but assigns the subject to a discarded `_auth` and never uses it. Grepping `session.user_id` across `apps/quiz-agent/app/` returns only quota and feedback bookkeeping (`flow.py:226/228/235/268/269`, `quiz.py:84/86/89/178/179/357/397`). **The authenticated subject is never compared to `session.user_id` anywhere in the application.** So even the gated voice route only asks "is this *a* valid user", never "is this *the* session's user".

**3. Pack ownership is a one-time check.**
`_require_pack_ownership` (`sessions.py:28-69`) runs exclusively inside `create_session` (`sessions.py:105-108`), before the session row exists. Its own docstring states the predicate it enforces (a `question_packs` row matching `(id, user_id)`) and its 404-not-403 semantics. Every subsequent serve of that pack's questions goes through the unauthenticated `/sessions/{id}/question` and `/sessions/{id}/input`.

**Impact.** Broken access control on paid content plus a quota/cost path: a leaked session id lets a third party read another user's paid pack questions, burn that user's free monthly allowance, and trigger LLM evaluation and TTS spend on routes rate-limited at 10/min (`start`) and 30/min (`input`). `LEGACY_USER_ID_GRACE` is already off in prod, so these routes are the last remaining un-gated AI-cost surface.

**Severity — why serious, not critical.** Three mitigations the raw finding understated: (a) session creation itself is authenticated and pack-ownership-checked, so an attacker must first obtain a valid, live session id — this is a leak-exploitation path, not an anonymous open door; (b) ids are `sess_` + 12 hex ≈ 48 bits (`app/session/manager.py:186`) and TTL-bound, with the rate limits above, so guessing is not practical; (c) prod currently has no real users beyond the founder. The gap is real and worth closing now while it is cheap; it is not a live incident.

**Unverified / not claimed.** No evidence of actual abuse (no logs reviewed for cross-subject session access). Whether legitimate multiplayer participants must reach these routes under a different subject id is an open design question — see the approach below.

## Proposed approach

Conceptual, one shared mechanism rather than per-route ad-hoc checks:

1. **One ownership helper**, sibling to `_require_pack_ownership` and placed where all three route modules can import it (session dependency module or a small shared `deps` helper). It takes the request's resolved subject and the loaded session, and rejects unless the subject owns the session. Mirror `_require_pack_ownership`'s **404, never 403** semantics so a caller cannot distinguish "not yours" from "expired/absent", and log the real reason server-side.
2. **Add the auth dependency to every `/sessions/{session_id}/…` route** in `quiz.py` and `sessions.py`, binding the subject to a named parameter (not a discarded `_auth`), and route it through the helper right after the session is loaded.
3. **Fix the voice route to use the same helper** instead of discarding its subject — one code path, no second-class twin.
4. **Decide the grace and no-identity behaviour explicitly.** `require_auth_or_grace` can return an unauthenticated legacy subject while `LEGACY_USER_ID_GRACE` is on; prod has it off. Fail closed (deny when the subject cannot be verified), and keep the decision in one place inside the helper rather than duplicating conditionals per route.
5. **Multiplayer participants** — founder decision (2026-08-06, in-session): **owner-only for now**; multiplayer is far-future but the architecture should accommodate it. Keep the ownership rule in the single shared helper so a participant-scoped predicate can be added there later without touching routes.
6. **No client change.** iOS already attaches `Authorization: Bearer` on its generic request path (`apps/ios-app/Hangs/Hangs/Services/NetworkService.swift:97/109`), so this ships and deploys server-side alone.

## Done criteria

- [ ] Every route under `/sessions/{session_id}` in `quiz.py`, `sessions.py` and `voice.py` declares the auth dependency and passes the loaded session through the shared ownership helper — verified by an inventory test or an explicit route-list assertion, not by eyeballing.
- [ ] A test proves cross-subject access is denied: subject A creates a session, subject B (valid bearer, different subject) gets **404** on `start`, `input`, `question`, `rate`, `flag`, `GET /sessions/{id}`, `DELETE`, `extend`, `voice/submit`, and the participant routes.
- [ ] A test proves the pack case specifically: subject B cannot read subject A's custom-pack questions through `/sessions/{id}/question` — closing the #96 gap end to end.
- [ ] A test proves an unauthenticated / unverifiable subject is denied (fail-closed), including the grace-window path.
- [ ] Owner's happy path unchanged: existing quiz flow tests green with no fixture changes beyond adding a bearer where one was missing.
- [ ] `cd apps/quiz-agent && pytest tests/ -v` green; deployed to prod and one real session played through from the iOS client (start → input → question) with no 404 regression.
