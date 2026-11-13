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
| `answer_evaluated` | grade of a question: first grade (`quiz/flow.py` process_answer) and again on every re-grade of an edited answer (`quiz/resubmission.py`, `is_regrade` = true; consumers keep the latest row per `session_id` + `question_id`) | `question_id`, `result` (correct / incorrect / partially_correct / skipped …), `category`, `question_type`, `difficulty`, `route` (voice / text), `is_regrade`, `question_index`; voice route stage durations in ms (#208.3): `stt_ms`, `parse_ms`, `judge_ms`, `feedback_tts_ms` (only when feedback audio was synthesized) |
| `quiz_completed` | session → finished | `reason` (max_questions / usage_limit / no_more_questions), `questions_asked`, `score`, `is_pack` |
| `quota_hit` | the monthly limit (free 30 or Trubbo Plus 1,000) blocks a start or the next question | `stage` (start / mid_quiz), `questions_used`, `questions_limit`, `plan` (plus / free) |
| `transcription_failed` | server rejects a voice upload as no speech | `reason`, `question_id` |
| `room_created` | a host turns an idle session into a game together (#212.5); not on a retried create | `room_id` |
| `room_joined` | a guest joins a game for the first time (#212.5), under the guest; a rejoin (name change) is not counted | `room_id`, `via` (nearby = the Wi-Fi list / qr = scanned code / link = shared link, also builds that do not send it) |
| `room_finished` | a game together ends (#212.5), under the host, next to its `quiz_completed` | `room_id`, `reason`, `players` (incl. host), `questions_asked` |
| `room_with_pack` | a host's finished custom pack becomes a game together (#232.2), next to its `room_created` | `room_id` |
| `quiz_shared` | a player creates a "play my quiz" link (#232); not when the same session or pack is shared again (same link back) | `kind` (round / daily / pack), `language`, `question_count` |
| `shared_quiz_opened` | a shared-quiz link is opened: in the app when the player starts it (under that player), or on the website's play page (anonymous) | `kind`, `source` (app / web) |
| `shared_quiz_finished` | a session started from a shared link finishes and records a result (#232); once per session, under the player (or host of a game together) | `kind`, `players` (results recorded), `questions_asked` |
| `store_event` | every RevenueCat webhook (purchase, renewal, cancellation, expiration, refund …) | `type`, `product_id`, `environment`, `store`, `period_type` |

## App events (posted to `POST /api/v1/analytics/events` — only what the server cannot see)

| Event | When | Properties |
|---|---|---|
| `app_opened` | app launch / return to foreground | `launch` (cold / foreground) |
| `onboarding_finished` | onboarding completed or skipped (replay from Settings emits again) | `outcome` (mic_granted / mic_denied / mic_later / skipped), `step` |
| `quiz_context` | right after a quiz starts | `audio_route` (carplay / bluetooth / speaker / headphones / …), `voice_commands_enabled`, `entry_point`, `timezone` (IANA id, e.g. Europe/Bratislava; local time of day from UTC `occurred_at`), `quick_game` (the Home quick-game switch was on, #224.8; absent on older builds) |
| `quiz_abandoned` | quiz ended by the player before finishing | `questions_answered`, `phase` |
| `answer_submitted` | player submits an answer | `input_mode` (voice / tap / typed), `question_id`, `is_retry`, `latency_ms` (ms from when the player could answer to speech onset or tap/submit, pauses excluded; left out on retries or when unknown) |
| `voice_capture_failed` | on-device capture fails (server rejections are `transcription_failed`) | `reason` (too_short / empty_transcript / stt_timeout / stt_commit_failed / recorder_failed), `question_id` |
| `voice_command` | a voice command is recognised | `command` (next / skip / repeat / pause / stop …), `phase` |
| `paywall_viewed` | paywall shown | `source` (quota / home (builds ≤ 81) / profile (#216.3, the plan card moved there) / settings / completion) |
| `purchase_result` | purchase attempt ends | `product_id`, `kind` (subscription / credits / custom_pack), `outcome` (success / cancelled / failed / pending), `question_count` (custom_pack only, from #228.6: the size bought, 10 or 30) |
| `restore_result` | restore purchases ends | `outcome` |
| `sign_in_prompt_shown` | the sign-in prompt after a purchase comes on screen (#217.4), for a signed-out buyer, at most twice ever | `kind` (plus / credit / custom_pack) |
| `sign_in_prompt_result` | that prompt closes (#217.4) | `kind`, `outcome` (signed_in / dismissed; a swipe down is dismissed) |
| `profile_opened` | the Profile tab comes on screen (#213.4) | `has_account` (signed in with Apple) |
| `recap_viewed` | a recap story closes (#213.5); builds ≤ 81 only, #216.3 replaced the story with a Profile card | `kind` (first / month / year), `slides_seen` (furthest slide reached), `slides_total` |
| `recap_shared` | the share sheet opens on the recap's last slide (#213.5) or, from #216.3, on the Profile's recap card; whether the player then posts it is not known | `kind` |
| `together_opened` | the Together tab comes on screen (#216.2); with `room_created` / `room_joined` it shows how many who look at the tab go on to play | — |
| `shared_quiz_pasted` | the first-launch "quiz from a friend?" paste button was used (#232) | `outcome` (opened / not_a_link) |
| `room_settings_changed` | the host of a game together changed a rule and the server accepted it (#213.8); one per change | `setting` (reveal_mode / thinking_seconds / reads_aloud), `value` (question / round, 15 / 30 / 45 / 60, true / false), `surface` (lobby / in_game) |
| `room_guest_read_aloud` | a guest of a game together switched reading aloud on their own phone on or off (#230.2) | `on` (true / false), `via` (nearby / qr / link) |
| `room_pause_changed` | the host of a game together stayed on a reveal or resumed (#224.4); the server accepted it | `paused` (true / false), `question` (number) |
| `home_category_stepped` | a step on the Home category deck (#224.6): one per tap or VoiceOver adjust | `direction` (next / previous), `input` (tap / voiceover), `to` (category id, or `all`) |
| `home_category_picker_opened` | the multi-category picker opened on Home (#224.6) | `source` (deck_button / pill) |
| `quick_game_changed` | the Home "Quick quiz" switch flipped (#224.8) | `enabled` |
| `question_skipped` | a question skipped by button or voice, the skip request accepted for sending (#224.8) | `quick` (the quick quiz was on) |
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
| Game together (#212.5, verdict 4 weeks after the switch goes on) | games = `room_created`; played = `room_finished` with `players` ≥ 2; joins by `room_joined.via` (many games without guests or mostly link joins = guests cannot find the game, see 212.6); new player = a `room_joined` guest whose first `app_opened` is at most 24 h before the join; later solo game = a `quiz_started` by that guest after the join (a guest never starts a session inside a game) |
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
