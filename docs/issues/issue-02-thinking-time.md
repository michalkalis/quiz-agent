# Issue #2: Add Configurable Thinking Time Before Recording

## Status: DONE

## Context
After TTS finishes reading the question, recording auto-starts after only 500ms (`Config.autoRecordDelayMs`). User needs time to think before mic activates. The `answerTimeLimit` (default 30s) is the answer window, not thinking time.

## Design
- Add `thinkingTime` setting to QuizSettings (default: 60s, options: [0, 15, 30, 45, 60, 90, 120])
- After TTS completes, show a visible countdown for thinking time
- Auto-start recording only after thinking time expires
- Allow tap on mic to start recording early (skip remaining thinking time)
- The existing `answerTimeLimit` becomes the recording window AFTER thinking time

## Files to modify
- `apps/ios-app/CarQuiz/CarQuiz/Models/QuizSettings.swift` — Add `thinkingTime` property
- `apps/ios-app/CarQuiz/CarQuiz/Utilities/Config.swift` — Add `thinkingTimeOptions`
- `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift` (line ~1648-1662) — Insert thinking time countdown between TTS completion and recording start
- `apps/ios-app/CarQuiz/CarQuiz/Views/QuestionView.swift` — Show thinking time countdown UI
- `apps/ios-app/CarQuiz/CarQuiz/Views/SettingsView.swift` — Add thinking time picker

## Key code locations
- `QuizViewModel.playQuestionAudio()` at line ~1648: after TTS completes, currently calls `startRecordingOrTimer()`
- `Config.autoRecordDelayMs = 500` at line 92 of Config.swift
- `QuizSettings.answerTimeLimit` — existing timer setting to reference as pattern

## Verification
- Set thinking time to 30s, verify recording doesn't start until 30s after TTS
- Tap mic during thinking time → recording starts immediately
- Set thinking time to 0 → behaves like current (500ms delay)
