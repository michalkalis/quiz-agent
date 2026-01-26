# Bluetooth Audio (HFP vs A2DP)

## Bluetooth Profiles

| Profile | Purpose | Quality | Bidirectional |
|---------|---------|---------|---------------|
| **A2DP** | High-quality playback | High (stereo, 256+ kbps) | No (output only) |
| **HFP** | Hands-free (calls) | Low (mono, 8-16 kHz) | Yes (mic + speaker) |

## Key Insight

- **A2DP** = High-quality audio output, but **no microphone input**
- **HFP** = Enables Bluetooth microphone, but may show as "phone call" in car

## Configuration Options

### Playback Only (A2DP)
```swift
// Best quality, no mic
options: [.allowBluetoothA2DP]
```

### Recording + Playback (HFP + A2DP)
```swift
// Bluetooth mic enabled, may show call UI in car
options: [.allowBluetoothHFP, .allowBluetoothA2DP]
```

### Media Mode (A2DP Only)
```swift
// High quality, uses built-in mic instead of Bluetooth
func setupMediaMode() throws {
    try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .spokenAudio,
        options: [
            .defaultToSpeaker,
            .allowBluetoothA2DP,  // Output only
            .mixWithOthers
        ]
    )
}
```

### Call Mode (HFP + A2DP)
```swift
// Bluetooth mic, may trigger "call" UI
func setupCallMode() throws {
    try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .spokenAudio,
        options: [
            .defaultToSpeaker,
            .allowBluetoothHFP,   // Enables Bluetooth mic
            .allowBluetoothA2DP,  // High-quality output
            .mixWithOthers
        ]
    )
}
```

## Dynamic Mode Switching

```swift
enum AudioMode: String, CaseIterable, Identifiable {
    case media = "media"
    case call = "call"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .media: return "Media Mode"
        case .call: return "Call Mode"
        }
    }

    var description: String {
        switch self {
        case .media: return "High-quality audio, built-in mic"
        case .call: return "Bluetooth mic enabled"
        }
    }
}

@MainActor
final class AudioService {
    private var currentMode: AudioMode = .media

    func switchMode(to mode: AudioMode) async throws {
        guard mode != currentMode else { return }

        // Stop any active operations
        if isRecording { _ = try? await stopRecording() }
        if isPlaying { await stopPlayback() }

        // Deactivate session
        try AVAudioSession.sharedInstance().setActive(false)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Setup with new mode
        try setupAudioSession(mode: mode)
        currentMode = mode
    }
}
```

## Device Detection

```swift
func refreshAvailableDevices() {
    let session = AVAudioSession.sharedInstance()

    guard let inputs = session.availableInputs else { return }

    for input in inputs {
        let isBluetoothHFP = input.portType == .bluetoothHFP
        let isBuiltIn = input.portType == .builtInMic

        print("🎤 \(input.portName) - \(input.portType.rawValue)")
        print("   Bluetooth HFP: \(isBluetoothHFP)")
        print("   Built-in: \(isBuiltIn)")
    }
}

func currentOutputDevice() -> String {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    return outputs.first?.portName ?? "Unknown"
}
```

## Selecting Input Device

```swift
func setPreferredInputDevice(_ device: AudioDevice?) throws {
    let session = AVAudioSession.sharedInstance()

    if let device = device {
        // Find matching port
        guard let inputs = session.availableInputs,
              let port = inputs.first(where: { $0.uid == device.id }) else {
            throw AudioError.deviceNotFound
        }

        try session.setPreferredInput(port)
    } else {
        // Clear preference - automatic selection
        try session.setPreferredInput(nil)
    }
}
```

## Route Change Handling

```swift
func handleRouteChange(_ notification: Notification) {
    guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
        return
    }

    switch AVAudioSession.RouteChangeReason(rawValue: reason) {
    case .newDeviceAvailable:
        // Bluetooth connected
        print("🎧 Device connected")
        refreshAvailableDevices()

    case .oldDeviceUnavailable:
        // Bluetooth disconnected - fall back gracefully
        print("🎧 Device disconnected")
        // Audio session automatically uses built-in mic/speaker

    case .categoryChange:
        // Another app changed audio category
        print("🔄 Category changed")

    default:
        break
    }
}
```

## CarPlay Considerations

- **HFP Mode**: May show "Phone Call" on car display
- **Media Mode**: Shows as regular audio source
- Test with real CarPlay (simulator is limited)
- Consider letting users switch modes based on preference

## Troubleshooting

### Bluetooth Mic Not Working
1. Verify `.allowBluetoothHFP` is in options
2. Check that category is `.playAndRecord`
3. Ensure Bluetooth device supports HFP (not all do)
4. Try disconnecting/reconnecting Bluetooth

### Audio Quality Drops When Recording
- Expected behavior: HFP uses lower quality codec
- Consider recording locally and playing back via A2DP after

### Car Shows "Phone Call" UI
- Using HFP triggers call UI in some vehicles
- Use Media Mode (A2DP only) to avoid this
- Trade-off: Built-in mic instead of car's Bluetooth mic
