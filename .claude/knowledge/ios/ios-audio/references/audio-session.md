# AVAudioSession Configuration

## Core Concept

AVAudioSession manages your app's audio behavior: how it interacts with other apps, system sounds, and hardware.

**Must configure before any audio operation.**

## Basic Setup

```swift
@MainActor
final class AudioService {
    func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        try session.setCategory(
            .playAndRecord,      // Both playback and recording
            mode: .spokenAudio,  // Optimized for voice
            options: [
                .defaultToSpeaker,     // Use speaker, not receiver
                .allowBluetoothA2DP,   // High-quality Bluetooth playback
                .mixWithOthers         // Allow navigation audio
            ]
        )

        try session.setActive(true)
    }
}
```

## Categories

| Category | Use Case |
|----------|----------|
| `.playback` | Music, podcasts (output only) |
| `.record` | Voice memos (input only) |
| `.playAndRecord` | VoIP, voice apps (both) |
| `.ambient` | Game sounds (mixable, silenced by switch) |
| `.soloAmbient` | Game sounds (not mixable) |

## Modes

| Mode | Use Case |
|------|----------|
| `.default` | General audio |
| `.spokenAudio` | Voice/podcast apps (ducking enabled) |
| `.voiceChat` | VoIP calls |
| `.videoRecording` | Video capture |
| `.measurement` | Audio analysis |

## Common Options

```swift
// Speaker instead of earpiece receiver
.defaultToSpeaker

// High-quality Bluetooth output (A2DP)
.allowBluetoothA2DP

// Bluetooth microphone input (HFP)
.allowBluetoothHFP

// Mix with other apps (navigation)
.mixWithOthers

// Duck other apps' audio
.duckOthers

// Use USB/AirPlay when available
.allowAirPlay
```

## Mode-Based Configuration

```swift
enum AudioMode {
    case media      // A2DP only (high quality, built-in mic)
    case call       // HFP + A2DP (Bluetooth mic enabled)
}

func setupAudioSession(mode: AudioMode) throws {
    let session = AVAudioSession.sharedInstance()

    let options: AVAudioSession.CategoryOptions

    switch mode {
    case .media:
        // No HFP = No "phone call" UI in car display
        options = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]

    case .call:
        // HFP enables Bluetooth mic (may show as call in car)
        options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
    }

    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
    try session.setActive(true)
}
```

## Route Change Handling

```swift
@MainActor
final class AudioService {
    private var routeObserver: NSObjectProtocol?

    func setupRouteChangeObserver() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            print("🎧 Device connected")
            refreshAvailableDevices()
        case .oldDeviceUnavailable:
            print("🎧 Device disconnected")
            refreshAvailableDevices()
        default:
            break
        }
    }
}
```

## Interruption Handling

```swift
func setupInterruptionObserver() {
    NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
    ) { [weak self] notification in
        self?.handleInterruption(notification)
    }
}

private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
        return
    }

    switch type {
    case .began:
        // Phone call, Siri, etc. - stop operations
        stopRecording()
        stopPlayback()
    case .ended:
        // Interruption over - don't auto-resume, let user restart
        break
    @unknown default:
        break
    }
}
```

## Session Activation/Deactivation

```swift
// Deactivate before major mode changes
try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

// Brief delay for hardware to settle
try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

// Reactivate with new settings
try AVAudioSession.sharedInstance().setActive(true)
```

## Current Route Inspection

```swift
func logCurrentRoute() {
    let session = AVAudioSession.sharedInstance()
    let route = session.currentRoute

    print("🔊 Outputs:")
    for output in route.outputs {
        print("   - \(output.portName) (\(output.portType.rawValue))")
    }

    print("🎤 Inputs:")
    for input in route.inputs {
        print("   - \(input.portName) (\(input.portType.rawValue))")
    }
}
```
