# Audio Recording with AVAudioRecorder

## Basic Recording Setup

```swift
@MainActor
final class AudioService: ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?

    func startRecording() throws {
        // Create temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Voice-optimized settings
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,      // 16kHz for voice
            AVNumberOfChannelsKey: 1,       // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 32000      // 32kbps
        ]

        recorder = try AVAudioRecorder(url: fileURL, settings: settings)

        guard recorder?.record() == true else {
            recorder = nil
            throw AudioError.recordingFailed
        }

        isRecording = true
    }

    func stopRecording() async throws -> Data {
        guard let recorder = recorder else {
            throw AudioError.noActiveRecording
        }

        recorder.stop()
        isRecording = false

        let url = recorder.url
        let data = try Data(contentsOf: url)

        // Validate minimum size (empty M4A header is ~28 bytes)
        guard data.count >= 500 else {
            throw AudioError.recordingTooShort
        }

        // Cleanup
        try? FileManager.default.removeItem(at: url)
        self.recorder = nil

        return data
    }
}
```

## Recording Settings by Use Case

### Voice Recording (Speech)
```swift
// Optimized for voice: smaller files, faster processing
let voiceSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 16000.0,       // 16kHz sufficient for voice
    AVNumberOfChannelsKey: 1,        // Mono
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    AVEncoderBitRateKey: 32000       // 32kbps
]
```

### Music Recording (High Quality)
```swift
let musicSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 44100.0,       // CD quality
    AVNumberOfChannelsKey: 2,        // Stereo
    AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
    AVEncoderBitRateKey: 256000      // 256kbps
]
```

### Lossless Recording
```swift
let losslessSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatAppleLossless),
    AVSampleRateKey: 44100.0,
    AVNumberOfChannelsKey: 2,
    AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
]
```

## Requesting Permission

```swift
func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}

// Check before recording
func checkPermission() -> Bool {
    AVAudioSession.sharedInstance().recordPermission == .granted
}
```

## Preparing for Recording

**Critical:** Add a settle delay after stopping playback to prevent empty recordings.

```swift
func prepareForRecording() async {
    // Stop any active playback
    await stopPlayback()

    // Reset audio session
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        try session.setActive(true)
    } catch {
        print("⚠️ Session reset failed: \(error)")
    }

    // Hardware settle time
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
}
```

## Delegate for Recording Events

```swift
extension AudioService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            isRecording = false
            if !flag {
                print("⚠️ Recording finished unsuccessfully")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        Task { @MainActor in
            isRecording = false
            print("❌ Recording encode error: \(error?.localizedDescription ?? "unknown")")
        }
    }
}
```

## Common Issues

### Empty Recording (28 bytes)
```swift
// Cause: Hardware not ready after playback stopped

// Solution: Add prepare step with delay
await prepareForRecording()  // Includes 100ms settle time
try startRecording()
```

### Recording Too Short
```swift
// Validate recording length
let minimumValidSize = 500  // bytes
guard data.count >= minimumValidSize else {
    throw AudioError.recordingTooShort
}
```

### Permission Denied
```swift
// Check and handle gracefully
let status = AVAudioSession.sharedInstance().recordPermission
switch status {
case .undetermined:
    let granted = await requestMicrophonePermission()
    // Handle result
case .denied:
    // Show settings prompt
    showMicrophonePermissionAlert()
case .granted:
    try startRecording()
@unknown default:
    break
}
```

## Info.plist Requirement

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record your answers.</string>
```
