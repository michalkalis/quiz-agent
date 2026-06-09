# Issue 49: MCQ backend activation — let `text_multichoice` reach the voice quiz

**Triage:** enhancement · ready-for-agent
**Status:** Ralph-ready — decomposed into atomic tasks below. Backend-only slice of the "MCQ in launch" founder decision (`docs/product/launch-decisions-2026-06-08.md`); spun out of `handoff-2026-06-09-1042.md` next steps.
**Created:** 2026-06-09
**Related:** `issue-42-question-quality-and-mcq.md` (generation side, done), `issue-45-ios-mcq-voice-and-redesign.md` (iOS side, 45.7–45.13 human), `docs/product/launch-decisions-2026-06-08.md`

## TL;DR

The founder decided MCQ ships in launch. The generation pipeline (#42) and iOS components (#45.1–45.6) are done, but the voice-quiz retriever still hard-filters question types to `["text", "image"]` (`apps/quiz-agent/app/retrieval/question_retriever.py:212`) — so no `text_multichoice` question can ever reach a session, regardless of what content is approved. This issue flips that switch and locks the serializer contract so MCQ payloads survive the trip to iOS.

Everything downstream is already in place:
- Evaluator MCQ fast-path routes on `question.possible_answers` (`apps/quiz-agent/app/evaluation/evaluator.py:77`, tested in `tests/test_mcq_evaluator.py`).
- `question_to_dict` already passes `possible_answers` (`apps/quiz-agent/app/serializers.py:20`).
- Generation drops MCQ questions missing options (#42 task 42.9), and the converted batch (42.11) populates options.

## Tasks

- [x] **49.1 Retriever: allow `text_multichoice`.** Add `"text_multichoice"` to `allowed_types` in `_build_metadata_filters` (`apps/quiz-agent/app/retrieval/question_retriever.py:212`). New test file `apps/quiz-agent/tests/test_question_retriever_filters.py` calling `_build_metadata_filters` directly with a minimal `QuizSession`.
      **Acceptance:** test asserts the `type.$in` filter contains exactly `{"text", "image", "text_multichoice"}` and that `review_status == "approved"` is still enforced. Test docstring states the intent: the launch decision requires MCQ retrievable — a type filter missing `text_multichoice` silently disables MCQ end-to-end even with approved MCQ content in pgvector. `cd apps/quiz-agent && pytest tests/ -v` fully green.

- [x] **49.2 Serializer contract lock for MCQ.** Add a test (extend `apps/quiz-agent/tests/test_question_retriever_filters.py` or a small dedicated test file — whichever reads better) that builds a `Question` with `type="text_multichoice"` and `possible_answers={"a": ..., "b": ..., "c": ..., "d": ...}` / `correct_answer="b"`, runs it through `question_to_dict` (`apps/quiz-agent/app/serializers.py`), and asserts `type` and `possible_answers` survive intact. No production-code change expected — this is a regression lock.
      **Acceptance:** test encodes why it matters (iOS selects `MCQOptionPicker` on `type` and renders `possible_answers`; a serializer that drops either turns an MCQ into a broken free-form question — same bug class as the `generated_by`/`headline_answer` serializer bugs fixed in `16161de`). `cd apps/quiz-agent && pytest tests/ -v` fully green.

## Scope guards (rule #1 — keep it small)

- **No retrieval-time guard** for MCQ questions missing `possible_answers` — generation already drops those (#42.9) and the evaluator falls through to LLM evaluation safely (`tests/test_mcq_evaluator.py::test_text_multichoice_with_none_options_falls_through_to_llm`). Don't add it.
- **Don't touch** quiz-pack-api, prompts, or `packages/shared` models — the generation side is done (#42).
- **Out of scope (human/content):** approving the converted MCQ batch in the DB; iOS tasks 45.7–45.13; deploy (founder triggers per `feedback_backend_auto_deploy`).

## Success criteria

- A quiz session with approved `text_multichoice` content in pgvector can be served an MCQ question (filter no longer excludes it), and the serialized payload carries `type` + `possible_answers` for iOS.
- Full quiz-agent suite green (98 tests before this issue; expect +2 or more after).
