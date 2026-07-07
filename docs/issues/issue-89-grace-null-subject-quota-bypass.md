# Issue #89 — Bug: grace-window request with no identity skips the monthly quota entirely

**Triage:** bug · ready-for-agent

**Created:** 2026-07-07 · **Source:** auth security review 2026-07-07 (top-level code-verified `identity.py:116-123` → `quiz.py:60` / `flow.py:245`)

**Severity:** ~~medium~~ **low — latent hardening, not a live bypass** *(corrected 2026-07-07: `LEGACY_USER_ID_GRACE=off` was flipped in prod and verified live on 2026-07-06 as part of #65's closure — one day before this review was written)*. While the grace window is **on**, a client can play unlimited free questions by sending no bearer and no `user_id`; with grace off the path is unreachable. Fix stays worthwhile as defence against ever re-enabling grace.

## Problem

`resolve_session_subject` (`identity.py:94-123`) has three paths:
1. Bearer present → authoritative subject.
2. No bearer, grace **off** → 401.
3. No bearer, grace **on** → trust `body.user_id` as a legacy subject.

In path 3, if `body_user_id` is also absent, it returns `AuthSubject(subject_id=None, …)` (`identity.py:123`). The session is then created with `user_id=None`, and **every quota gate is guarded on a truthy subject** — `if usage_tracker and session.user_id:` (`quiz.py:60`, `quiz.py:147`, `flow.py:245`, `flow.py:285`). A null subject skips both `check_limit` and `record_question`, so the play is neither counted nor capped.

This is simpler than the ID-spoofing the design already anticipates: an empty-body `POST /sessions` (no auth, no `user_id`) yields unlimited free questions.

It is a residual of the intentional migration window (`LEGACY_USER_ID_GRACE`, default `on`, `identity.py:38`). ~~Since grace is on in prod today, the bypass is live.~~ **Correction 2026-07-07: grace is already OFF in prod (#65 closed 2026-07-06, verified live: header-less `POST /sessions` → 401), so the bypass is latent — it matters only if grace is re-enabled or on a misconfigured deploy.**

## Evidence (code-verified 2026-07-07)

- `app/auth/identity.py:115-123` — no-bearer grace path returns `subject_id=body_user_id`; when `body_user_id` is falsy the subject is `None`.
- `app/api/routes/sessions.py` — session created with `user_id=subject.subject_id` (may be `None`).
- Quota gates all short-circuit on a falsy subject: `app/api/routes/quiz.py:60`, `:147`; `app/quiz/flow.py:245`, `:285` (`if … and session.user_id:`).

## Recommendation

When the grace path passes through with **no subject at all**, do not leave `user_id` null. Two viable options:

- **Preferred:** mint a server-side throwaway subject (a fresh UUID registered as legacy) so the session is still quota-counted. Keeps anonymous play working during the migration window without an unmetered hole.
- **Alternative:** reject the session (`400`/`401`) when grace is on but neither bearer nor `user_id` is supplied — legitimate legacy clients always send a `user_id`, so this only blocks the bypass.

Pick the option that matches how legacy clients actually behave (they send `user_id`); the throwaway-subject option is safer if any legacy path can legitimately omit it. Keep the loud grace-passthrough warning (`identity.py:126-137`).

**Decision (2026-07-07, session-split — folded in from the deleted draft `issue-89-quota-grace-window-bypass.md`):** go with **reject (401)** — legacy clients always send `user_id`, so nothing legitimate is blocked; a minted throwaway subject would add rows for no user. Belt-and-braces: also guard session creation so a `user_id=None` session can never be created (fail-loud invariant). Flipping the grace flag itself stays #65's scope, not this issue's; keep separable from #90.

## Acceptance

- [ ] Empty-body `POST /sessions` (no bearer, no `user_id`) with grace on → either rejected, or assigned a server-minted subject that **is** counted by the quota
- [ ] Legitimate legacy request (no bearer, valid `user_id`) still works unchanged during grace
- [ ] Bearer path unchanged
- [ ] Unit test: null-subject session cannot exceed the free quota
- [ ] Grace-passthrough WARNING log preserved

## Notes

- This closes fully when `LEGACY_USER_ID_GRACE=off` **and** `APP_ATTEST_REQUIRED=on` — confirm the flag state on the Fly deploy as part of #65. This issue hardens the interim.
- Prod has no real users yet (founder only) so the live risk is currently theoretical, but it should not survive to the paid launch.
- Cross-refs #65 (authenticate production endpoints / grace flip-off), #87 (monthly free quota), #60 (anonymous identity).
