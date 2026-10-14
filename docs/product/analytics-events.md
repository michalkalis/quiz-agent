# Analytics Events — Quiz Agent

> **Tool: own Postgres table `analytics_events`** (quiz-agent DB) — decision revised 2026-10-07 in issue #51 (product analytics); Sentry stays for crashes/health only.
> **Allowlist in code:** `apps/quiz-agent/app/analytics/taxonomy.py` is the source of truth — names and property keys not listed there are dropped, never stored. Change both together.
> **No PII:** no transcript or answer text, no names/emails. Identity = the anonymous/account `subject_id` (same id `daily_usage` uses). Rows are deleted on account erase.
> **Viewing:** ask Claude to query the table (recipes below). Dashboard deferred.
> Founder-approved: original 10 events 2026-07-14; extra groups (money, voice & controls, usage context, first run) 2026-10-07; automatic voice-settings test (#204 task 204.9) 2026-10-14.

## Server events (emitted by the API — where the truth lives)

| Event | When | Properties |
|---|---|---|
| `quiz_started` | first question served (`routes/quiz.py` start_quiz) | `category`, `language`, `difficulty`, `mode`, `is_pack`, `max_questions` |
| `answer_evaluated` | first grade of a question (`quiz/flow.py` process_answer) | `question_id`, `result` (correct / incorrect / partially_correct / skipped …), `category`, `question_type`, `difficulty`, `route` (voice / text), `is_regrade`, `question_index` |
| `quiz_completed` | session → finished | `reason` (max_questions / usage_limit / no_more_questions), `questions_asked`, `score`, `is_pack` |
| `quota_hit` | the monthly limit (free 30 or Trubbo Plus 1,000) blocks a start or the next question | `stage` (start / mid_quiz), `questions_used`, `questions_limit`, `plan` (plus / free) |
| `transcription_failed` | server rejects a voice upload as no speech | `reason`, `question_id` |
| `store_event` | every RevenueCat webhook (purchase, renewal, cancellation, expiration, refund …) | `type`, `product_id`, `environment`, `store`, `period_type` |

## App events (posted to `POST /api/v1/analytics/events` — only what the server cannot see)

| Event | When | Properties |
|---|---|---|
| `app_opened` | app launch / return to foreground | `launch` (cold / foreground) |
| `onboarding_finished` | onboarding completed or skipped (replay from Settings emits again) | `outcome` (mic_granted / mic_denied / mic_later / skipped), `step` |
| `quiz_context` | right after a quiz starts | `audio_route` (carplay / bluetooth / speaker / headphones / …), `voice_commands_enabled`, `entry_point` |
| `quiz_abandoned` | quiz ended by the player before finishing | `questions_answered`, `phase` |
| `answer_submitted` | player submits an answer | `input_mode` (voice / tap / typed), `question_id`, `is_retry` |
| `voice_capture_failed` | on-device capture fails (server rejections are `transcription_failed`) | `reason` (too_short / empty_transcript / stt_timeout / stt_commit_failed / recorder_failed), `question_id` |
| `voice_command` | a voice command is recognised | `command` (next / skip / repeat / pause / stop …), `phase` |
| `paywall_viewed` | paywall shown | `source` (quota / home / settings / completion) |
| `purchase_result` | purchase attempt ends | `product_id`, `kind` (subscription / credits / custom_pack), `outcome` (success / cancelled / failed / pending) |
| `restore_result` | restore purchases ends | `outcome` |
| `answer_captured` | every recorded voice answer (#204.9 voice-settings test) | `question_id`, `is_retry`; test: `auto_test`, `src_neural_vad` / `src_aec` / `src_front_mic` (auto = set by the server's coin, manual = the player's switch), effective `neural_vad` / `aec` / `front_mic`, `exp_gen_neural_vad` / `exp_gen_aec` / `exp_gen_front_mic` (test generation, auto only); route: `route_group` (bt_car / other), `output_route`, `input_route`; capture: `stop_reason` (vad / noSpeechWindow / cap / manual), `detector`, `heard_speech`, `speech_ms`, `end_delay_ms`, `duration_ms`; mic: `voice_processing`, `ec_enabled`, `aec_applicable`, `front_mic_applicable`, `mic_data_source`, `mic_polar_pattern`; `rejected_count` (transcripts already rejected for this question) |
| `voice_experiment_guard` | the app switched echo cancellation off mid-round because the sound left the car (#204.9) | `flag` (aec), `reason` (output_route_changed), `from_route`, `to_route`, `exp_gen` |

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
| Voice first-try capture | per (session_id, question_id) with a voice attempt: first try succeeded = no `voice_capture_failed` / `transcription_failed` for that pair AND its `answer_submitted` voice row has is_retry = false. (A server-rejected upload also logs `answer_submitted`, so never use that event alone as the success count.) |
| Skip rate | `answer_evaluated` result = skipped ÷ all |
| DAU / retention | distinct `subject_id` per day on `app_opened` (D1/D7/D30 cohorts by first `app_opened`) |
| Paywall conversion | `purchase_result` outcome = success ÷ `paywall_viewed`, by `source` |
| Quota pressure | `quota_hit` per subject per month; share followed by `paywall_viewed` / purchase |
| Usage context | `quiz_context.audio_route` mix (car vs. home vs. party) |
| Voice command usage | `voice_command` counts by `command` |
| Voice-settings test (#204.9) | per setting × `route_group`, answers where the coin decided it: bad capture = `stop_reason` = cap OR `heard_speech` = false OR rejected (a later `answer_captured` of the same session + question has a higher `rejected_count`); compare the rate between the ON and OFF arms. The weekly job (`POST /api/v1/admin/voice-experiment/evaluate`) does this; SQL below for ad-hoc checks |

Bad-capture rate per arm, here neural VAD on the car / Bluetooth route, generation 1. For `aec` / `front_mic` swap the flag keys and add `AND (c.p->>'aec_applicable')::boolean` (or `front_mic_applicable`):

```sql
WITH cap AS (
  SELECT session_id, occurred_at, properties AS p
  FROM analytics_events WHERE name = 'answer_captured'
), arm AS (
  SELECT (c.p->>'neural_vad')::boolean AS arm_on,
         (c.p->>'stop_reason' = 'cap'
          OR c.p->>'heard_speech' = 'false'
          OR EXISTS (SELECT 1 FROM cap l
                     WHERE l.session_id = c.session_id
                       AND l.p->>'question_id' = c.p->>'question_id'
                       AND l.occurred_at > c.occurred_at
                       AND COALESCE((l.p->>'rejected_count')::int, 0)
                         > COALESCE((c.p->>'rejected_count')::int, 0))) AS bad
  FROM cap c
  WHERE c.p->>'src_neural_vad' = 'auto'
    AND (c.p->>'exp_gen_neural_vad')::int = 1
    AND c.p->>'route_group' = 'bt_car'
)
SELECT arm_on, count(*) AS n, count(*) FILTER (WHERE bad) AS bad,
       round(avg(bad::int), 3) AS bad_rate
FROM arm GROUP BY arm_on;
```

Always filter `app_version` / `environment` when sandbox or TestFlight noise matters.
