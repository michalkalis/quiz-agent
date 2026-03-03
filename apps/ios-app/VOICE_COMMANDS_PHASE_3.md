# Phase 3: Barge-In Detection

## Goal

Allow the user to interrupt TTS question playback by speaking. When speech is detected during playback, immediately stop TTS and switch to recording mode. This eliminates waiting for the question to finish when the user already knows the answer.

**Industry standard:** BMW, Mercedes, Bosch automotive voice systems, Google Assistant, and Alexa all support barge-in.

## Flow

```
TTS plays question → User starts speaking → TTS immediately mutes →
500ms settle → Auto-open mic → User speaks answer →
Silence detection auto-submits (Phase 2)
```

## Prerequisites

- Phase 1 voice commands working (done)
- Phase 2 auto-record + silence detection working (provides the infrastructure)
- `SpeechDetector` already running in `VoiceCommandService` (added in Phase 2)

## Current State After Phase 2

| Component | Behavior |
|-----------|----------|
| `VoiceCommandService` | Runs `SpeechAnalyzer` with `SpeechTranscriber` + `SpeechDetector` |
| `silenceEvents` stream | Emits `.speechStarted`, `.silenceAfterSpeech(duration:)` |
| `playQuestionAudio()` | Sets `setPlaybackText()` for echo cancellation → plays TTS → clears text → auto-starts recording |
| `AudioService.stopPlayback()` | Stops any playing audio |

## Design

### Barge-In During TTS

The `SpeechDetector` is already running during TTS playback (Phase 2 adds it). Currently during playback, voice command matching ignores volatile results for echo cancellation. For barge-in, we need a different behavior:

1. During TTS playback, monitor `SpeechDetector` for `.speechStarted` events
2. When speech detected during playback:
   - Immediately call `audioService.stopPlayback()`
   - Wait 500ms for audio hardware to settle
   - Auto-start recording (same as Phase 2 post-TTS flow)
3. The echo cancellation text-overlap filter already protects against the TTS audio triggering false barge-in — but `SpeechDetector` works on audio energy, not text. Need a different approach.

### Echo vs Barge-In Discrimination

**Problem:** The speaker's TTS audio might trigger `SpeechDetector` — it can't distinguish between TTS output and human speech.

**Solution — Audio route detection:**
- If output goes to **speaker** (same device as mic): high echo risk. Use conservative threshold.
  - Only trigger barge-in if `SpeechDetector` detects `.high` confidence voice activity
  - OR: Disable barge-in entirely when using speaker output (safest approach for Phase 3)
- If output goes to **Bluetooth/CarPlay** (different device than mic): low echo risk. Barge-in works normally.
  - The TTS audio goes to car speakers, mic picks up cabin audio — minimal bleed

**Recommended Phase 3 approach:**
- Enable barge-in only when output route is Bluetooth/CarPlay/external (not iPhone speaker)
- This covers the primary use case (driving with car audio) and avoids the hardest echo problem
- Phase 4+ can add acoustic echo cancellation for speaker mode

---

## Files to Modify (4)

### 1. `Services/VoiceCommandService.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Services/VoiceCommandService.swift`

- Add `bargeInEvents: AsyncStream<Void>` to protocol — fires when speech detected during TTS playback
- Add `setTTSPlaybackActive(_ active: Bool)` to protocol — tells service when TTS is playing
- When `ttsPlaybackActive && speechDetected`:
  - Check audio route: if external output → emit barge-in event
  - If iPhone speaker → ignore (no barge-in)
- Audio route check: `AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType` — `.bluetoothA2DP`, `.carAudio`, `.airPlay` = external; `.builtInSpeaker` = internal
- Update mock with `simulateBargeIn()`

### 2. `ViewModels/QuizViewModel.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift`

- Add `private var bargeInTask: Task<Void, Never>?`
- In `startVoiceCommands()`: also subscribe to `bargeInEvents`
- Add `handleBargeIn()`:
  1. Call `await stopAnyPlayingAudio()` — immediately stop TTS
  2. Clear echo cancellation: `voiceCommandService?.setPlaybackText(nil)`
  3. Wait 500ms for hardware settle
  4. Call `startRecording()` — switches to recording mode
- Modify `playQuestionAudio()`:
  - Before playback: `voiceCommandService?.setTTSPlaybackActive(true)`
  - After playback ends (or is interrupted): `voiceCommandService?.setTTSPlaybackActive(false)`
- Cancel `bargeInTask` in `resetState()`

### 3. `Models/QuizSettings.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Models/QuizSettings.swift`

- Add `bargeInEnabled: Bool` (default: `true`)
- Update memberwise init and backward-compatible decoder

### 4. `Views/SettingsView.swift`

**Path:** `apps/ios-app/CarQuiz/CarQuiz/Views/SettingsView.swift`

- Add "Barge-In" toggle in Audio Settings section (iOS 26+ only)
- Description: "Interrupt question audio by speaking to answer immediately"
- Show note: "Works best with Bluetooth or CarPlay audio"

---

## Implementation Order

1. Add `bargeInEnabled` to `QuizSettings`
2. Add `setTTSPlaybackActive()` + `bargeInEvents` to `VoiceCommandServiceProtocol`
3. Implement audio route detection in `VoiceCommandService`
4. Wire barge-in subscription + handler into `QuizViewModel`
5. Update `playQuestionAudio()` with TTS active signaling
6. Add settings toggle
7. Write tests (barge-in triggers on external audio, suppressed on speaker, setting toggle)

## Verification

1. Connect to Bluetooth speaker/car → start quiz → question plays over Bluetooth → speak during question → TTS stops → recording starts
2. Use iPhone speaker → speak during question → no barge-in (TTS continues)
3. Toggle barge-in OFF in settings → no barge-in even on Bluetooth
4. Barge-in → speak answer → silence detection auto-submits (Phase 2 flow)
5. Run all tests → pass

## Risks

- **Bluetooth latency**: 100-300ms audio latency over Bluetooth means the detector might pick up slightly delayed TTS bleed. The 500ms settle time should cover this.
- **CarPlay specifics**: CarPlay audio routing may have different port types. Need to test with actual CarPlay setup.
- **User surprise**: Users might not expect TTS to stop when they cough or talk to a passenger. The "works best with Bluetooth" guidance helps set expectations.
