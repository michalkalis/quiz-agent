# Audio Playback

## Choosing a Player

| Player | Use Case | Formats |
|--------|----------|---------|
| `AVAudioPlayer` | Local files, sound effects | All iOS-supported |
| `AVPlayer` | Streaming, progress tracking | MP3, AAC, WAV, AIFF |
| `AVQueuePlayer` | Playlists, gapless playback | Same as AVPlayer |

## AVPlayer (Recommended for Streaming)

```swift
@MainActor
final class AudioService: ObservableObject {
    @Published private(set) var isPlaying = false

    private var player: AVPlayer?
    private var currentPlaybackId: UUID?

    func playAudio(_ data: Data) async throws -> TimeInterval {
        let operationId = UUID()
        currentPlaybackId = operationId

        // Save to temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(operationId).mp3")
        try data.write(to: tempURL)

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Create player
        let playerItem = AVPlayerItem(url: tempURL)
        playerItem.preferredForwardBufferDuration = 5.0

        player = AVPlayer(playerItem: playerItem)
        player?.automaticallyWaitsToMinimizeStalling = true

        // Get duration
        let duration = try await playerItem.asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        isPlaying = true

        // Wait for completion
        return try await withTaskCancellationHandler {
            try await waitForPlaybackCompletion(playerItem: playerItem, duration: durationSeconds)
        } onCancel: {
            Task { @MainActor in
                self.player?.pause()
                self.player = nil
                self.isPlaying = false
            }
        }
    }

    private func waitForPlaybackCompletion(
        playerItem: AVPlayerItem,
        duration: TimeInterval
    ) async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            let observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                guard !didResume else { return }
                didResume = true

                self?.isPlaying = false
                self?.player = nil

                continuation.resume(returning: duration)
            }

            player?.play()

            // Store observer for cleanup if needed
        }
    }

    func stopPlayback() async {
        player?.pause()
        player = nil
        isPlaying = false
    }
}
```

## AVAudioPlayer (Simple Local Files)

```swift
@MainActor
final class SoundService {
    private var player: AVAudioPlayer?

    func playSound(named name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            throw AudioError.fileNotFound
        }

        player = try AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func playData(_ data: Data) throws {
        player = try AVAudioPlayer(data: data)
        player?.play()
    }
}
```

## Playback Status Monitoring

```swift
func observePlaybackStatus() {
    player?.observe(\.timeControlStatus, options: [.new]) { player, _ in
        Task { @MainActor in
            switch player.timeControlStatus {
            case .waitingToPlayAtSpecifiedRate:
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                print("⚠️ Buffering: \(reason)")

                // Check for format errors
                if let error = player.currentItem?.error {
                    print("❌ Error: \(error.localizedDescription)")
                }

            case .playing:
                print("▶️ Playing")

            case .paused:
                print("⏸️ Paused")

            @unknown default:
                break
            }
        }
    }
}
```

## Handling Playback Failures

```swift
func observeFailures(for playerItem: AVPlayerItem) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
        forName: .AVPlayerItemFailedToPlayToEndTime,
        object: playerItem,
        queue: .main
    ) { notification in
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("❌ Playback failed: \(error.localizedDescription)")
        }
    }
}
```

## Serial Playback Queue (Prevent Overlap)

```swift
@MainActor
final class AudioService {
    private actor PlaybackQueue {
        private var currentOperation: UUID?

        func acquire(_ id: UUID) async -> Bool {
            while currentOperation != nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            currentOperation = id
            return true
        }

        func release(_ id: UUID) {
            if currentOperation == id {
                currentOperation = nil
            }
        }
    }

    private let queue = PlaybackQueue()

    func playAudio(_ data: Data) async throws -> TimeInterval {
        let id = UUID()

        // Cancel any previous playback
        await stopPlayback()

        // Wait for queue
        _ = await queue.acquire(id)
        defer { Task { await queue.release(id) } }

        // Play audio
        return try await performPlayback(data)
    }
}
```

## Playing from Base64

```swift
func playAudioFromBase64(_ base64: String) async throws -> TimeInterval {
    guard let data = Data(base64Encoded: base64) else {
        throw AudioError.invalidBase64
    }
    return try await playAudio(data)
}
```

## Progress Tracking

```swift
func addProgressObserver() {
    let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

    player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
        let currentTime = CMTimeGetSeconds(time)
        let duration = self?.player?.currentItem?.duration.seconds ?? 0

        // Update progress (0.0 to 1.0)
        let progress = duration > 0 ? currentTime / duration : 0
        self?.playbackProgress = progress
    }
}
```
