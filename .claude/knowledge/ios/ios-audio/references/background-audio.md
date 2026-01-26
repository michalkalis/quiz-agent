# Background Audio

## Enabling Background Audio

### 1. Info.plist Configuration

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

Or in Xcode:
- Target → Signing & Capabilities → + Capability → Background Modes
- Check "Audio, AirPlay, and Picture in Picture"

### 2. Audio Session Configuration

```swift
func setupForBackgroundAudio() throws {
    let session = AVAudioSession.sharedInstance()

    try session.setCategory(
        .playAndRecord,     // or .playback for playback-only
        mode: .spokenAudio,
        options: [
            .mixWithOthers,         // Don't stop other apps
            .allowBluetoothA2DP,    // Bluetooth output
            .defaultToSpeaker       // Use speaker
        ]
    )

    try session.setActive(true)
}
```

## What Background Audio Enables

- Audio continues when app is backgrounded
- Audio continues when device is locked
- Integration with Control Center playback controls
- Now Playing information display
- CarPlay audio routing

## Now Playing Info (Optional)

```swift
import MediaPlayer

func updateNowPlayingInfo(title: String, artist: String?, duration: TimeInterval) {
    var info: [String: Any] = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyPlaybackDuration: duration,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
    ]

    if let artist = artist {
        info[MPMediaItemPropertyArtist] = artist
    }

    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
}
```

## Remote Control Events (Optional)

```swift
import MediaPlayer

func setupRemoteControls() {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.addTarget { [weak self] _ in
        self?.play()
        return .success
    }

    commandCenter.pauseCommand.addTarget { [weak self] _ in
        self?.pause()
        return .success
    }

    commandCenter.stopCommand.addTarget { [weak self] _ in
        self?.stop()
        return .success
    }
}
```

## Handling Interruptions in Background

```swift
func setupInterruptionHandling() {
    NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
    ) { [weak self] notification in
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Pause playback - system audio taking over
            self?.pause()

        case .ended:
            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    self?.play()
                }
            }

        @unknown default:
            break
        }
    }
}
```

## Route Changes in Background

```swift
func handleRouteChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
        return
    }

    switch reason {
    case .oldDeviceUnavailable:
        // Headphones unplugged - pause to avoid unexpected speaker playback
        pause()

    case .newDeviceAvailable:
        // New device connected - could auto-resume or let user decide
        break

    default:
        break
    }
}
```

## Background Task for Cleanup

If you need to do cleanup when going to background:

```swift
import UIKit

func beginBackgroundCleanup() {
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    backgroundTaskID = UIApplication.shared.beginBackgroundTask {
        // Cleanup if time expires
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
    }

    // Perform cleanup
    saveCurrentState()

    UIApplication.shared.endBackgroundTask(backgroundTaskID)
}
```

## Troubleshooting

### Audio Stops in Background

1. Verify `UIBackgroundModes` includes `audio` in Info.plist
2. Ensure AVAudioSession category supports background (`.playAndRecord` or `.playback`)
3. Check that audio session is active when going to background
4. Verify player is actively playing (not paused) when backgrounding

### CarPlay Issues

- Use `.spokenAudio` mode for voice apps
- Ensure HFP enabled for mic input in car: `.allowBluetoothHFP`
- Test with physical CarPlay connection (simulator limited)
