# Phase 4: Additional Voice Commands — "repeat", "score", "help"

## Goal

Add 3 new voice commands that address the most-requested features from trivia app UX research. These are all non-recording commands — they don't affect the record/submit flow.

| Command | Action | Priority | Rationale |
|---------|--------|----------|-----------|
| **"repeat"** | Replay current question audio | High | Drivers miss questions ~30% of the time |
| **"score"** | Announce current score via TTS | Medium | Progress updates without looking at screen |
| **"help"** | List available commands via TTS | Medium | First-time UX, discoverability |

## Prerequisites

- Phase 1 voice commands working (done)
- Phases 2 and 3 are nice-to-have but NOT required — Phase 4 is independent

## Current State

| Component | Relevant Behavior |
|-----------|-----------------|
| `VoiceCommand` enum | `.start`, `.stop`, `.skip`, `.ok` |
| `VoiceCommand.match(from:)` | Priority-ordered `text.contains()` matching |
| `handleVoiceCommand(_:)` in QuizViewModel | Switch dispatch to existing methods |
| `playQuestionAudio(from:)` | Downloads and plays question audio, stores URL in `nextQuestionAudioUrl` |
| `audioService.playOpusAudio(_:)` | Plays audio data, returns duration |
| `networkService.downloadAudio(from:)` | Downloads audio from URL |
| Backend TTS endpoint | `POST /api/v1/tts/speak` — generates TTS for arbitrary text (if exists), or use existing audio URLs |

---

## Design

### "repeat" Command

**Valid states:** `.askingQuestion` (before answering)

**Implementation:**
1. Store the current question's audio URL when it arrives (already done — `nextQuestionAudioUrl` pattern)
2. Add `private var currentQuestionAudioUrl: String?` to QuizViewModel (set when question audio first plays)
3. On "repeat": replay question audio from stored URL
4. Reset the answer timer after replay finishes (same as initial play)
5. If no audio URL stored (audio mode off): ignore the command

**Edge cases:**
- "repeat" during TTS playback: stop current playback, restart from beginning
- "repeat" during recording: ignored (recording has priority)
- Multiple "repeat" in a row: each restarts playback

### "score" Command

**Valid states:** `.askingQuestion`, `.showingResult` (any active quiz state except recording/processing)

**Implementation:**
- Synthesize score text: `"Your score is {score} out of {questionsAnswered}. Question {current} of {total}."`
- Play via TTS — two options:
  - **Option A (recommended):** Use `AVSpeechSynthesizer` (built-in, no network, instant). This is different from backend TTS (OpenAI) but perfectly fine for short status messages.
  - **Option B:** Call backend TTS endpoint. Adds latency and network dependency for a simple status message.
- After score announcement finishes, resume previous state (no state transition needed)

**AudioService changes:** Add `func speakText(_ text: String) async` using `AVSpeechSynthesizer`. This is a new capability separate from `playOpusAudio`.

### "help" Command

**Valid states:** `.askingQuestion` (main quiz state)

**Implementation:**
- Synthesize help text listing available commands:
  - If Phase 2 done: `"Say skip to skip, or ok to confirm your answer."`
  - If Phase 1 only: `"Say start to record, stop to submit, skip to skip a question, or ok to confirm."`
- Use same `AVSpeechSynthesizer` approach as "score"
- Only announce commands relevant to the current state

---

## Files to Modify (6)

### 1. `Models/VoiceCommand.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Models/VoiceCommand.swift`

- Add `.repeat`, `.score`, `.help` to `VoiceCommand` enum
- Update `match(from:)` priority order: `start > stop > skip > repeat > score > help > ok`
  - "repeat" before "score"/"help" because it's more time-sensitive
  - "ok" stays last (least likely to be ambiguous)
- Note: "help" could false-match in phrases like "I can't help it" — consider requiring exact word match or checking that "help" appears as standalone word (word boundary matching)

**Word boundary consideration for "help":**
```swift
// Instead of text.contains("help"), use word boundary:
let words = Set(text.lowercased().split(separator: " ").map(String.init))
return words.contains("help")
```
Apply this to all commands for robustness. Single words like "start" or "stop" are unlikely to appear as substrings, but "ok" could match "book" — word boundary matching is safer.

### 2. `Services/AudioService.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Services/AudioService.swift`

- Add `func speakText(_ text: String) async` to `AudioServiceProtocol`
- Implementation uses `AVSpeechSynthesizer`:
  ```swift
  func speakText(_ text: String) async {
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      synthesizer.speak(utterance)
      // Wait for completion via delegate
  }
  ```
- Add `private let synthesizer = AVSpeechSynthesizer()` + delegate for completion
- Add `func speakText(_ text: String) async` to `MockAudioService` (no-op)

### 3. `ViewModels/QuizViewModel.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift`

- Add `private var currentQuestionAudioUrl: String?` (set in `playQuestionAudio()` and cleared in `resetState()`)
- Store URL: in `playQuestionAudio(from:)`, set `currentQuestionAudioUrl = urlString`
- Extend `handleVoiceCommand(_:)` with 3 new cases:

```swift
case .repeat:
    if quizState == .askingQuestion, let audioUrl = currentQuestionAudioUrl {
        cancelAnswerTimer()
        await stopAnyPlayingAudio()
        await playQuestionAudio(from: audioUrl)  // replays + restarts timer
    }

case .score:
    if quizState == .askingQuestion || quizState.isShowingResult {
        let total = currentSession?.maxQuestions ?? 0
        let current = questionsAnswered + (quizState == .askingQuestion ? 1 : 0)
        let text = "Your score is \(Int(score)) out of \(questionsAnswered). Question \(current) of \(total)."
        await audioService.speakText(text)
    }

case .help:
    if quizState == .askingQuestion {
        let text = "Say skip to skip, start to record, stop to submit, or ok to confirm."
        await audioService.speakText(text)
    }
```

- Clear `currentQuestionAudioUrl` in `resetState()`

### 4. `Views/Components/VoiceCommandIndicator.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Views/Components/VoiceCommandIndicator.swift`

- Update `label` computed property to handle new commands:
  - `.repeat` → "Repeat"
  - `.score` → "Score"
  - `.help` → "Help"
- Already handled by `command.rawValue.capitalized` if raw values are lowercase

### 5. `CarQuizTests/VoiceCommandTests.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuizTests/VoiceCommandTests.swift`

Add tests:
- "repeat" matched from transcription
- "score" matched from transcription
- "help" matched from transcription (word boundary — "helpful" should NOT match)
- Priority order: "repeat" > "score" > "help"
- "repeat" ignored during recording state
- "score" works in both askingQuestion and showingResult
- "help" ignored during recording state

### 6. `Views/SettingsView.swift` (optional)

No settings changes needed — all 3 commands are always available when voice commands are enabled.

---

## Implementation Order

1. Add `.repeat`, `.score`, `.help` to `VoiceCommand` enum + update `match(from:)`
2. Upgrade matching to word-boundary based (split into words, check `Set.contains`)
3. Add `speakText(_:)` to `AudioServiceProtocol` + implement with `AVSpeechSynthesizer`
4. Add `currentQuestionAudioUrl` tracking to QuizViewModel
5. Extend `handleVoiceCommand(_:)` with repeat/score/help handlers
6. Write tests
7. Update VoiceCommandIndicator labels (if needed)

## Verification

1. Start quiz → question plays → say "repeat" → question replays from start
2. Say "repeat" twice → works both times
3. Say "score" during question → hears "Your score is 2 out of 3. Question 4 of 10."
4. Say "score" on result screen → also works
5. Say "help" → hears available commands
6. Say "repeat" during recording → ignored
7. Run all tests → pass

## Risks

- **"help" false positives:** Words containing "help" (e.g., "helpful") could trigger. Word boundary matching mitigates this.
- **AVSpeechSynthesizer quality:** Built-in TTS is lower quality than OpenAI TTS. For status messages this is acceptable — users won't expect the same quality as question narration.
- **Audio session conflicts:** `AVSpeechSynthesizer` plays through the same audio session. Need to ensure it doesn't conflict with question audio playback. Use `await stopAnyPlayingAudio()` before speaking score/help.
- **"repeat" with no audio URL:** If audio mode is off (no TTS), "repeat" has no audio to replay. Could fall back to `speakText(currentQuestion?.question)` to read the question aloud via AVSpeechSynthesizer.

## Future Commands (not in this phase)

| Command | Notes |
|---------|-------|
| "hint" | Needs backend support — new endpoint to generate hints |
| "louder" / "quieter" | System volume control — `MPVolumeView` or `AVAudioSession.setOutputVolume()` (private API, may require workaround) |
| "pause" / "resume" | Could pause auto-advance timer or TTS playback |
