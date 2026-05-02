# Issue 25: Backend `QuizSession.phase` — add a transition guard module

**Triage:** enhancement · done
**Status:** Shipped 2026-05-02 — `SessionPhase` enum + `transition()` method on `QuizSession`, valid_transitions table in `packages/shared/quiz_shared/models/phase.py`, all 5 call sites migrated, deep-copy mutation in `routes/quiz.py` resolved by deferring transition until just before `update_session()`, redundant `asking → asking` self-loop at `flow.py:253` removed. 27 new transition-table unit tests + 64 backend tests passing.
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #4

## TL;DR for next session

The backend session state machine is unguarded. `QuizSession.phase` is a raw
string field, mutated with direct assignment across five files:

| Where | Mutation |
|---|---|
| `apps/quiz-agent/app/api/routes/quiz.py:68` | `session.phase = "asking"` |
| `apps/quiz-agent/app/quiz/flow.py:218,228,246,255` | Multiple direct assignments |
| `apps/quiz-agent/app/session/manager.py:163` | Direct assignment |
| `apps/quiz-agent/app/api/routes/voice.py:80` | Direct assignment |

The only guard is a caller-side check at the start of route handlers:
`if session.phase not in ["asking", "awaiting_answer"]`. That check lives in
the caller, not in the session module.

There is also a subtle bug path: `routes/quiz.py:68` mutates `session.phase`
on what may be a deep-copy *before* `session_manager.update_session(...)` —
if the subsequent call errors, the mutation is silently dropped.

iOS already has this pattern done right: `QuizState`'s `transition(to:caller:)`
plus `validTransitions[...]` table. Bring the equivalent to the backend.

## What to implement

1. **Replace the phase string with a `SessionPhase` enum.** Likely values:
   `started, asking, awaiting_answer, processing, finished` (audit current
   call sites for the actual set).

2. **Move transition logic onto `QuizSession`.** Add a
   `transition(to: SessionPhase) -> None` method with a `valid_transitions`
   table. Reject invalid transitions with a typed exception
   (`InvalidPhaseTransition`) — log + raise, don't silently swallow.

3. **Eliminate every `session.phase = "..."` assignment** in favour of
   `session.transition(to=...)`.

4. **Resolve the deep-copy mutation.** Either mutate via a method that
   delegates to `session_manager` atomically, or document why the current
   shape is correct.

## Where the work lands

| Where | What changes |
|---|---|
| `packages/shared/quiz_shared/models/session.py` (or wherever `QuizSession` lives) | `SessionPhase` enum + `transition()` method + `valid_transitions` table |
| `apps/quiz-agent/app/api/routes/quiz.py:68` | Replace string mutation with `session.transition(to=...)` |
| `apps/quiz-agent/app/quiz/flow.py:218,228,246,255` | Same |
| `apps/quiz-agent/app/session/manager.py:163` | Same; consider whether the guard belongs here |
| `apps/quiz-agent/app/api/routes/voice.py:80` | Same |
| `apps/quiz-agent/tests/` | Unit tests for the transition table — mirror what iOS has |

## Benefits

- **Locality.** Adding a new phase (e.g., `"paused"` for the resume feature)
  is one edit in the session module, not five.
- **Leverage.** Callers get protection against invalid transitions for free.
  No need to remember the valid set per route.
- **Testability.** The transition table becomes the test surface for the
  session module — pure unit tests, no fixtures.
- **Aligns with iOS.** Same pattern on both ends of the API; easier to
  reason about.

## Caveats and traps

- **`QuizSession` lives in `packages/shared` — the iOS app does not consume
  the backend's Pydantic model**, so this is a backend-only change. Verify
  before assuming iOS impact.
- **`SessionManager` already has its own ordering and locking concerns** —
  don't merge `transition()` logic into the manager. The session is the
  smaller, deeper module; the manager orchestrates many sessions.
- **The deep-copy mutation in `routes/quiz.py:68` is a separate bug** that
  this refactor exposes. Don't sweep it under the rug — fix it explicitly,
  even if it means the route now calls `session_manager.transition(session_id,
  to=...)` instead of mutating directly.
- **Don't add a "self-loop" transition** (e.g., `processing → processing`)
  to make some existing call go through. If a self-transition is currently
  happening, it's a bug — fix the caller. Same lesson as Issue 19.

## Related

- iOS reference: `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:80–91`
  for the `validTransitions` shape.
- Memory `feedback_root_cause_debugging` — fix the call path, not the
  transition table.
- Issue 19 — same family of bug on the iOS side.
