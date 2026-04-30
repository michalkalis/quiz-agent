# Issue 24: Consolidate `question_to_dict_translated` into `serializers.py`

**Triage:** enhancement · done
**Status:** Done 2026-04-30 — canonical `question_to_dict_translated` now lives in `app/serializers.py`, both duplicates removed.
**Created:** 2026-04-30
**Surfaced by:** architecture review, candidate #3

## TL;DR for next session

Two near-identical functions translate a `Question` for the wire:

| Where | Lines |
|---|---|
| `apps/quiz-agent/app/api/deps.py:166–177` | `question_to_dict_translated` (free function, used by `start_quiz`, `get_current_question`) |
| `apps/quiz-agent/app/quiz/flow.py:340–353` | `_question_to_dict_translated` (private method on `QuizFlowService`) |

Both call `question_to_dict`, then `translation_service.translate_question`,
both fall back silently on translation failure. The comment in `flow.py`
acknowledges the split exists only to dodge a circular import.

`apps/quiz-agent/app/api/serializers.py` exists as the natural home. The
translation step was never folded into it.

## What to implement

Move the canonical `question_to_dict_translated(question, target_lang) -> dict`
into `serializers.py`. Both call sites import from there. Delete the
duplicates.

If the original circular-import constraint still bites, break it the right
way — extract `translation_service`'s interface, or invert the dependency —
rather than papering over with two copies.

## Where the work lands

| Where | What changes |
|---|---|
| `apps/quiz-agent/app/api/serializers.py` | New `question_to_dict_translated(question, target_lang)` |
| `apps/quiz-agent/app/api/deps.py:166–177` | Delete free function; import from `serializers` |
| `apps/quiz-agent/app/quiz/flow.py:340–353` | Delete private method; call the serializer directly |

## Benefits

- **Locality.** Translation fallback behaviour fixed in one place.
- **Tests.** A single unit test covers the wire-format translation path.

## Caveats and traps

- **The reason for the split was a circular import** — verify the resolution
  doesn't reintroduce the cycle. If `serializers` already imports
  `translation_service` cleanly, you're fine.
- **This is a small, self-contained refactor.** Don't bundle other changes.
- **`question_to_dict` and `question_to_dict_translated` are not the same.**
  Don't accidentally collapse them.

## Related

- None. Strict locality fix.
