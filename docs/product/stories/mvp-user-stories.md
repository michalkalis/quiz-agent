# Hangs MVP User Stories

**Derived from:** [MVP Launch PRD](../prds/mvp-launch.md)
**Date:** 2026-03-18 | **Status:** Draft

---

## 1. Voice Quiz Flow

### US-001: Start a quiz by voice or tap
**As a** player
**I want to** start a new quiz from the home screen
**So that** I can begin playing quickly without complex setup

**Acceptance Criteria:**
- [ ] Given the user is on HomeView, when they tap "Start Quiz", then a session is created via `POST /api/v1/sessions` and the first question loads
- [ ] Given the quiz is starting, when the session creation is in progress, then the Start Quiz button shows a loading indicator and is disabled
- [ ] Given the backend is unreachable, when the user taps "Start Quiz", then an ErrorView is shown with "Try Again" and "Go Home" options
- [ ] Given the user has configured settings (language, difficulty, category, question count), when they start a quiz, then those settings are sent to the backend

**Priority:** P0

---

### US-002: Hear a question read aloud via TTS
**As a** driver
**I want to** hear each question spoken aloud automatically
**So that** I can play without looking at the screen

**Acceptance Criteria:**
- [ ] Given a new question is loaded, when the QuestionView appears, then the question text is read aloud via TTS audio from the backend
- [ ] Given TTS is playing, when the audio finishes, then auto-record begins after a 500ms delay (if autoRecordEnabled is true)
- [ ] Given TTS is playing and bargeInEnabled is true, when the user starts speaking on an external audio route (Bluetooth/CarPlay), then TTS stops and recording begins immediately
- [ ] Given TTS playback fails, when the question loads, then the question text is still displayed on screen so the user can read it

**Priority:** P0

---

### US-003: Answer a question by voice
**As a** driver
**I want to** speak my answer and have it transcribed and evaluated
**So that** I never need to touch the phone during a quiz

**Acceptance Criteria:**
- [ ] Given a question is displayed, when the user taps the mic button, then recording starts and the UI shows "Recording..." with a pulsing mic indicator
- [ ] Given recording is active, when the user taps the mic button again, then recording stops and the audio is submitted for transcription
- [ ] Given auto-record is enabled, when TTS finishes playing, then recording starts automatically after the configured delay
- [ ] Given auto-record is active and silence is detected after speech, then recording stops automatically and the answer is submitted
- [ ] Given recording finishes, when transcription completes, then the transcribed answer is shown in a confirmation sheet (if autoConfirmEnabled is false)
- [ ] Given autoConfirmEnabled is true, when transcription completes, then the answer is auto-confirmed after a 2-second countdown
- [ ] Given the confirmation sheet is shown, when the user says "re-record", then the confirmation is dismissed and recording restarts

**Priority:** P0

---

### US-004: See result with correct answer and explanation
**As a** player
**I want to** see whether I was right, the correct answer, and an explanation
**So that** I learn something from each question

**Acceptance Criteria:**
- [ ] Given an answer is evaluated, when ResultView appears, then a result badge shows correct/incorrect/partially correct/skipped with the points earned
- [ ] Given the result is shown, when the evaluation animation completes, then the user's answer and the correct answer are displayed in separate cards
- [ ] Given the question has an explanation, when the result is revealed, then an "Did You Know?" card shows the explanation text
- [ ] Given the result is shown, when TTS is available, then the result (correct/incorrect + correct answer) is read aloud
- [ ] Given haptic feedback is available, when the result appears, then a success haptic plays for correct, error haptic for incorrect/skipped, warning haptic for partial

**Priority:** P0

---

### US-005: Advance to the next question
**As a** player
**I want to** move to the next question automatically or by tapping
**So that** the quiz flows smoothly without friction

**Acceptance Criteria:**
- [ ] Given a result is displayed and auto-advance is enabled, when the auto-advance countdown (configurable: 5/8/10/15s) reaches zero, then the next question loads automatically
- [ ] Given a result is displayed, when the user taps "Continue", then the next question loads immediately
- [ ] Given the user wants to study the result, when they tap "Stay Here", then auto-advance pauses and the view shows "Staying on this question"
- [ ] Given the user is on a voice-only flow, when they say "ok" or "start", then the quiz advances to the next question

**Priority:** P0

---

### US-006: Complete a quiz and see summary
**As a** player
**I want to** see my final score and stats when the quiz ends
**So that** I know how I performed and feel motivated to play again

**Acceptance Criteria:**
- [ ] Given all questions are answered, when the quiz ends, then CompletionView shows final score (e.g., "8 / 10"), accuracy percentage, and a congratulatory message
- [ ] Given the completion screen is shown, then stats cards display correct count, missed count, and total questions
- [ ] Given the user has a streak, then streak stats (current streak, best streak, total quizzes played) are displayed
- [ ] Given the user is on CompletionView, when they tap "Play Again", then a new quiz starts with the same settings
- [ ] Given the user is on CompletionView, when they tap "Back to Home", then the app returns to HomeView

**Priority:** P0

---

### US-007: Skip a question
**As a** player
**I want to** skip a question I do not know
**So that** the quiz keeps flowing and I am not stuck

**Acceptance Criteria:**
- [ ] Given a question is displayed, when the user taps "Skip" or says "skip", then the question is marked as skipped (0 points) and the result shows "Skipped"
- [ ] Given the user skips, then the correct answer and explanation are still revealed in ResultView
- [ ] Given the user skips, then the current streak resets to 0

**Priority:** P0

---

### US-008: Use voice commands during a quiz
**As a** driver
**I want to** control the quiz with voice commands
**So that** I never need to touch the phone

**Acceptance Criteria:**
- [ ] Given voice commands are enabled (iOS 26+), when the user says "skip", then the current question is skipped
- [ ] Given voice commands are enabled, when the user says "repeat", then the current question audio replays
- [ ] Given voice commands are enabled, when the user says "score", then the current score is announced via TTS
- [ ] Given voice commands are enabled, when the user says "help", then available commands are listed via TTS
- [ ] Given the quiz is on CompletionView, when the user says "again", then a new quiz starts
- [ ] Given the quiz is on CompletionView, when the user says "home", then the app returns to HomeView
- [ ] Given voice commands are active, then a VoiceCommandIndicator shows the current listening state (disabled/listening/command detected)

**Priority:** P1

---

### US-009: End a quiz early
**As a** player
**I want to** end the quiz before all questions are answered
**So that** I can stop when I need to without losing my progress

**Acceptance Criteria:**
- [ ] Given a quiz is in progress, when the user taps the close (X) button, then a confirmation dialog asks "End Quiz?"
- [ ] Given the confirmation dialog is shown, when the user confirms "End Quiz", then the session ends and CompletionView shows stats for questions answered so far
- [ ] Given the confirmation dialog is shown, when the user taps "Cancel", then the quiz continues from where it was

**Priority:** P0

---

### US-010: Type an answer as fallback
**As a** player in a noisy environment
**I want to** type my answer instead of speaking
**So that** I can still play when voice input is unreliable

**Acceptance Criteria:**
- [ ] Given a non-MCQ question is displayed, when the user taps the keyboard icon, then a text input field appears
- [ ] Given the text field is visible, when the user types an answer and taps send (or presses Return), then the text answer is submitted for evaluation
- [ ] Given the text field is empty, then the submit button is disabled

**Priority:** P1

---

## 2. Multiple Choice Questions (MCQ)

### US-011: Answer an MCQ by tapping
**As a** passenger
**I want to** see multiple choice options and tap my answer
**So that** I can play visually without using voice

**Acceptance Criteria:**
- [ ] Given a question has type `text_multichoice` with `possible_answers`, when QuestionView renders, then A/B/C/D options are displayed in an MCQOptionPicker
- [ ] Given MCQ options are displayed, when the user taps an option, then that answer is submitted for evaluation
- [ ] Given an MCQ question, then the mic button and text input toggle are hidden (only option picker and skip are shown)

**Priority:** P0

---

### US-012: Answer an MCQ by voice
**As a** driver
**I want to** say "A", "B", "C", or "D" to select my answer
**So that** I can answer MCQs hands-free

**Acceptance Criteria:**
- [ ] Given an MCQ question is displayed and voice commands are enabled, when the user says "a", "b", "c", or "d" (single letter), then the corresponding option is selected and submitted
- [ ] Given an MCQ question, when the user says "option B" or "answer C", then the corresponding option is selected
- [ ] Given an MCQ question is read aloud via TTS, then each option letter and text are included in the spoken question

**Priority:** P1

---

## 3. Image Questions

### US-013: Answer a silhouette question
**As a** player
**I want to** see a country silhouette and guess which country it is
**So that** I can enjoy visual geography trivia

**Acceptance Criteria:**
- [ ] Given a question has type `image` and `image_subtype: "silhouette"`, when QuestionView renders, then the silhouette image loads from `media_url` and displays above the question text
- [ ] Given the image is loading, then a placeholder or loading indicator is shown
- [ ] Given the result is revealed, then the image is also shown in ResultView for reference

**Priority:** P1

---

### US-014: Answer a blind map question
**As a** player
**I want to** see an unlabeled map with a marked location and identify it
**So that** I can test my geography knowledge

**Acceptance Criteria:**
- [ ] Given a question has type `image` and `image_subtype: "blind_map"`, when QuestionView renders, then the map image with a red marker loads and displays above the question text
- [ ] Given the user answers (by voice, text, or MCQ), then evaluation works the same as for text questions

**Priority:** P1

---

### US-015: Answer a hint image question
**As a** player
**I want to** see an AI-generated hint image and guess the answer
**So that** I can enjoy creative visual clues

**Acceptance Criteria:**
- [ ] Given a question has type `image` and `image_subtype: "hint_image"`, when QuestionView renders, then the hint image loads from `media_url`
- [ ] Given the image fails to load, then the question text is still displayed and answerable without the image

**Priority:** P2

---

### US-016: Image questions are capped per quiz
**As a** player
**I want to** get a mix of question types in each quiz
**So that** the quiz does not become repetitive with too many image questions

**Acceptance Criteria:**
- [ ] Given a quiz session, then no more than max(3, maxQuestions/4) questions are image-based
- [ ] Given image questions are served, then two image questions never appear consecutively

**Priority:** P1

---

## 4. Settings Customization

### US-017: Change quiz language
**As a** multilingual player
**I want to** choose the language for questions and TTS
**So that** I can play in my preferred language

**Acceptance Criteria:**
- [ ] Given the user is on HomeView or SettingsView, when they select a language from the picker, then the setting is persisted and used for the next quiz
- [ ] Given 10 languages are supported (English, Slovak, Czech, German, French, Spanish, Italian, Polish, Hungarian, Romanian), then all appear in the language picker with native names
- [ ] Given a language is selected, then TTS audio plays in that language and questions are served in that language

**Priority:** P0

---

### US-018: Set difficulty level
**As a** player
**I want to** choose easy, medium, hard, or random difficulty
**So that** the quiz matches my skill level

**Acceptance Criteria:**
- [ ] Given the user selects a difficulty on HomeView or SettingsView, when they start a quiz, then only questions of that difficulty are served
- [ ] Given "Random" is selected, then questions of mixed difficulty are served
- [ ] Given the selected difficulty is persisted, when the app restarts, then the previous difficulty is preserved

**Priority:** P0

---

### US-019: Filter by category
**As a** player
**I want to** choose a question category
**So that** I get questions matching my interests

**Acceptance Criteria:**
- [ ] Given category options are "All Categories", "Adults", and "General", when the user selects one, then only matching questions are served
- [ ] Given "All Categories" is selected (nil), then questions from all categories are included

**Priority:** P1

---

### US-020: Configure question count
**As a** player
**I want to** choose how many questions are in a quiz (5, 10, 15, or 20)
**So that** I can fit the quiz to my available time

**Acceptance Criteria:**
- [ ] Given the user sets question count to N in SettingsView, when they start a quiz, then the session has exactly N questions
- [ ] Given the default is 10, when a new user starts, then quizzes have 10 questions

**Priority:** P1

---

### US-021: Configure voice features
**As a** player
**I want to** toggle voice commands, auto-record, barge-in, and auto-confirm independently
**So that** I can customize the hands-free experience to my preference

**Acceptance Criteria:**
- [ ] Given the user is on SettingsView, when they toggle "Voice Commands" off, then voice command detection is disabled during quizzes
- [ ] Given the user toggles "Auto-Record" off, then recording does not start automatically after TTS; the user must tap the mic
- [ ] Given the user toggles "Barge-In" off, then speaking during TTS does not interrupt playback
- [ ] Given the user toggles "Auto-Confirm Answer" off, then a confirmation sheet always appears after transcription
- [ ] Given voice features require iOS 26+, when running on older iOS, then voice command toggles are hidden from SettingsView
- [ ] Given all voice settings default to true, when a new user opens settings, then all voice toggles are on

**Priority:** P1

---

### US-022: Configure auto-advance and answer time limit
**As a** player
**I want to** adjust the auto-advance delay and answer time limit
**So that** the quiz pacing fits my speed

**Acceptance Criteria:**
- [ ] Given auto-advance delay options are 5, 8, 10, or 15 seconds, when the user selects one, then the result screen waits that many seconds before advancing
- [ ] Given answer time limit options are Off, 15, 20, 30, 45, or 60 seconds, when the user selects one, then a countdown timer badge appears during question asking
- [ ] Given answer time limit is "Off" (0), then no countdown is shown and recording does not auto-start from the timer

**Priority:** P2

---

### US-023: Select audio output device
**As a** driver using Bluetooth
**I want to** choose which microphone and audio mode to use
**So that** voice input works reliably with my car's audio system

**Acceptance Criteria:**
- [ ] Given the user is on SettingsView, when they tap "Microphone", then an AudioDevicePickerView sheet appears with available input devices
- [ ] Given the user selects a device, then that device UID is persisted and used for recording
- [ ] Given the user toggles audio mode between "Call" and "Media", then the audio session category updates accordingly

**Priority:** P2

---

### US-024: Settings persist across app launches
**As a** returning player
**I want to** find my settings unchanged after closing the app
**So that** I do not need to reconfigure every time

**Acceptance Criteria:**
- [ ] Given the user changes any setting, then PersistenceStore saves QuizSettings to UserDefaults
- [ ] Given the app is killed and relaunched, then all settings (language, difficulty, category, voice toggles, etc.) are restored
- [ ] Given a new settings field is added in an app update, then backward-compatible decoding defaults the field (e.g., new voice toggle defaults to true)

**Priority:** P0

---

## 5. Streak Tracking and Stats

### US-025: Track answer streak
**As a** player
**I want to** see my current streak of correct answers
**So that** I feel motivated to keep my streak going

**Acceptance Criteria:**
- [ ] Given the user answers correctly, then `currentStreak` increments by 1
- [ ] Given the user answers incorrectly or skips, then `currentStreak` resets to 0
- [ ] Given `currentStreak` exceeds `bestStreak`, then `bestStreak` is updated to match
- [ ] Given streaks are tracked, then stats persist across quiz sessions via PersistenceStore

**Priority:** P1

---

### US-026: View cumulative stats
**As a** a returning player
**I want to** see my overall stats (total correct, total answered, accuracy, quizzes played)
**So that** I can track my progress over time

**Acceptance Criteria:**
- [ ] Given a quiz ends, then `totalQuizzes` increments by 1
- [ ] Given each answer is evaluated, then `totalCorrect` and `totalAnswered` are updated
- [ ] Given CompletionView is shown and `bestStreak > 0`, then streak stats row displays current streak, best streak, and total quizzes
- [ ] Given `accuracyPercentage` is calculated as `(totalCorrect / totalAnswered) * 100`, then CompletionView shows this as "X% Accuracy"

**Priority:** P1

---

## 6. Onboarding

### US-027: First-time onboarding flow
**As a** new user
**I want to** understand the app's voice features and grant microphone permission
**So that** I can use the app effectively from the start

**Acceptance Criteria:**
- [ ] Given the user has never opened the app, when the app launches, then OnboardingView is shown instead of HomeView
- [ ] Given onboarding has 3 pages (Welcome, Features, Microphone), then the user can swipe or tap "Continue" to advance through them
- [ ] Given page 1 (Welcome), then it explains "Answer by Voice" with a mic icon and description
- [ ] Given page 2 (Features), then it lists Auto-Record, Barge-In, Voice Commands, and Auto-Advance with descriptions
- [ ] Given page 3 (Microphone), when the user taps "Allow Microphone", then the system permission dialog appears
- [ ] Given microphone permission is granted, then page 3 updates to show "You're All Set!" with a checkmark
- [ ] Given the user taps "Get Started" on the last page, then onboarding is marked complete and HomeView is shown
- [ ] Given the user taps "Skip" on any page except the last, then onboarding is marked complete and HomeView is shown
- [ ] Given onboarding is completed, when the app is relaunched, then onboarding is not shown again

**Priority:** P0

---

## 7. Error Handling

### US-028: Handle network errors gracefully
**As a** player
**I want to** see a clear error message when something goes wrong
**So that** I know what happened and can try again

**Acceptance Criteria:**
- [ ] Given the backend is unreachable, when session creation fails, then ErrorView shows with a "wifi.slash" icon, the error message, "Try Again" and "Go Home" buttons
- [ ] Given an error occurred during session creation, when the user taps "Try Again", then a new quiz session is started from scratch
- [ ] Given an error occurred mid-quiz, when the user taps "Try Again", then the last failed operation is retried without restarting the session
- [ ] Given the user taps "Go Home", then the app returns to HomeView in idle state

**Priority:** P0

---

### US-029: Handle voice transcription failure
**As a** player
**I want to** re-record or type my answer when voice recognition fails
**So that** I am not stuck on a question

**Acceptance Criteria:**
- [ ] Given recording finishes and transcription returns empty or unintelligible text, when the confirmation sheet appears, then the user can tap "Re-Record" to try again
- [ ] Given voice input repeatedly fails, when the user taps the keyboard icon, then they can type their answer as a fallback
- [ ] Given an error occurs during audio submission, then the error message is shown inline on QuestionView (not a full-screen error)
- [ ] Given the user cancels processing, then they return to the asking-question state and can record again

**Priority:** P0

---

### US-030: Handle question loading failure
**As a** player
**I want to** continue playing even if one question fails to load
**So that** a transient error does not ruin my quiz

**Acceptance Criteria:**
- [ ] Given the backend returns an error when fetching the next question, then an inline error message appears on the question screen
- [ ] Given a question's TTS audio fails to load, then the question text is still displayed and the user can answer normally
- [ ] Given an image question's `media_url` fails to load, then the question text is still displayed and answerable

**Priority:** P1

---

## 8. Question History and Freshness

### US-031: Avoid repeated questions
**As a** returning player
**I want to** never see the same question twice
**So that** every quiz feels fresh

**Acceptance Criteria:**
- [ ] Given the user has answered questions in previous sessions, then the iOS app sends a question exclusion list (seen question IDs) to the backend
- [ ] Given question history is tracked by PersistenceStore, then seen question IDs persist across app launches
- [ ] Given SettingsView shows "Questions Seen: X / 500", when the count approaches the limit, then the counter color changes to warning (>400) and error (>=450)

**Priority:** P1

---

### US-032: Reset question history
**As a** player who has seen many questions
**I want to** reset my question history
**So that** I can replay previously seen questions

**Acceptance Criteria:**
- [ ] Given the user is on SettingsView, when they tap "Reset History", then a confirmation alert appears: "Reset Question History?"
- [ ] Given the confirmation alert is shown, when the user taps "Reset", then all question history is cleared and the count resets to 0
- [ ] Given the user taps "Cancel", then history is preserved
- [ ] Given question history count is 0, then the "Reset History" button is disabled

**Priority:** P2

---

## 9. Question Rating and Source

### US-033: Rate a question
**As a** player
**I want to** rate questions on a 1-5 star scale
**So that** bad questions get flagged and good questions are reinforced

**Acceptance Criteria:**
- [ ] Given a result is shown, when the evaluation is revealed, then a star rating row appears with 5 tappable stars
- [ ] Given the user taps a star, then the rating is sent to the backend and the selected stars fill in
- [ ] Given the user does not rate, then no rating is submitted (optional interaction)

**Priority:** P2

---

### US-034: View question source
**As a** curious player
**I want to** see where a question came from and read the source article
**So that** I can learn more about the topic

**Acceptance Criteria:**
- [ ] Given a question has `source_url` and `source_excerpt`, when the result is shown, then a Source card displays the excerpt with a "Read Full Article" link
- [ ] Given the user taps "View Source" or "Read Full Article", then a SourceWebView sheet opens with the source URL
- [ ] Given a question has no source, then the source card and "View Source" button are hidden

**Priority:** P2

---

## 10. Accessibility

### US-035: VoiceOver support
**As a** visually impaired player
**I want to** use VoiceOver to navigate the app
**So that** I can play the quiz with screen reader assistance

**Acceptance Criteria:**
- [ ] Given VoiceOver is enabled, when navigating HomeView, then all buttons, pickers, and labels have meaningful accessibility labels and hints
- [ ] Given VoiceOver is enabled, when on QuestionView, then the question text, mic button, skip button, and error messages are announced with context
- [ ] Given VoiceOver is enabled, when on ResultView, then the score, result badge, answer cards, and action buttons are readable
- [ ] Given VoiceOver is enabled, when on CompletionView, then the final score is announced as "Final score: X of Y, Z percent accuracy"
- [ ] Given decorative elements (icons, dividers), then they have `accessibilityHidden(true)`

**Priority:** P0

---

### US-036: Dynamic Type and Reduce Motion
**As a** player with accessibility needs
**I want to** use the app with large text sizes and reduced motion
**So that** the app is comfortable for my vision and motion sensitivity

**Acceptance Criteria:**
- [ ] Given Dynamic Type is set to a large size, then all text scales appropriately without being clipped
- [ ] Given Reduce Motion is enabled, then all animations (result reveal, pulsing mic, transitions) are disabled or replaced with simple crossfades
- [ ] Given Reduce Motion is enabled, then `reduceMotion ? nil : .spring(...)` guards are applied to all view animations

**Priority:** P1

---

## Priority Summary

| Priority | Count | Description |
|----------|-------|-------------|
| P0 | 14 | Must-have for launch: core quiz flow, settings persistence, onboarding, error handling, basic accessibility |
| P1 | 14 | Should-have for launch: voice commands, MCQ voice, image questions, stats, question freshness, Dynamic Type |
| P2 | 8 | Nice-to-have: advanced settings, question rating, source viewing, history reset, hint images |
