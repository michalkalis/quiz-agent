# Issue #13: Add Repeat Question Button & Mute Toggle

## Status: DONE

## Context
Repeat exists as voice command only (`VoiceCommand.repeat` in QuizViewModel line 1841). No UI button. No mute functionality exists.

## Design
- Add "Repeat" icon button near the question area (speaker.wave.2.circle icon)
- Add "Mute" toggle in QuestionView (speaker.slash icon)
- Mute should stop current TTS playback and prevent auto-play of next question
- Store mute preference in QuizSettings (persisted)

## Key code locations
- `QuizViewModel.swift` lines 1841-1846: existing voice command repeat logic
- `QuizViewModel.playQuestionAudio()`: where TTS is triggered
- `QuestionView.swift` top bar area: where to place buttons

## Files to modify
- `apps/ios-app/CarQuiz/CarQuiz/Views/QuestionView.swift` — Add repeat + mute buttons to top bar
- `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift` — Add `isMuted` state, modify TTS to respect mute, add public `repeatQuestion()` method
- `apps/ios-app/CarQuiz/CarQuiz/Models/QuizSettings.swift` — Add `isMuted` property

## Verification
- Tap repeat → question TTS plays again, timer resets
- Toggle mute → next question's TTS doesn't play
- Mute persists across questions within same quiz session
