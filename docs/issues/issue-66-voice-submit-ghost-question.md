# Issue #66 — Bug: voice submit advances the session on a non-answer intent (ghost question)

**Triage:** bug · ready-for-agent

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 3 — verified first-hand)

**Severity:** high — primary voice interaction path, plausible in a noisy car.

## Problem

When a spoken utterance is parsed as a **non-answer intent** (preference/category change, rating,
or anything that isn't `answer`/`skip`), `process_answer()` still advances
`session.current_question_id`, appends to `asked_question_ids`, and calls
`usage_tracker.record_question()`. The voice route then returns a 400 *after* the session has
already moved on. iOS re-displays the original question, but the server is now on the next one —
every subsequent answer is evaluated against the wrong (silently skipped) question. It also burns
a question against the daily free limit for an utterance the user never answered.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-agent/app/quiz/flow.py:150` — only the `answer` intent sets `result.evaluation`.
- `apps/quiz-agent/app/quiz/flow.py:178` — only the `skip` intent sets `result.evaluation`.
- `apps/quiz-agent/app/quiz/flow.py:256-302` — the next-question fetch, `session.current_question_id` advance (272-273), and `record_question()` (277) run with **no guard on `result.evaluation`**. There is no early return for "no evaluatable intent."
- `apps/quiz-agent/app/api/routes/voice.py:165` — raises `HTTPException(400)` *after* `process_answer()` has already mutated the session.
- The text `/input` path (`quiz.py`) has the same structural advance with no error signal at all.

## Recommendation

In `flow.py`, after the intent loop and before the session-advance block (~line 256), return early
when nothing evaluatable was recognized:

```python
if result.evaluation is None:
    return result  # non-answer intent — do not advance the session or consume a question
```

The caller then sees `evaluation is None` / no `next_question_dict` and can surface the 400
without any state mutation. Apply the same guard to the text `/input` path.

## Acceptance

- [ ] A voice submission parsed as only `preference_change` (or any non-answer intent) does **not** change `session.current_question_id`
- [ ] The same submission does **not** call `record_question()` (no daily-limit consumption)
- [ ] The 400 is returned with the session still pointing at the original question
- [ ] New test in the flow integration suite: preference-only intent → `current_question_id` unchanged + 400
- [ ] Text `/input` path returns a meaningful error instead of silently advancing
- [ ] Existing RS regression scenarios pass
