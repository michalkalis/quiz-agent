# Audio Debugging

## Common Issues

### Audio Stalls Immediately

**Symptom:** Player status shows "waitingToPlayAtSpecifiedRate"

**Likely Cause:** Unsupported audio format (e.g., Opus in Ogg container)

**Diagnosis:**
```swift
player?.observe(\.timeControlStatus) { player, _ in
    if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
        print("⚠️ Stalling: \(player.reasonForWaitingToPlay?.rawValue ?? "unknown")")

        if let error = player.currentItem?.error {
            print("❌ Error: \(error.localizedDescription)")
        }
    }
}
```

**Fix:** Use MP3 or AAC instead of Opus/Ogg.

### Empty Recording (28 bytes)

**Symptom:** Recording data is only ~28 bytes (just the M4A header)

**Likely Cause:** Hardware not ready after playback stopped

**Fix:**
```swift
func prepareForRecording() async {
    await stopPlayback()

    // Deactivate and reactivate session
    try? AVAudioSession.sharedInstance().setActive(false)
    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    try? AVAudioSession.sharedInstance().setActive(true)

    // Hardware settle delay
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
}
```

### Permission Denied

**Symptom:** Recording fails with permission error

**Check:**
```swift
let status = AVAudioSession.sharedInstance().recordPermission
print("Permission: \(status.rawValue)")  // 0=undetermined, 1=denied, 2=granted
```

**Fix:** Add to Info.plist:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record your answers.</string>
```

### No Sound Output

**Checks:**
1. Volume not zero
2. Silent mode switch not on
3. Correct audio session category

```swift
let session = AVAudioSession.sharedInstance()
print("Category: \(session.category.rawValue)")
print("Mode: \(session.mode.rawValue)")
print("Route outputs: \(session.currentRoute.outputs.map { $0.portName })")
```

**Fix:** Ensure `.defaultToSpeaker` option is set.

### Bluetooth Mic Not Working

**Check HFP enabled:**
```swift
// Must include .allowBluetoothHFP for Bluetooth mic
options: [.allowBluetoothHFP, .allowBluetoothA2DP]
```

**List available inputs:**
```swift
if let inputs = AVAudioSession.sharedInstance().availableInputs {
    for input in inputs {
        print("🎤 \(input.portName) (\(input.portType.rawValue))")
    }
}
```

## Diagnostic Logging

```swift
func logAudioSessionState() {
    let session = AVAudioSession.sharedInstance()

    print("=== Audio Session State ===")
    print("Category: \(session.category.rawValue)")
    print("Mode: \(session.mode.rawValue)")
    print("Options: \(session.categoryOptions.rawValue)")
    print("Sample Rate: \(session.sampleRate)")
    print("I/O Buffer: \(session.ioBufferDuration)")

    print("\n=== Current Route ===")
    for input in session.currentRoute.inputs {
        print("Input: \(input.portName) (\(input.portType.rawValue))")
    }
    for output in session.currentRoute.outputs {
        print("Output: \(output.portName) (\(output.portType.rawValue))")
    }

    print("\n=== Available Inputs ===")
    if let inputs = session.availableInputs {
        for input in inputs {
            print("- \(input.portName) (\(input.portType.rawValue))")
        }
    }
}
```

## Player State Debugging

```swift
func logPlayerState(_ player: AVPlayer) {
    print("=== Player State ===")
    print("Status: \(player.status.rawValue)")  // 0=unknown, 1=ready, 2=failed
    print("Time Control: \(player.timeControlStatus.rawValue)")  // 0=paused, 1=waiting, 2=playing
    print("Rate: \(player.rate)")  // 0=paused, 1=playing

    if let item = player.currentItem {
        print("\n=== Current Item ===")
        print("Status: \(item.status.rawValue)")
        print("Duration: \(CMTimeGetSeconds(item.duration))s")

        if let error = item.error {
            print("Error: \(error.localizedDescription)")
        }
    }
}
```

## Recording Validation

```swift
func validateRecording(_ data: Data) -> Bool {
    // M4A header alone is ~28 bytes
    // Minimum valid voice recording is ~500 bytes
    let minimumSize = 500

    if data.count < minimumSize {
        print("❌ Recording too short: \(data.count) bytes")
        return false
    }

    print("✅ Recording valid: \(data.count) bytes")
    return true
}
```

## Simulator Limitations

- No microphone access (use device for recording tests)
- Bluetooth not available
- Some audio session options may behave differently

**Test audio recording on physical device, not simulator.**
