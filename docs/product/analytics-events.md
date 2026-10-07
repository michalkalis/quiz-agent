# Analytics Events — Quiz Agent

> **Tool: own Postgres table `analytics_events`** (quiz-agent DB) — decision revised 2026-10-07 in issue #51 (product analytics); Sentry stays for crashes/health only.
> **Allowlist in code:** `apps/quiz-agent/app/analytics/taxonomy.py` is the source of truth — names and property keys not listed there are dropped, never stored. Change both together.
> **No PII:** no transcript or answer text, no names/emails. Identity = the anonymous/account `subject_id` (same id `daily_usage` uses). Rows are deleted on account erase.
> **Viewing:** ask Claude to query the table (recipes below). Dashboard deferred.
> Founder-approved: original 10 events 2026-07-14; extra groups (money, voice & controls, usage context, first run) 2026-10-07.

## Server events (emitted by the API — where the truth lives)

| Event | When | Properties |
|---|---|---|
| `quiz_started` | first question served (`routes/quiz.py` start_quiz) | `category`, `language`, `difficulty`, `mode`, `is_pack`, `max_questions` |
| `answer_evaluated` | first grade of a question (`quiz/flow.py` process_answer) | `question_id`, `result` (correct / incorrect / partially_correct / skipped …), `category`, `question_type`, `difficulty`, `route` (voice / text), `is_regrade`, `question_index` |
| `quiz_completed` | session → finished | `reason` (max_questions / usage_limit / no_more_questions), `questions_asked`, `score`, `is_pack` |
| `quota_hit` | free limit blocks a start or the next question | `stage` (start / mid_quiz), `questions_used`, `questions_limit` |
| `transcription_failed` | server rejects a voice upload as no speech | `reason`, `question_id` |
| `store_event` | every RevenueCat webhook (purchase, renewal, cancellation, expiration, refund …) | `type`, `product_id`, `environment`, `store`, `period_type` |

## App events (posted to `POST /api/v1/analytics/events` — only what the server cannot see)

| Event | When | Properties |
|---|---|---|
| `app_opened` | app launch / return to foreground | `launch` (cold / foreground) |
| `onboarding_finished` | onboarding completed or skipped | `outcome`, `step` |
| `quiz_context` | right after a quiz starts | `audio_route` (carplay / bluetooth / speaker / headphones / …), `voice_commands_enabled`, `entry_point` |
| `quiz_abandoned` | quiz ended by the player before finishing | `questions_answered`, `phase` |
| `answer_submitted` | player submits an answer | `input_mode` (voice / tap / typed), `question_id`, `is_retry` |
| `voice_capture_failed` | on-device capture/recognition fails | `reason`, `question_id` |
| `voice_command` | a voice command is recognised | `command` (next / skip / repeat / pause / stop …), `phase` |
| `quiz_minimized` | quiz minimised | `phase` |
| `paywall_viewed` | paywall shown | `source` (quota / home / settings / completion) |
| `purchase_result` | purchase attempt ends | `product_id`, `kind` (subscription / credits / custom_pack), `outcome` (success / cancelled / failed / pending) |
| `restore_result` | restore purchases ends | `outcome` |

## Already in other tables — query there, don't duplicate

- Custom pack orders and delivery: `generation_orders` (status, created/delivered timestamps).
- Question ratings / flags: `question_ratings`. In-app feedback: `feedback`.
- Questions per subject per day: `daily_usage`.

## Metric recipes (SQL against `analytics_events`)

| Metric | Derivation |
|---|---|
| Completion rate | sessions with `quiz_completed` (reason ≠ usage_limit) ÷ sessions with `quiz_started`, per day |
| Abandon rate | `quiz_abandoned` sessions ÷ `quiz_started` sessions |
| Wrong-answer rate | `answer_evaluated` result = incorrect ÷ all graded (exclude skipped), sliced by category / question_type / difficulty |
| Voice first-try capture | `answer_submitted` (input_mode = voice, is_retry = false) ÷ (that + `voice_capture_failed` + `transcription_failed`) |
| Skip rate | `answer_evaluated` result = skipped ÷ all |
| DAU / retention | distinct `subject_id` per day on `app_opened` (D1/D7/D30 cohorts by first `app_opened`) |
| Paywall conversion | `purchase_result` outcome = success ÷ `paywall_viewed`, by `source` |
| Quota pressure | `quota_hit` per subject per month; share followed by `paywall_viewed` / purchase |
| Usage context | `quiz_context.audio_route` mix (car vs. home vs. party) |
| Voice command usage | `voice_command` counts by `command` |

Always filter `app_version` / `environment` when sandbox or TestFlight noise matters.
