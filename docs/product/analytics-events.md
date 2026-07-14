# Analytics Events — Quiz Agent

> Tool: **Sentry** (org `missinghue` / project `carquiz`). Decision recorded in issue #51 and launch decision #11.
> Sentry mechanism: **custom event** (`sentry_sdk.capture_event()` backend; `SentrySDK.capture(event:)` iOS).
> SDK versions verified: sentry-sdk ≥ 2.0.0 (backend `pyproject.toml:17`); sentry-cocoa (iOS Xcode SPM ref confirmed in `project.pbxproj`).
> No-PII rule: no transcript text, no audio references. `question_id` + `category` + `question_type` + `result` are safe per #50 privacy labels.

---

## Event Table

| Event | Exact Trigger (file:function, line) | Properties | PRD Metric | Emitter |
|---|---|---|---|---|
| `quiz_started` | iOS `ViewModels/QuizViewModel.swift:355` — `startNewQuiz()` → `transition(to: .startingQuiz)` | `session_id`, `category` | Completion rate — numerator; #49 daily-active (distinct `session_id` per day) | iOS |
| `quiz_completed` | iOS `ViewModels/QuizViewModel.swift:923` — `transition(to: .finished)` (auto-advance after last result) | `session_id`, `questions_answered` | Completion rate — completed denominator | iOS |
| `quiz_abandoned` | iOS `ViewModels/QuizViewModel.swift:722` — `resetToHome()`, emitted only when `quizState ∉ {.idle, .finished}` before the reset | `session_id`, `questions_answered` | Completion rate — abandoned denominator | iOS |
| `question_presented` | iOS `ViewModels/QuizViewModel.swift:416` (first question) and `:937` (each subsequent) — both → `transition(to: .askingQuestion)` | `session_id`, `question_id`, `question_index`, `question_type` | Voice reliability — denominator (each presentation is one capture opportunity); #49 cost model (questions-per-session) | iOS |
| `answer_captured` | iOS `ViewModels/QuizViewModel+Recording.swift:197` (batch path) and `:277` (silence-detect path) — both → `transition(to: .processing)` after recording stops | `session_id`, `question_id`, `is_retry` (bool — true if called from `resubmitAnswer()`) | Voice reliability — numerator (audio reached server for evaluation) | iOS |
| `answer_retry` | iOS `ViewModels/QuizViewModel+Recording.swift:431` — `resubmitAnswer()` entry | `session_id`, `question_id` | Voice reliability — retry count (complement to first-try rate) | iOS |
| `transcription_failed` | Backend `apps/quiz-agent/app/api/routes/voice.py:190` — `transcribe_and_submit()` except block, after `RuntimeError` from `app/voice/transcriber.py:249` | `session_id` (from request query param), `error_type` (exception class name) | Voice reliability — failure path (counts against first-try capture rate) | Backend |
| `answer_correct` | Backend `apps/quiz-agent/app/quiz/flow.py:140` — `process_answer()` after `answer_evaluator.evaluate()` returns `"correct"` | `session_id`, `question_id`, `category`, `question_type`, `difficulty` | Wrong-answer rate — correct count | Backend |
| `answer_incorrect` | Backend `apps/quiz-agent/app/quiz/flow.py:140` — `process_answer()` after `answer_evaluator.evaluate()` returns `"incorrect"` | `session_id`, `question_id`, `category`, `question_type`, `difficulty` | Wrong-answer rate — incorrect count | Backend |
| `quota_hit` | Backend `apps/quiz-agent/app/quiz/flow.py:250` — `process_answer()`, after `usage_tracker.check_limit()` (called `:247`) returns `allowed=False` (mid-quiz gate); same rejection shape also raised at `apps/quiz-agent/app/api/routes/quiz.py:65` — `start_quiz()`, after `check_limit()` (called `:62`) returns `allowed=False` (new-session gate) | `session_id`, `questions_used`, `questions_limit` | #49 cost model — quota/limit tuning signal; upgrade-funnel volume (#93 monetization) | Backend |

---

## PRD Metric Derivations (Sentry Discover queries)

| PRD Metric | Derivation |
|---|---|
| **Completion rate** | `count(quiz_completed)` / `count(quiz_started)` grouped by day. Abandon rate = `count(quiz_abandoned)` / `count(quiz_started)`. |
| **Voice reliability — first-try capture rate** | Among `answer_captured` events: fraction where `is_retry = false` AND no prior `transcription_failed` for that (`session_id`, `question_id`) pair. Approximation: `count(answer_captured where is_retry=false)` / `count(question_presented)`. |
| **Wrong-answer rate** | `count(answer_incorrect)` / (`count(answer_correct)` + `count(answer_incorrect)`). Slice by `category`, `question_type`, or `difficulty` tags. |
| **#49 cost model: questions/session** | `count(question_presented)` grouped by `session_id`, then avg/p50 across sessions per day. |
| **#49 cost model: daily active** | `count_unique(session_id)` on `quiz_started` grouped by day. |

---

## Property Field Mapping

| Property | iOS source | Backend source | Notes |
|---|---|---|---|
| `session_id` | `currentSession?.sessionId` | `session.id` (from `QuizSession`) | Low-cardinality grouping key — use as Sentry tag |
| `question_id` | `currentQuestion?.id` | `evaluated_question_id` (`flow.py:114`) | High-cardinality — use as Sentry extra, not tag |
| `category` | `currentSession?.category` | `current_question.category` | Sentry tag — indexed for slice-by-category |
| `question_type` | `currentQuestion?.type.rawValue` (`Question.swift:14`, `QuestionType` enum at `:150`) | `current_question.question_type` (`question.py:111`) | Sentry tag — values: `text`, `mcq`, `image` |
| `difficulty` | n/a (backend only for answer events) | `current_question.difficulty` (`question.py:115`) | Sentry tag — values: `easy`, `medium`, `hard` |
| `questions_answered` | `questionsAnswered` (`QuizViewModel.swift:107`) | n/a | Sentry extra |
| `is_retry` | bool: true when emitting from `resubmitAnswer()` path | n/a | Sentry tag |
| `error_type` | n/a | `type(e).__name__` from caught exception | Sentry tag — backend only |
| `question_index` | `questionsAnswered` at time of `transition(to: .askingQuestion)` | n/a | Sentry extra |
| `questions_used` | n/a | `usage["questions_used"]` (`tracker.py:252`/`:262`, from `get_usage()`) | Sentry extra — backend only |
| `questions_limit` | n/a | `usage["questions_limit"]` (`tracker.py:263`; free-tier constant, currently `30`) | Sentry tag — backend only, low-cardinality |

---

## Scope guards (from issue #51)

- These 10 events are the complete set (6 iOS, 4 backend) — no additional events without a named PRD metric or #49/#50 link.
- No transcript text, no audio blobs, no user identifiers in any property.
- Privacy labels (#50) and this table must agree before 51.3/51.4 ship.
- Do not add a parallel state source; hook the existing transitions listed above.
