# Issue #10: Real-time Word-by-Word Transcription Display

## Status: DONE

## Context
ElevenLabs Scribe v2 sends `partial_transcript` events displayed in QuestionView. But partial transcripts come in chunks, not word-by-word. User wants Claude Code voice mode-like word-by-word appearance. Could replace confirm sheet.

## Design options
1. **Animate partial transcript diffs** — Compare previous and new partial transcript, animate new words appearing with fade-in
2. **Custom word splitting** — When new partial arrives, diff against previous, animate each new word with staggered delay
3. **Keep confirm sheet optional** — If user can see real-time transcription, make confirm sheet toggleable

## Key code locations
- `QuizViewModel.swift` line 520-521: `self.liveTranscript = text` (receives partial transcripts)
- `QuestionView.swift` lines 122-136: live transcript display
- `ElevenLabsSTTService.swift` lines 181-187: partial_transcript events

## Files to modify
- `apps/ios-app/CarQuiz/CarQuiz/Views/QuestionView.swift` (lines 122-136) — Enhanced live transcript with word animation
- New: `apps/ios-app/CarQuiz/CarQuiz/Views/LiveTranscriptView.swift` — Animated word-by-word component
- `apps/ios-app/CarQuiz/CarQuiz/Models/QuizSettings.swift` — Add `showConfirmSheet` toggle

## Implementation approach
1. Create `LiveTranscriptView` that tracks previous/current text, diffs words
2. New words animate in with stagger (e.g., 50ms per word, fade + slight slide up)
3. Final transcript highlighted differently from partial
4. Add settings toggle to skip confirm sheet when live transcript is visible
