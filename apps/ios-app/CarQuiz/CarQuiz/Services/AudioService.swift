//
//  AudioService.swift
//  CarQuiz
//
//  Audio recording and playback service
//  @MainActor because AVFoundation requires main thread
//

import AVFoundation
import AVKit
import Combine
import Foundation

/// Protocol for audio operations
@MainActor
protocol AudioServiceProtocol: Sendable {
    var isRecording: Bool { get }
    var isPlaying: Bool { get }

    func setupAudioSession(mode: AudioMode) throws
    func switchAudioMode(_ mode: AudioMode) async throws
    func requestMicrophonePermission() async -> Bool
    func startRecording() throws
    func stopRecording() async throws -> Data
    func playOpusAudio(_ data: Data) async throws -> TimeInterval
    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval
    func stopPlayback() async  // Now async for proper cleanup
}

/// Main actor audio service for AVFoundation operations
@MainActor
final class AudioService: NSObject, ObservableObject, AudioServiceProtocol {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false

    // MARK: - Audio Queue Actor (Serial Execution)

    /// Actor-based serial queue ensuring only one audio operation at a time
    private actor AudioQueue {
        private var currentOperation: UUID?

        func setCurrentOperation(_ id: UUID) {
            currentOperation = id
        }

        func getCurrentOperation() -> UUID? {
            currentOperation
        }

        func clearOperation(_ id: UUID) {
            if currentOperation == id {
                currentOperation = nil
            }
        }

        func isOperationActive(_ id: UUID) -> Bool {
            currentOperation == id
        }
    }

    private let audioQueue = AudioQueue()

    // MARK: - Playback State

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVPlayer?
    private var currentPlaybackTask: Task<TimeInterval, Error>?
    private var currentPlaybackId: UUID?
    private var currentAudioMode: AudioMode = AudioMode.default

    // Mark as nonisolated(unsafe) because NSObjectProtocol is not Sendable in Swift 6
    // Only accessed on main queue, so cross-isolation is safe
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?

    deinit {
        // Clean up route change observer
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        // Cancel any in-flight playback
        currentPlaybackTask?.cancel()
    }

    // MARK: - Audio Session Setup

    func setupAudioSession(mode: AudioMode) throws {
        let session = AVAudioSession.sharedInstance()

        // Store current mode
        currentAudioMode = mode

        // Configure audio session options based on selected mode
        var options: AVAudioSession.CategoryOptions

        switch mode.id {
        case "media":
            // Media Mode: A2DP only (high-quality playback, built-in mic)
            // No HFP = No "phone call" UI in car display
            options = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]

            if Config.verboseLogging {
                print("🎤 Audio session: Media Mode (A2DP only)")
            }

        case "call":
            // Call Mode: HFP + A2DP (Bluetooth mic enabled)
            // May show as "phone call" in car display
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]

            if Config.verboseLogging {
                print("🎤 Audio session: Call Mode (HFP + A2DP)")
            }

        default:
            // Fallback to call mode (current behavior)
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]

            if Config.verboseLogging {
                print("⚠️ Unknown audio mode '\(mode.id)', defaulting to Call Mode")
            }
        }

        // Configure for background playback and recording
        // .defaultToSpeaker forces output to speaker instead of receiver (louder audio)
        // .allowBluetoothHFP enables Bluetooth microphone input (Hands-Free Profile)
        // .allowBluetoothA2DP enables high-quality Bluetooth playback (A2DP)
        // .mixWithOthers allows navigation apps to play simultaneously
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: options
        )

        try session.setActive(true)

        // Observe audio route changes (Bluetooth connect/disconnect)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Already on main queue, can call directly
            self?.handleRouteChange(notification)
        }

        if Config.verboseLogging {
            print("🎤 Audio session configured for background playback and recording")
        }
    }

    /// Switch audio mode dynamically (e.g., during quiz)
    /// - Parameter mode: New audio mode to activate
    func switchAudioMode(_ mode: AudioMode) async throws {
        guard mode.id != currentAudioMode.id else {
            if Config.verboseLogging {
                print("🔄 Audio mode already set to \(mode.name), skipping switch")
            }
            return
        }

        // Stop any active recording/playback first
        if isRecording {
            _ = try? await stopRecording()
        }
        if isPlaying {
            await stopPlayback()  // Now async
        }

        // Deactivate current session
        try AVAudioSession.sharedInstance().setActive(false)

        // Reconfigure with new mode
        try setupAudioSession(mode: mode)

        if Config.verboseLogging {
            print("🔄 Audio mode switched to: \(mode.name)")
        }
    }

    nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            // Bluetooth connected
            if Config.verboseLogging {
                print("🎧 Bluetooth device connected")
            }
        case .oldDeviceUnavailable:
            // Bluetooth disconnected - gracefully fall back to built-in mic
            if Config.verboseLogging {
                print("🎧 Bluetooth device disconnected, using built-in microphone")
            }
        default:
            break
        }
    }

    // MARK: - Microphone Permission

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                if Config.verboseLogging {
                    print("🎤 Microphone permission: \(granted ? "granted" : "denied")")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    func startRecording() throws {
        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Configure audio recorder settings for voice
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,  // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64000  // 64kbps for voice
        ]

        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.record()

        isRecording = true

        if Config.verboseLogging {
            print("🎤 Started recording to: \(fileName)")
        }
    }

    func stopRecording() async throws -> Data {
        guard let recorder = audioRecorder else {
            throw AudioError.noActiveRecording
        }

        recorder.stop()
        isRecording = false

        let url = recorder.url

        if Config.verboseLogging {
            print("🎤 Stopped recording")
        }

        // Read the recorded audio data
        let data = try Data(contentsOf: url)

        // Clean up temporary file
        try? FileManager.default.removeItem(at: url)

        audioRecorder = nil

        if Config.verboseLogging {
            print("🎤 Recording data: \(data.count) bytes")
        }

        return data
    }

    // MARK: - Playback

    func playOpusAudio(_ data: Data) async throws -> TimeInterval {
        let operationId = UUID()

        // Cancel any previous playback first
        await cancelCurrentPlayback()

        // Wait for any in-flight operation to complete (serial queue)
        while await audioQueue.getCurrentOperation() != nil {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms polling
        }

        // Mark this as the current operation
        await audioQueue.setCurrentOperation(operationId)
        currentPlaybackId = operationId

        // Perform the actual playback
        return try await performPlayback(data: data, operationId: operationId)
    }

    /// Performs the actual audio playback with proper cancellation support
    private func performPlayback(data: Data, operationId: UUID) async throws -> TimeInterval {
        // Save to temporary file for playback
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(operationId).opus")

        try data.write(to: tempURL)

        if Config.verboseLogging {
            print("🔊 Playing audio: \(data.count) bytes from \(tempURL.lastPathComponent)")
        }

        // Ensure cleanup happens even on cancellation or error
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Use AVPlayer for better codec support (including Opus)
        let playerItem = AVPlayerItem(url: tempURL)

        // Configure buffering for smoother playback
        playerItem.preferredForwardBufferDuration = 5.0  // Buffer 5 seconds ahead

        audioPlayer = AVPlayer(playerItem: playerItem)

        // Automatically wait when buffering to minimize stalling
        audioPlayer?.automaticallyWaitsToMinimizeStalling = true

        // Get duration before starting playback (async in iOS 18+)
        let asset = playerItem.asset
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        if Config.verboseLogging {
            print("🔊 Audio duration: \(String(format: "%.1f", durationSeconds))s")
        }

        isPlaying = true

        // Use withTaskCancellationHandler for proper cleanup
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval, Error>) in
                // Mark as nonisolated(unsafe) because NSObjectProtocol is not Sendable in Swift 6
                // These are only accessed on main queue, so cross-isolation is safe
                nonisolated(unsafe) var successObserver: NSObjectProtocol?
                nonisolated(unsafe) var failureObserver: NSObjectProtocol?
                nonisolated(unsafe) var statusObserver: NSKeyValueObservation?
                var didResume = false

                // Helper to ensure continuation resumes only once
                func resumeOnce(with result: Result<TimeInterval, Error>) {
                    guard !didResume else { return }
                    didResume = true

                    // Clean up observers
                    if let observer = successObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    if let observer = failureObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    statusObserver?.invalidate()

                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                // Monitor playback status for stalling
                statusObserver = audioPlayer?.observe(\.timeControlStatus, options: [.new]) { player, _ in
                    Task { @MainActor in
                        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                            if Config.verboseLogging {
                                print("⚠️ Audio playback stalling, waiting for buffer...")
                            }
                        } else if player.timeControlStatus == .playing {
                            if Config.verboseLogging {
                                print("▶️ Audio playback resumed")
                            }
                        }
                    }
                }

                // Observe when playback finishes successfully
                successObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.audioQueue.clearOperation(operationId)
                        self?.isPlaying = false
                        self?.currentPlaybackId = nil

                        if Config.verboseLogging {
                            print("🔊 Playback completed")
                        }

                        resumeOnce(with: .success(durationSeconds))
                    }
                }

                // Observe playback failures
                failureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] notification in
                    // Extract error outside Task to avoid concurrency issues
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error

                    Task { @MainActor [weak self] in
                        await self?.audioQueue.clearOperation(operationId)
                        self?.isPlaying = false
                        self?.currentPlaybackId = nil

                        if Config.verboseLogging {
                            print("❌ Playback failed")
                        }

                        resumeOnce(with: .failure(error ?? AudioError.playbackFailed))
                    }
                }

                // Start playback
                audioPlayer?.play()

                if Config.verboseLogging {
                    print("🔊 Started AVPlayer playback")
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cleanupPlayback(operationId: operationId)
            }
        }
    }

    /// Cleans up playback resources for a specific operation
    private func cleanupPlayback(operationId: UUID) async {
        guard currentPlaybackId == operationId else { return }

        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        currentPlaybackId = nil

        await audioQueue.clearOperation(operationId)

        if Config.verboseLogging {
            print("🔊 Cleaned up playback (id: \(operationId))")
        }
    }

    /// Cancels any currently active playback
    private func cancelCurrentPlayback() async {
        currentPlaybackTask?.cancel()
        currentPlaybackTask = nil

        if let id = currentPlaybackId {
            await cleanupPlayback(operationId: id)
        }
    }

    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval {
        guard let data = Data(base64Encoded: base64) else {
            throw AudioError.invalidBase64
        }
        return try await playOpusAudio(data)
    }

    func stopPlayback() async {
        if let id = currentPlaybackId {
            await cleanupPlayback(operationId: id)
        }

        if Config.verboseLogging {
            print("🔊 Stopped playback")
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            isRecording = false
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            isRecording = false
            if Config.verboseLogging {
                print("❌ Recording error: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }
}

// MARK: - Error Types

enum AudioError: LocalizedError {
    case noActiveRecording
    case recordingFailed
    case playbackFailed
    case permissionDenied
    case invalidBase64

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording"
        case .recordingFailed:
            return "Recording failed"
        case .playbackFailed:
            return "Playback failed"
        case .permissionDenied:
            return "Microphone permission denied"
        case .invalidBase64:
            return "Invalid base64 audio data"
        }
    }
}

// MARK: - Mock for Testing

#if DEBUG
@MainActor
final class MockAudioService: ObservableObject, AudioServiceProtocol {
    var isRecording = false
    var isPlaying = false
    var shouldFailRecording = false
    var shouldFailPlayback = false
    var mockRecordingData = Data("mock audio".utf8)

    func setupAudioSession(mode: AudioMode) throws {
        // Mock implementation
    }

    func switchAudioMode(_ mode: AudioMode) async throws {
        // Mock implementation
    }

    func requestMicrophonePermission() async -> Bool {
        return true
    }

    func startRecording() throws {
        if shouldFailRecording {
            throw AudioError.recordingFailed
        }
        isRecording = true
    }

    func stopRecording() async throws -> Data {
        isRecording = false
        if shouldFailRecording {
            throw AudioError.recordingFailed
        }
        return mockRecordingData
    }

    func playOpusAudio(_ data: Data) async throws -> TimeInterval {
        if shouldFailPlayback {
            throw AudioError.playbackFailed
        }
        isPlaying = true
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        isPlaying = false
        return 3.0  // Mock duration
    }

    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval {
        guard Data(base64Encoded: base64) != nil else {
            throw AudioError.invalidBase64
        }
        return try await playOpusAudio(Data())
    }

    func stopPlayback() async {
        isPlaying = false
    }
}
#endif
