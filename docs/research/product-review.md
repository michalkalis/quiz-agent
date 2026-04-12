# CarQuiz Product Review

**Date:** 2026-04-03
**Reviewer:** Claude (comprehensive code-level review)
**Scope:** Full iOS app + backend, voice-first driving UX, edge cases, multiplayer readiness

---

## 1. Full Flow Analysis

### 1.1 First Launch (Onboarding)

The app shows a 3-page onboarding (`OnboardingView.swift`) covering voice answering, hands-free features, and microphone permission. The onboarding is well-structured with skip option and page indicators.

**Issue:** The onboarding only describes English voice commands ("skip", "repeat", "score", "help"). Users who set Slovak or another language immediately will not know whether voice commands work in their language. Voice commands are hardcoded to English keyword matching (`VoiceCommand.match()` in `VoiceCommand.swift:50-68`) regardless of quiz language setting.

### 1.2 Home Screen

`HomeView.swift` presents a clean layout: app logo, quick settings (language, difficulty, category), usage badge, and Start Quiz / More Settings buttons. Settings use dropdown menus which are accessible but require precise tap targets.

**Flow:** On appear, refreshes audio devices and usage info. The "Start Quiz" button triggers `startNewQuiz()` which creates a session, starts the quiz, gets the first question, starts voice commands, and plays question audio. This is a ~3-5 second wait with only a loading spinner on the button.

### 1.3 Question Screen

`QuestionView.swift` is the core interaction screen with:
- Top bar: voice command indicator, repeat button, mute toggle, close button
- Error banner (shown inline above question)
- Question card (text or image via `ImageQuestionView`)
- For MCQ: option picker + skip button
- For voice: thinking time badge, answer timer badge, live transcript, mic button, skip + type-answer buttons

**State machine:** `idle -> startingQuiz -> askingQuestion -> recording -> processing -> showingResult -> (next question or finished)`

After TTS reads the question, the flow depends on settings:
- **Auto-record enabled (default):** Thinking time countdown (default 60s) -> auto-start recording -> silence detection or manual stop -> confirmation modal -> submit
- **Auto-record disabled:** Answer timer countdown -> manual tap to record -> stop and submit

### 1.4 Answer Confirmation

`AnswerConfirmationView.swift` shows as a `.medium` detent sheet with the transcribed answer, Confirm and Re-record buttons. With auto-confirm enabled (default), a 10-second countdown auto-submits. The sheet is `interactiveDismissDisabled` to prevent accidental dismissal.

### 1.5 Result Screen

`ResultView.swift` shows evaluation result (correct/incorrect/partial/skipped), user answer vs correct answer, explanation card, source attribution with web view, question rating (1-5 stars), and a sticky bottom bar with Continue button + auto-advance countdown + Stay Here option.

Auto-advance timer (default 8s) starts after feedback audio finishes. User can pause with "Stay Here" or manually continue.

### 1.6 Completion Screen

`CompletionView.swift` shows trophy icon, final score with accuracy percentage, stats cards (correct/missed/total), streak and best streak if applicable, and Play Again / Back to Home buttons.

### 1.7 Settings Screen

`SettingsView.swift` is accessed via "More Settings" from home. Contains collapsible sections for Quiz Settings (language, question count, difficulty) and Audio Settings (voice commands, auto-record, barge-in, auto-confirm, audio mode, microphone, auto-advance timer, answer time limit, thinking time). Also shows question history with reset option.

---

## 2. Voice-First UX Assessment

### 2.1 What Works Well

**Hands-free loop (happy path):** TTS reads question -> thinking time countdown -> auto-record starts -> user speaks -> silence detection auto-stops recording -> auto-confirm submits -> feedback audio plays -> auto-advance to next question. This loop requires zero taps once the quiz starts, which is excellent for driving.

**Voice commands:** "skip", "repeat", "score", "help", "start", "stop", "ok", "again", "home", and MCQ options "a"/"b"/"c"/"d". Covers the essential interactions.

**Barge-in:** On external audio routes (Bluetooth/CarPlay), speaking during TTS interrupts playback and starts recording. Smart echo cancellation via word-overlap detection prevents false triggers.

**Error escalation:** 3-tier system for transcription failures (gentle retry -> speak closer hint -> auto-skip) prevents the user from getting stuck.

### 2.2 Friction Points

**F1: Voice commands are English-only** (`VoiceCommand.swift:50-68`)
Voice command matching uses hardcoded English words ("skip", "repeat", etc.). A Slovak user must say English keywords even when their quiz language is Slovak. This is a significant voice-first UX gap. The `VoiceCommandService` also hardcodes `Locale(identifier: "en_US")` for the speech recognizer (`VoiceCommandService.swift:128`), meaning it may poorly recognize commands spoken with a non-English accent.

**F2: No voice command for "Continue" on result screen**
After seeing the result, the only voice-activated path is auto-advance. There is no voice command to manually continue to the next question. If the user paused auto-advance (said nothing or the timer was paused), they must tap "Continue". The `handleVoiceCommand` function (`QuizViewModel.swift:1871-1954`) has no command for advancing from the result screen.

**F3: 60-second default thinking time is very long**
The default `thinkingTime` of 60 seconds (`QuizSettings.swift:74,111`) means after TTS finishes, the user waits a full minute before auto-recording starts. For a driving scenario where the user wants a quick quiz, this creates dead air. A 10-15 second default would be more appropriate.

**F4: Confirmation modal blocks hands-free flow**
Even with auto-confirm (10 seconds), the confirmation sheet (`AnswerConfirmationView`) is a visual-only interaction that adds latency. For a driving user who cannot look at the screen, the 10-second wait adds ~10s to every answer cycle. The `showConfirmSheet` setting exists in `QuizSettings` but there is no path that bypasses the sheet -- `confirmAnswer()` at line 803 always requires the confirmation modal to have been shown.

**F5: No audio feedback for state transitions**
When auto-record starts, there is no audio cue (beep/tone) telling the driver "start speaking now." The only indication is a visual hint text change ("Listening..." -> "Recording..."). Similarly, when thinking time expires and recording begins, there is no audible signal. For eyes-on-road driving, this is a critical gap.

**F6: Mute toggle stops TTS but still requires visual interaction**
When muted (`settings.isMuted`), question TTS is skipped but the question is still only shown visually (`QuestionView.swift` question card). A muted user who is driving has no way to know the question. The mute feature effectively breaks the hands-free flow.

### 2.3 Audio Architecture Assessment

The dual audio mode system (Call Mode with HFP for Bluetooth mic vs Media Mode with A2DP only) is well-designed. The 200ms hardware settle time before recording (`AudioService.swift:385`) and 3-attempt retry logic for recording start (`AudioService.swift:416-434`) show good real-world robustness. Audio interruption handling (phone calls, Siri) properly stops recording and playback.

---

## 3. Error Handling UX

### 3.1 Network Errors

**Quiz start failure:** Shows error state with message and returns to home. Error is announced via local TTS (`setError` at `QuizViewModel.swift:913-916`), which is good for hands-free awareness.

**Answer submission failure:** Shows inline error banner in QuestionView. The 30-second timeout (`QuizViewModel.swift:670`) with `TimeoutError` gracefully handles slow connections.

**Session expiry:** Backend returns 404 for expired sessions. The iOS `endSession()` handles 404 via `NetworkError.sessionNotFound`, but `submitVoiceAnswer` and `submitTextInput` throw generic `NetworkError.invalidResponse` for 404, which means a stale session mid-quiz shows "Invalid server response" instead of a helpful "Session expired" message.

### 3.2 STT Failures

The streaming STT (ElevenLabs) gracefully falls back to batch Whisper on setup failure (`QuizViewModel.swift:505-516`). The 3-tier error escalation (`handleTranscriptionFailure` at line 922-943) is excellent -- gentle retry, hint, then auto-skip prevents infinite loops.

### 3.3 Audio Failures

Question audio playback failures are silently swallowed (`QuizViewModel.swift:1690-1694`) with "Don't fail the quiz if audio doesn't play." This is correct -- the question text is always visible. However, for a driving user who relies entirely on TTS, a silent failure means they miss the question entirely with no retry mechanism.

### 3.4 Recording Failures

`startBatchRecording()` catches errors and reverts to `askingQuestion` state with inline error message. The minimum recording size check (500 bytes at `AudioService.swift:476-483`) catches corrupt recordings. However, `AudioError.recordingTooShort` is shown as a generic error message without suggesting the user try again.

### 3.5 Missing Error Scenarios

**E1: No handling for backend down during quiz.** If the backend goes offline mid-quiz, every network call fails independently. There is no circuit breaker or "backend unavailable" detection that would prevent repeated failed calls.

**E2: No handling for question history at capacity mid-quiz.** The `addQuestionId` call in `handleQuizResponse` (`QuizViewModel.swift:1477-1488`) catches `capacityReached` but only logs it. The quiz continues but the question is not saved to history, causing future duplicates.

---

## 4. Settings Discoverability

### 4.1 Quick Settings on Home Screen

Language, difficulty, and category are surfaced as quick settings on the home screen, which is good. These are the most commonly changed settings.

### 4.2 Problems

**S1: Too many settings in Audio Settings section.** The Audio Settings section in `SettingsView.swift` contains 8 settings (voice commands, auto-record, barge-in, auto-confirm, audio mode, microphone, auto-advance, answer time limit, thinking time). For a voice-first app designed for simplicity, this is overwhelming. Many of these settings interact with each other (auto-record requires voice commands; barge-in requires external audio route).

**S2: No settings presets.** There is no "Driving Mode" vs "Casual Mode" preset that would set all audio-related settings to optimal values at once. A first-time user must understand and configure 8+ settings individually.

**S3: Confusing relationship between thinking time and answer time limit.** Thinking time (delay before recording) and answer time limit (countdown to auto-start recording when auto-record is disabled) serve similar purposes but for different modes. Both appear in settings regardless of whether auto-record is enabled, creating confusion.

**S4: No category description.** The category options "Adults" and "General" have no description of what content they include. A user cannot make an informed choice.

### 4.3 Defaults Assessment

| Setting | Default | Assessment |
|---------|---------|------------|
| Language | English | Good |
| Difficulty | Medium | Good |
| Category | All | Good |
| Questions | 10 | Good for driving (~15-20 min) |
| Voice Commands | On | Good |
| Auto-Record | On | Good |
| Barge-In | On | Good |
| Auto-Confirm | On | Good, but 10s delay is long |
| Audio Mode | Media | Reasonable but means no Bluetooth mic by default |
| Auto-Advance | 8s | Good |
| Answer Time Limit | 30s | OK when auto-record is off |
| Thinking Time | 60s | **Too long** -- creates dead air after question is read |

---

## 5. New Issues Found (Beyond the 13 Reported)

### P0: Critical

**NEW-01: Voice commands do not work in non-English languages**
`VoiceCommandService.swift:128` hardcodes `Locale(identifier: "en_US")` for the speech recognizer. `VoiceCommand.match()` at `VoiceCommand.swift:50-68` matches against English keywords only. A Slovak user must speak English words to control the quiz, breaking the hands-free promise.
Files: `VoiceCommandService.swift:128`, `VoiceCommand.swift:44-68`

**NEW-02: No audio cue when recording starts/stops**
A driving user has no audible indication that recording has started (after thinking time) or stopped (after silence detection). The only feedback is visual text changes. This means the user may speak before recording starts or after it stops, losing their answer.
Files: `QuizViewModel.swift:430-465` (startRecording), `QuizViewModel.swift:614-647` (stopRecordingAndSubmit)

### P1: High Impact

**NEW-03: No voice command to advance from result screen**
The voice command handler (`QuizViewModel.swift:1871-1954`) has no command mapped to "continue" or "next" when in `showingResult` state. A user who paused auto-advance must tap the screen to continue.
Files: `QuizViewModel.swift:1871-1954`

**NEW-04: Session expiry mid-quiz shows unhelpful error**
When a backend session expires (after 30 min TTL), subsequent API calls to `submitVoiceAnswer` or `submitTextInput` return HTTP 404. The iOS client decodes this as `NetworkError.invalidResponse` ("Invalid server response") instead of detecting the expired session and offering to restart.
Files: `NetworkService.swift:301-329` (submitVoiceAnswer has no 404 handling), `NetworkService.swift:361-378` (submitTextInput has no 404 handling)

**NEW-05: Default thinking time of 60s creates long dead air**
After TTS reads a question, 60 seconds of silence pass before recording auto-starts. For a driving quiz designed to be fast-paced, this default is far too long. Most trivia players know their answer within 5-10 seconds.
Files: `QuizSettings.swift:74,111` (default value)

**NEW-06: `speakText()` hardcodes English locale**
`AudioService.swift:870` sets `AVSpeechSynthesisVoice(language: "en-US")` for local TTS announcements (error messages, score readout). When the quiz is in Slovak, error messages like "Sorry, I didn't catch that" are still spoken in English TTS voice.
Files: `AudioService.swift:870`

### P2: Medium Impact

**NEW-07: Mute mode makes quiz unusable for drivers**
When muted, the question is only displayed visually (`QuizViewModel.swift:1671-1681`). The mute feature should probably be "mute TTS but still show question text large enough for passengers" rather than a driving-mode feature. Currently there is no guard or warning when a user mutes in a voice-first context.
Files: `QuizViewModel.swift:1666-1681`

**NEW-08: Question history hard cap of 500 with no auto-rotation**
The question history uses a fixed 500-question cap (`PersistenceStore.swift:102`). Once reached, the user must manually reset. For a daily driver, this could fill up in ~25 quiz sessions. There is no LRU/FIFO rotation that would keep the most recent 500 and drop the oldest.
Files: `PersistenceStore.swift:102,218-223`

**NEW-09: CompletionView stats card shows "Correct" as raw score, not count**
`CompletionView.swift:83` shows `Int(viewModel.score)` as "Correct" count. But `score` is a Double that accumulates fractional points (e.g., 0.5 for partially correct). A score of 7.5 from 8 correct + 1 partial would show "7" as "Correct" count, which is misleading. The actual correct count should use `participant.correctCount` but this is not tracked on the iOS side -- only `score` and `questionsAnswered`.
Files: `CompletionView.swift:80-98`

**NEW-10: Auto-confirm countdown off-by-one creates visual glitch**
In `startAutoConfirmIfEnabled()` at `QuizViewModel.swift:829-838`, the countdown loops `for remaining in (0 ..< duration).reversed()` which counts from `duration-1` to `0`, then auto-confirms when it reaches 0. But the initial `autoConfirmCountdown = duration` is set before the loop starts. The first tick shows `duration`, then the first sleep produces `duration-1`. This means the countdown shows `10, 9, 8...1, 0` but the sleep happens BEFORE the decrement, so the visual starts at 10 and the auto-confirm fires at 0 -- total wait is actually 10 seconds, not 10. This is correct timing but the countdown shows `10` briefly before the first sleep completes, which could show `10` for nearly 2 seconds (initial set + first sleep).
Files: `QuizViewModel.swift:826-838`

**NEW-11: No explanation TTS for incorrect answers**
The code at `QuizViewModel.swift:1515-1528` has a TODO comment for explanation TTS but it is not implemented. For a hands-free quiz, hearing the correct answer and explanation spoken aloud after an incorrect answer is essential for the educational value of the quiz.
Files: `QuizViewModel.swift:1515-1528`

**NEW-12: Question rating requires precise tap during driving**
The star rating row (`ResultView.swift:416-446`) requires tapping individual stars with 44pt hit targets. While technically accessible, rating questions while driving is dangerous and there is no voice command for rating.
Files: `ResultView.swift:416-446`, `VoiceCommand.swift` (no rating command)

**NEW-13: `resumeSession()` does not actually resume -- it starts a new quiz**
`QuizViewModel.swift:1131-1140` has a `resumeSession()` method that just calls `startNewQuiz()` with a comment "For now, just start a new quiz." If the app is backgrounded and reopened, any in-progress quiz state is lost. The session ID is persisted but never used for resumption.
Files: `QuizViewModel.swift:1131-1140`

### P3: Low Impact / Polish

**NEW-14: No haptic feedback for voice command detection**
When a voice command is detected, the UI briefly shows the command name in `VoiceCommandIndicator` but there is no haptic feedback. Adding `.sensoryFeedback(.selection)` would help the user know their command was heard.
Files: `QuizViewModel.swift:1873`

**NEW-15: `set_premium` endpoint has no authentication**
`misc.py:63-78` checks for `X-Admin-Key` header, but the `set_premium` call from iOS (`NetworkService.swift:524-541`) does not send this header. The endpoint will always return 401. Premium status notification is broken.
Files: `apps/quiz-agent/app/api/routes/misc.py:63-78`, `NetworkService.swift:524-541`

**NEW-16: Question audio cache bypass may increase latency**
`NetworkService.swift:403` sets `cachePolicy: .reloadIgnoringLocalCacheData` for ALL audio downloads, including feedback audio. The comment says "Backend returns same URL for different questions" -- but feedback URLs include the result type (e.g., `/tts/feedback/correct`). Disabling cache for feedback audio unnecessarily forces re-download every time.
Files: `NetworkService.swift:400-403`

**NEW-17: CompletionView "Missed" count double-counts partial answers**
`CompletionView.swift:88` calculates missed as `questionsAnswered - Int(score)`. A partially correct answer (0.5 points) counts as missed (score truncated to Int). With 10 questions, 8 correct + 2 partial (0.5 each) = score 9.0, missed = 10 - 9 = 1, but actually 0 questions were fully wrong.
Files: `CompletionView.swift:88`

**NEW-18: Voice command "help" only works in two states**
The "help" voice command (`QuizViewModel.swift:1907-1914`) only responds during `askingQuestion` and `finished`. During `showingResult`, saying "help" does nothing. The user has no way to discover available commands while reviewing results.
Files: `QuizViewModel.swift:1907-1914`

**NEW-19: Background audio session not reactivated after interruption**
When an audio interruption ends (`AudioService.swift:279-283`), the code logs "interruption ended" but does not call `try session.setActive(true)` to re-activate the audio session. Subsequent recording or playback may fail silently.
Files: `AudioService.swift:278-283`

---

## 6. Multiplayer Readiness

The backend architecture has solid multiplayer foundations:
- `Participant` model with `participant_id`, `user_id`, `score`, `answered_count`
- Session has a `participants` array (currently always 1 participant)
- API endpoints exist for `add_participant` and `remove_participant` (`sessions.py:85-111`)
- Backend `process_answer` accepts `participant_id` parameter

### What Would Need to Change

**6.1 Backend changes:**
- WebSocket or SSE for real-time state sync between players (currently polling-only)
- Turn-based logic: who answers when, buzzer mode vs round-robin
- Scoring differentiation: speed bonus, first-to-answer bonus
- Session lobby: waiting room before quiz starts
- Spectator mode for passengers

**6.2 iOS changes:**
- `QuizViewModel` assumes single participant throughout (e.g., `session.participants.first` at `QuizResponse.swift:49-55`)
- No lobby/waiting UI
- No opponent score display
- No turn indicator
- No real-time sync mechanism (would need WebSocket client)
- Voice command "score" only reports own score

**6.3 Estimated effort:** The backend is ~60% ready for basic multiplayer. The iOS app would need significant new UI (lobby, leaderboard, turn indicator) and a WebSocket layer. Estimate: 3-4 weeks for basic 2-player mode.

---

## 7. Prioritized Backlog (New Issues)

### P0 -- Must Fix (breaks core promise)

| ID | Title | Effort |
|----|-------|--------|
| NEW-01 | Voice commands do not work in non-English languages | M |
| NEW-02 | No audio cue when recording starts/stops | S |

### P1 -- High Impact (significantly degrades driving UX)

| ID | Title | Effort |
|----|-------|--------|
| NEW-03 | No voice command to advance from result screen | S |
| NEW-04 | Session expiry mid-quiz shows unhelpful error | S |
| NEW-05 | Default thinking time of 60s creates long dead air | XS |
| NEW-06 | `speakText()` hardcodes English locale | S |
| NEW-11 | No explanation TTS for incorrect answers | S |

### P2 -- Medium Impact (usability gap)

| ID | Title | Effort |
|----|-------|--------|
| NEW-07 | Mute mode makes quiz unusable for drivers | S |
| NEW-08 | Question history has no auto-rotation (500 cap) | S |
| NEW-09 | CompletionView shows score as "Correct" count (misleading) | XS |
| NEW-10 | Auto-confirm countdown visual timing glitch | XS |
| NEW-12 | Question rating requires tapping stars while driving | S |
| NEW-13 | `resumeSession()` does not actually resume | M |

### P3 -- Polish

| ID | Title | Effort |
|----|-------|--------|
| NEW-14 | No haptic feedback for voice command detection | XS |
| NEW-15 | `set_premium` endpoint auth is broken from iOS | S |
| NEW-16 | Audio cache bypass for feedback audio increases latency | XS |
| NEW-17 | CompletionView "Missed" count incorrect with partial scores | XS |
| NEW-18 | Voice command "help" only works in two states | XS |
| NEW-19 | Audio session not reactivated after interruption | S |

**Size key:** XS = <1 hour, S = 1-4 hours, M = 4-8 hours, L = 1-2 days

---

## 8. Top 5 Recommendations

1. **Add recording start/stop audio cues (NEW-02).** A simple beep tone when recording starts and a confirmation tone when it stops would transform the driving experience. This is the single highest-impact change for the least effort.

2. **Reduce default thinking time to 10-15s (NEW-05).** The current 60s default creates awkward dead air. Most trivia answers come within 5-10 seconds. Advanced users can increase it in settings.

3. **Implement multilingual voice commands (NEW-01).** At minimum, add Slovak equivalents ("preskoc" for skip, "opakuj" for repeat, etc.) to `VoiceCommand.match()` and switch the recognizer locale based on quiz language.

4. **Add "next" voice command for result screen (NEW-03).** This completes the fully hands-free loop. Without it, a user who pauses auto-advance is stuck until they tap.

5. **Implement explanation TTS (NEW-11).** The educational value of the quiz depends on hearing why an answer was wrong. The code is already structured for this (TODO at line 1515) -- it just needs the trigger logic.

---

## 9. Code Quality Observations

**Strengths:**
- Clean MVVM architecture with protocol-based dependency injection
- Comprehensive mock implementations for all services
- Good use of Swift concurrency (actors, @MainActor, async/await)
- Thorough accessibility labels and identifiers
- Re-entrancy guard on `handleQuizResponse` prevents race conditions
- Robust audio handling with retry logic and validation

**Concerns:**
- `QuizViewModel.swift` is ~2000 lines and handles too many responsibilities (quiz flow, voice commands, audio coordination, timer management, error handling). Consider extracting into focused coordinators.
- Multiple timer tasks (`autoAdvanceTask`, `answerTimerTask`, `thinkingTimeTask`, `autoStopRecordingTask`, `silenceDetectionTask`, `autoConfirmTask`) create complex interactions. A formal state machine library would reduce the risk of timer-related bugs.
- The `thinkingTimeCountdown` loop at `QuizViewModel.swift:1307-1329` runs directly in the calling function rather than as a detached task. If `startThinkingTimeCountdown()` is called from `startRecordingOrTimer()` which is called from `playQuestionAudio()`, the entire call chain blocks for up to 120 seconds. This means `playQuestionAudio` does not return until thinking time completes, which may have subtle effects on caller expectations.
