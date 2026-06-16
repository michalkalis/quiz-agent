# Phase 2: Auto-Record After TTS + Silence Detection

## Goal

Eliminate the need for "start" and "stop" voice commands for the happy path. After TTS finishes reading a question, the app auto-opens the mic, waits for the user to speak, detects 1.5s of silence after speech ends, then auto-submits. The user only needs voice commands for non-default actions ("skip", "ok").

## Flow

```
TTS plays question → TTS ends → 500ms pause → Auto-open mic → User speaks →
1.5s silence after speech → Auto-stop & submit
```

## Prerequisites

- Phase 1 voice commands are implemented and working (done)
- iOS 26+ with `SpeechDetector` API for voice activity detection (VAD)

## Current State (What Exists)

| Component | Current Behavior |
|-----------|-----------------|
| `playQuestionAudio()` in QuizViewModel | After TTS finishes → calls `startAnswerTimer()` |
| `startAnswerTimer()` | Counts down `answerTimeLimit` seconds → auto-starts recording |
| `startAutoStopRecordingTimer()` | Fixed 4s timer (`Config.autoRecordingDuration`) → auto-stops recording |
| `Config.autoRecordingDuration` | 4.0 seconds (static) |
| `QuizSettings.answerTimeLimit` | User-configurable: 0/15/20/30/45/60 seconds |

## Design Decisions

### Smart Silence Detection vs Fixed Timer

Replace the fixed 4s `autoStopRecordingTimer` with `SpeechDetector` (iOS 26 VAD). `SpeechDetector` provides real-time voice activity detection without full transcription — lightweight and fast.

**Behavior:**
1. When recording starts, begin monitoring with `SpeechDetector`
2. Wait for speech to begin (user starts talking)
3. Once speech detected, start a 1.5s silence timer
4. Each new speech detection resets the 1.5s timer
5. When 1.5s of continuous silence passes after speech → auto-stop and submit
6. Keep the hard maximum of `Config.autoRecordingDuration` as a safety fallback (increase from 4s → 15s)

### Auto-Record After TTS

Replace the `startAnswerTimer()` countdown with immediate auto-record:
1. After TTS finishes playing → 500ms pause → auto-start recording
2. The answer timer countdown UI becomes unnecessary when auto-record is enabled
3. Keep `answerTimeLimit` as a fallback for when auto-record is disabled

### Settings

Add `autoRecordEnabled: Bool` to `QuizSettings` (default: `true` on iOS 26+, `false` otherwise). When enabled:
- Skip the answer countdown timer entirely
- Auto-start recording 500ms after TTS finishes
- Use silence detection to auto-stop

When disabled: fall back to Phase 1 behavior (answer timer → fixed duration recording).

---

## Files to Create (1)

### `Services/SilenceDetectionService.swift`

- `@available(iOS 26, *)` service wrapping `SpeechDetector`
- Protocol: `SilenceDetectionServiceProtocol`
- `startMonitoring() -> AsyncStream<SilenceDetectionEvent>` where events are `.speechStarted`, `.silenceDetected(duration: TimeInterval)`, `.speechEnded`
- Uses `SpeechDetector(sensitivity: .medium)` — medium sensitivity avoids false triggers from road noise
- Add to `SpeechAnalyzer(modules: [transcriber, detector])` — reuse the same analyzer from VoiceCommandService
- Mock: `MockSilenceDetectionService` for testing

**Key consideration:** SpeechDetector and SpeechTranscriber can share the same `SpeechAnalyzer` instance. This means VoiceCommandService should own both modules. Alternatively, create a shared `SpeechAnalyzerManager` that both services access.

**Recommended approach:** Extend `VoiceCommandService` to also run a `SpeechDetector` module alongside the existing `SpeechTranscriber`, and expose a `silenceEvents: AsyncStream<SilenceDetectionEvent>` on the protocol. This avoids running two `AVAudioEngine` instances.

---

## Files to Modify (5)

### 1. `Services/VoiceCommandService.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Services/VoiceCommandService.swift`

- Add `SpeechDetector` module to the existing `SpeechAnalyzer(modules: [transcriber, detector])`
- Add `silenceEvents: AsyncStream<SilenceEvent>` to `VoiceCommandServiceProtocol`
- `SilenceEvent` enum: `.speechStarted`, `.silenceAfterSpeech(duration: TimeInterval)`
- In `startListening()`, create `SpeechDetector(sensitivity: .medium)` and add to modules array
- Process detector results in parallel with transcriber results
- Track state: `idle → speechActive → silenceAccumulating → silenceThresholdReached`
- Emit `.silenceAfterSpeech(1.5)` when 1.5s continuous silence detected after speech
- Update `MockVoiceCommandService` with `simulateSilenceEvent()` for tests

### 2. `Models/QuizSettings.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Models/QuizSettings.swift`

- Add `autoRecordEnabled: Bool` (default: `true`)
- Update memberwise init and backward-compatible `init(from decoder:)`
- No new settings options array needed (it's a toggle)

### 3. `ViewModels/QuizViewModel.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift`

Major changes to recording lifecycle:

- Add `private var silenceDetectionTask: Task<Void, Never>?`
- Modify `playQuestionAudio()`:
  - After TTS finishes, if `settings.autoRecordEnabled && voiceCommandService != nil`:
    - Wait 500ms
    - Call `startRecording()` directly (skip answer timer)
  - Else: keep current `startAnswerTimer()` behavior
- Modify `startRecording()`:
  - After recording starts, if auto-record enabled:
    - Subscribe to `voiceCommandService?.silenceEvents`
    - On `.silenceAfterSpeech(≥1.5)`: call `stopRecordingAndSubmit()`
  - Else: keep current `startAutoStopRecordingTimer()`
- Modify `stopRecordingAndSubmit()`:
  - Cancel `silenceDetectionTask`
- Increase `Config.autoRecordingDuration` from 4.0 to 15.0 seconds (hard safety limit)
- Cancel `silenceDetectionTask` in `resetState()`

### 4. `Views/QuestionView.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Views/QuestionView.swift`

- Update `hintText` to show "Listening..." when auto-recording is active and waiting for speech
- Show "Speaking..." when speech is detected
- Show "Processing..." after silence detection stops recording

### 5. `Views/SettingsView.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Views/SettingsView.swift`

- Add "Auto-Record" toggle in Audio Settings (visible only on iOS 26+)
- Description: "Automatically start recording after question audio and stop when you finish speaking"

---

## Implementation Order

1. Add `autoRecordEnabled` to `QuizSettings` + backward-compat decoder
2. Add `SpeechDetector` + `silenceEvents` to `VoiceCommandService`
3. Update mock with `simulateSilenceEvent()`
4. Modify `QuizViewModel` recording lifecycle (auto-record + silence detection)
5. Update `QuestionView` hint text
6. Add toggle to `SettingsView`
7. Write tests (silence detection events, auto-record flow, fallback to timer)

## Verification

1. Build for iOS 26 simulator
2. Start quiz with auto-record ON → question plays → recording auto-starts → speak answer → stop talking → 1.5s later auto-submits
3. Start quiz with auto-record OFF → current Phase 1 behavior (timer countdown → manual or timed stop)
4. Toggle auto-record in settings → persists correctly
5. Long answer (>10s of speaking) → keeps recording, only stops after 1.5s silence
6. Run all tests → pass

## Risks

- **SpeechDetector sensitivity tuning**: `.medium` might trigger on car engine/radio noise. May need `.high` (less sensitive) or adaptive tuning.
- **Shared SpeechAnalyzer**: Running both SpeechTranscriber and SpeechDetector in same analyzer may have performance implications. Test on real device.
- **Auto-record UX**: Users might not expect immediate recording. The UI hint text update is critical to set expectations.
