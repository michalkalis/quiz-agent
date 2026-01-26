# iOS Audio Patterns (AVFoundation)

Use this knowledge when working with audio recording, playback, AVAudioSession, or Bluetooth audio.

## Quick Reference

| Need | Reference |
|------|-----------|
| Configure AVAudioSession | [audio-session.md](references/audio-session.md) |
| Record audio | [recording.md](references/recording.md) |
| Play audio files | [playback.md](references/playback.md) |
| Background audio | [background-audio.md](references/background-audio.md) |
| MP3/AAC/Opus formats | [format-compatibility.md](references/format-compatibility.md) |
| Bluetooth HFP/A2DP | [bluetooth-audio.md](references/bluetooth-audio.md) |

## Decision Tree

### 1. Need to play and record audio?
Use `.playAndRecord` category:
```swift
try AVAudioSession.sharedInstance().setCategory(
    .playAndRecord,
    mode: .spokenAudio,
    options: [.defaultToSpeaker, .allowBluetoothA2DP]
)
```

### 2. Audio needs to work in background?
Add `audio` to UIBackgroundModes in Info.plist:
```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

### 3. Need Bluetooth microphone?
Use HFP option (may show "call" UI in car):
```swift
options: [.allowBluetoothHFP, .allowBluetoothA2DP]
```

### 4. Playing backend audio that fails?
- iOS AVPlayer does NOT support OggOpus
- Request MP3 or AAC from backend
- See [format-compatibility.md](references/format-compatibility.md)

## Common Patterns

### @MainActor Audio Service
```swift
@MainActor
final class AudioService: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
}
```

### Hardware Settle Time
```swift
// Wait after stopping playback before recording
await stopPlayback()
try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
try startRecording()
```

## Troubleshooting Checklist

- [ ] Microphone permission in Info.plist
- [ ] Background audio mode if needed
- [ ] Audio session activated before use
- [ ] Correct format (MP3/AAC, not OggOpus)
- [ ] Hardware settle time between play/record
