//
//  AudioService.swift
//  CarQuiz
//
//  Audio recording and playback service
//  @MainActor because AVFoundation requires main thread
//
//  IMPORTANT: Audio Format Compatibility
//  - iOS AVPlayer supports Opus ONLY in CAF/MOV/MP4 containers
//  - OggOpus (.opus/.ogg) is NOT supported by AVPlayer
//  - Backend must serve MP3 or AAC in M4A for reliable playback
//  - See: https://developer.apple.com/documentation/avfoundation/avasset
//

import AVFoundation
import AVKit
import Combine
import Foundation
import os
import UIKit

/// Callback for streaming PCM audio chunks (raw 16kHz 16-bit mono PCM data)
typealias PCMChunkHandler = @Sendable (Data) -> Void

/// Protocol for audio operations
@MainActor
protocol AudioServiceProtocol: Sendable {
    var isRecording: Bool { get }
    var isPlaying: Bool { get }

    // Device management
    var availableInputDevices: [AudioDevice] { get }
    var currentInputDevice: AudioDevice? { get }
    var currentOutputDeviceName: String { get }

    func setupAudioSession(mode: AudioMode) throws
    func switchAudioMode(_ mode: AudioMode) async throws
    func requestMicrophonePermission() async -> Bool
    func prepareForRecording() async  // Stops playback and waits for hardware settle
    func startRecording() throws
    func stopRecording() async throws -> Data
    func playOpusAudio(_ data: Data) async throws -> TimeInterval
    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval
    func stopPlayback() async  // Now async for proper cleanup
    func speakText(_ text: String) async  // Local TTS via AVSpeechSynthesizer

    // Streaming PCM recording (for ElevenLabs STT)
    func startStreamingRecording(onChunk: @escaping PCMChunkHandler) throws
    func stopStreamingRecording()

    // Device selection
    func refreshAvailableDevices()
    func setPreferredInputDevice(_ device: AudioDevice?) throws
}

/// Main actor audio service for AVFoundation operations
@MainActor
final class AudioService: NSObject, ObservableObject, AudioServiceProtocol {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false

    // MARK: - Device Management

    /// Available input devices (microphones)
    @Published private(set) var availableInputDevices: [AudioDevice] = []

    /// Currently active input device (nil = automatic)
    @Published private(set) var currentInputDevice: AudioDevice?

    /// Current output device name for display
    var currentOutputDeviceName: String {
        let session = AVAudioSession.sharedInstance()
        if let output = session.currentRoute.outputs.first {
            return output.portName
        }
        return "iPhone"
    }

    // MARK: - Playback State

    /// Consolidated playback state - single source of truth
    /// Replaces the previous triple-variable tracking (currentPlaybackTask, currentPlaybackId, isPlaybackComplete)
    enum PlaybackState: Equatable, Sendable {
        case idle
        case playing(id: UUID)

        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var playbackId: UUID? {
            if case .playing(let id) = self { return id }
            return nil
        }
    }

    private var playbackState: PlaybackState = .idle

    // Tracked continuation for active playback — allows stopPlayback/cleanupPlayback
    // to properly resume the continuation instead of leaking it.
    // Mark as nonisolated(unsafe) because withCheckedThrowingContinuation's closure is @Sendable.
    // All access is on main queue, so cross-isolation is safe.
    nonisolated(unsafe) private var playbackContinuation: CheckedContinuation<TimeInterval, Error>?

    // Tracked notification observers for active playback — removed on stop
    nonisolated(unsafe) private var playbackSuccessObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackFailureObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackStalledTimer: Timer?

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVPlayer?
    private var speechSynthesizer = AVSpeechSynthesizer()
    private var speechCompletion: CheckedContinuation<Void, Never>?
    private var currentAudioMode: AudioMode = AudioMode.default

    // Mark as nonisolated(unsafe) because NSObjectProtocol is not Sendable in Swift 6
    // Only accessed on main queue, so cross-isolation is safe
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?

    deinit {
        // Clean up observers
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

            Logger.audio.info("🎤 Audio session: Media Mode (A2DP only)")

        case "call":
            // Call Mode: HFP + A2DP (Bluetooth mic enabled)
            // May show as "phone call" in car display
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]

            Logger.audio.info("🎤 Audio session: Call Mode (HFP + A2DP)")

        default:
            // Fallback to call mode (current behavior)
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]

            Logger.audio.warning("⚠️ Unknown audio mode '\(mode.id, privacy: .public)', defaulting to Call Mode")
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

        // Observe audio session interruptions (phone calls, Siri, other apps)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        Logger.audio.info("🎤 Audio session configured for background playback and recording")
    }

    /// Switch audio mode dynamically (e.g., during quiz)
    /// - Parameter mode: New audio mode to activate
    func switchAudioMode(_ mode: AudioMode) async throws {
        guard mode.id != currentAudioMode.id else {
            Logger.audio.debug("🔄 Audio mode already set to \(mode.name, privacy: .public), skipping switch")
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

        Logger.audio.info("🔄 Audio mode switched to: \(mode.name, privacy: .public)")
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
            Logger.audio.info("🎧 Bluetooth device connected")
            // Refresh available devices on main actor
            Task { @MainActor in
                self.refreshAvailableDevices()
            }
        case .oldDeviceUnavailable:
            // Bluetooth disconnected - gracefully fall back to built-in mic
            Logger.audio.info("🎧 Bluetooth device disconnected, using built-in microphone")
            // Refresh available devices on main actor
            Task { @MainActor in
                self.refreshAvailableDevices()
                self.updateCurrentInputDevice()
            }
        default:
            break
        }
    }

    /// Handle audio session interruptions (phone calls, Siri, other apps)
    nonisolated private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        Task { @MainActor in
            switch type {
            case .began:
                // Interruption started - stop any active operations to prevent corruption
                if self.isRecording {
                    _ = try? await self.stopRecording()
                }
                if self.isPlaying {
                    await self.stopPlayback()
                }
                Logger.audio.warning("⚠️ Audio session interrupted")
            case .ended:
                // Interruption ended - log but don't auto-resume (let user restart)
                Logger.audio.info("✅ Audio session interruption ended")
            @unknown default:
                break
            }
        }
    }

    // MARK: - Device Management

    /// Refresh list of available input devices
    func refreshAvailableDevices() {
        let session = AVAudioSession.sharedInstance()

        guard let inputs = session.availableInputs else {
            availableInputDevices = []
            Logger.audio.debug("🎤 No input devices available")
            return
        }

        availableInputDevices = inputs.map { AudioDevice.from(port: $0) }

        Logger.audio.debug("🎤 Available input devices: \(self.availableInputDevices.map { $0.name }, privacy: .public)")

        // Update current device state
        updateCurrentInputDevice()
    }

    /// Update the current input device based on session's preferred input
    private func updateCurrentInputDevice() {
        let session = AVAudioSession.sharedInstance()

        if let preferredInput = session.preferredInput {
            currentInputDevice = AudioDevice.from(port: preferredInput)
        } else {
            // No preferred input = automatic selection
            currentInputDevice = nil
        }

        Logger.audio.debug("🎤 Current input device: \(self.currentInputDevice?.name ?? "Automatic", privacy: .public)")
    }

    /// Set preferred input device
    /// - Parameter device: Device to use, or nil for automatic selection
    func setPreferredInputDevice(_ device: AudioDevice?) throws {
        let session = AVAudioSession.sharedInstance()

        if let device = device, !device.isAutomatic {
            // Find matching AVAudioSessionPortDescription
            guard let inputs = session.availableInputs,
                  let port = inputs.first(where: { $0.uid == device.id }) else {
                throw AudioError.deviceNotFound
            }

            try session.setPreferredInput(port)
            currentInputDevice = device

            Logger.audio.info("🎤 Set preferred input: \(device.name, privacy: .public)")
        } else {
            // Clear preference - let iOS choose automatically
            try session.setPreferredInput(nil)
            currentInputDevice = nil

            Logger.audio.info("🎤 Cleared preferred input (automatic selection)")
        }
    }

    // MARK: - Microphone Permission

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                Logger.audio.info("🎤 Microphone permission: \(granted ? "granted" : "denied", privacy: .public)")
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    /// Prepares audio system for recording by stopping playback and waiting for hardware
    ///
    /// stopPlayback() now guarantees cleanup is complete before returning,
    /// eliminating the need for polling. We only need hardware settle time.
    func prepareForRecording() async {
        // Stop any active playback - this is now a blocking operation
        await stopPlayback()

        // Hardware settle time - AVAudioSession needs time to release playback resources
        // and transition to recording mode. Without this delay, recording may start
        // before hardware is ready, resulting in empty/corrupt recordings (28 bytes)
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        Logger.audio.debug("🎤 Audio system ready for recording")
    }

    func startRecording() throws {
        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Configure audio recorder settings for voice
        // 16kHz sample rate is sufficient for speech (voice range ~85-255Hz fundamentals)
        // Benefits: ~2.75x smaller files, faster upload, faster Whisper processing
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,  // Voice-optimized (was 44100)
            AVNumberOfChannelsKey: 1,  // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 32000  // 32kbps sufficient for 16kHz voice
        ]

        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self

        // Try to start recording with retry logic
        // record() can fail if audio session isn't fully ready after playback
        var started = false

        for attempt in 1 ... 3 {
            started = audioRecorder?.record() ?? false
            if started {
                break
            }

            // Log retry attempt
            Logger.audio.warning("⚠️ Recording attempt \(attempt, privacy: .public) failed, retrying...")

            // Exponential backoff: 100ms, 200ms, 400ms
            let delayNs = UInt64(100_000_000 * (1 << (attempt - 1)))

            // Use RunLoop to wait without blocking @MainActor
            // We can't use Task.sleep in a non-async function
            let delaySeconds = Double(delayNs) / 1_000_000_000
            RunLoop.current.run(until: Date().addingTimeInterval(delaySeconds))
        }

        guard started else {
            audioRecorder = nil
            Logger.audio.error("❌ Recording failed to start after 3 attempts")
            // Log audio session state for diagnostics
            let session = AVAudioSession.sharedInstance()
            Logger.audio.error("   Session category: \(session.category.rawValue, privacy: .public)")
            Logger.audio.error("   Session mode: \(session.mode.rawValue, privacy: .public)")
            Logger.audio.error("   Input available: \(session.isInputAvailable, privacy: .public)")
            throw AudioError.recordingFailed
        }

        isRecording = true

        Logger.audio.info("🎤 Started recording to: \(fileName, privacy: .public)")
    }

    func stopRecording() async throws -> Data {
        guard let recorder = audioRecorder else {
            throw AudioError.noActiveRecording
        }

        recorder.stop()
        isRecording = false

        let url = recorder.url

        Logger.audio.info("🎤 Stopped recording")

        // Read the recorded audio data
        let data = try Data(contentsOf: url)

        // Validate minimum recording size
        // M4A header alone is ~28 bytes, a 1-second 16kHz mono recording is ~2KB minimum
        // Use 500 bytes as threshold to catch empty/corrupt recordings
        let minimumValidSize = 500
        guard data.count >= minimumValidSize else {
            Logger.audio.error("❌ Recording too short: \(data.count, privacy: .public) bytes (minimum: \(minimumValidSize, privacy: .public))")
            try? FileManager.default.removeItem(at: url)
            audioRecorder = nil
            throw AudioError.recordingTooShort
        }

        // Clean up temporary file
        try? FileManager.default.removeItem(at: url)

        audioRecorder = nil

        Logger.audio.debug("🎤 Recording data: \(data.count, privacy: .public) bytes")

        return data
    }

    // MARK: - Streaming PCM Recording (AVAudioEngine)

    private var audioEngine: AVAudioEngine?

    /// Start streaming PCM recording via AVAudioEngine.
    /// Calls `onChunk` with raw 16kHz 16-bit mono PCM data at regular intervals.
    /// Use `stopStreamingRecording()` to stop.
    func startStreamingRecording(onChunk: @escaping PCMChunkHandler) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Target format: 16kHz, 16-bit, mono (matching ElevenLabs pcm_16000)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioError.recordingFailed
        }

        // Get the hardware input format
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Validate hardware format — can be 0 Hz on device after audio route changes
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            Logger.audio.error("🎤 Streaming: invalid hardware format: \(hardwareFormat.sampleRate, privacy: .public)Hz, \(hardwareFormat.channelCount, privacy: .public)ch")
            throw AudioError.recordingFailed
        }

        Logger.audio.debug("🎤 Streaming: hardware format: \(hardwareFormat.sampleRate, privacy: .public)Hz, \(hardwareFormat.channelCount, privacy: .public)ch")
        Logger.audio.debug("🎤 Streaming: target format: \(targetFormat.sampleRate, privacy: .public)Hz, \(targetFormat.channelCount, privacy: .public)ch")

        // Create a converter from hardware format to target format
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioError.recordingFailed
        }

        // Buffer for accumulating PCM data before sending
        let chunkInterval = Config.sttStreamingChunkIntervalMs
        let samplesPerChunk = Int(16000.0 * Double(chunkInterval) / 1000.0) // e.g., 4000 samples for 250ms

        // Use nonisolated(unsafe) for the mutable buffer accessed in the tap closure.
        // Safe because the tap callback is serial (one buffer at a time) and we only
        // read/reset the accumulated buffer within the same closure.
        nonisolated(unsafe) var accumulatedData = Data()

        // Install a tap on the input node
        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * Double(chunkInterval) / 1000.0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { buffer, _ in
            // Belt-and-suspenders guard against division by zero
            guard hardwareFormat.sampleRate > 0 else { return }
            // Convert hardware buffer to 16kHz 16-bit mono
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / hardwareFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // Extract raw PCM bytes
            if let channelData = convertedBuffer.int16ChannelData {
                let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
                let data = Data(bytes: channelData[0], count: byteCount)
                accumulatedData.append(data)
            }

            // Send chunk when we've accumulated enough samples
            let targetBytes = samplesPerChunk * MemoryLayout<Int16>.size
            if accumulatedData.count >= targetBytes {
                let chunk = accumulatedData.prefix(targetBytes)
                accumulatedData = accumulatedData.dropFirst(targetBytes).asData
                onChunk(Data(chunk))
            }
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        isRecording = true

        Logger.audio.info("🎤 Streaming PCM recording started (16kHz, 16-bit, mono)")
    }

    /// Stop streaming PCM recording
    func stopStreamingRecording() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.audioEngine = nil
        isRecording = false

        Logger.audio.info("🎤 Streaming PCM recording stopped")
    }

    // MARK: - Playback

    func playOpusAudio(_ data: Data) async throws -> TimeInterval {
        let operationId = UUID()

        // Cancel any previous playback first
        await stopPlayback()

        // Mark this as the current operation
        playbackState = .playing(id: operationId)

        // Perform the actual playback
        return try await performPlayback(data: data, operationId: operationId)
    }

    /// Performs the actual audio playback with proper cancellation support
    private func performPlayback(data: Data, operationId: UUID) async throws -> TimeInterval {
        // playbackState already set to .playing(id: operationId) by caller

        // Save to temporary file for playback (MP3 for universal AVPlayer compatibility)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(operationId).mp3")

        try data.write(to: tempURL)

        // Force flush to disk - prevents AVPlayer from reading incomplete data
        // This is critical for files written immediately before playback
        if let fileHandle = try? FileHandle(forWritingTo: tempURL) {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }

        Logger.audio.info("🔊 Playing audio: \(data.count, privacy: .public) bytes from \(tempURL.lastPathComponent, privacy: .public)")

        // Clean up temp file on exit (state cleanup handled by observers/onCancel)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Use AVPlayer for codec support (MP3, AAC, etc.)
        let playerItem = AVPlayerItem(url: tempURL)

        // Configure buffering for smoother playback
        playerItem.preferredForwardBufferDuration = 5.0  // Buffer 5 seconds ahead

        audioPlayer = AVPlayer(playerItem: playerItem)

        // IMPORTANT: Disable auto-wait for local files
        // automaticallyWaitsToMinimizeStalling = true is designed for streaming
        // For local files, it causes unnecessary "evaluating buffering rate" delays
        audioPlayer?.automaticallyWaitsToMinimizeStalling = false

        // Get duration before starting playback (async in iOS 18+)
        let asset = playerItem.asset
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        Logger.audio.debug("🔊 Audio duration: \(String(format: "%.1f", durationSeconds), privacy: .public)s")

        isPlaying = true

        // Use withTaskCancellationHandler for proper cleanup
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TimeInterval, Error>) in
                nonisolated(unsafe) var statusObserver: NSKeyValueObservation?
                var didResume = false
                var hasStartedPlaying = false

                // Store continuation so stopPlayback/cleanupPlayback can resume it
                self.playbackContinuation = continuation

                // Helper to ensure continuation resumes only once
                func resumeOnce(with result: Result<TimeInterval, Error>) {
                    guard !didResume else { return }
                    didResume = true

                    // Clear tracked state
                    self.playbackContinuation = nil

                    // Clean up observers and timer
                    if let observer = self.playbackSuccessObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.playbackSuccessObserver = nil
                    }
                    if let observer = self.playbackFailureObserver {
                        NotificationCenter.default.removeObserver(observer)
                        self.playbackFailureObserver = nil
                    }
                    statusObserver?.invalidate()
                    self.playbackStalledTimer?.invalidate()
                    self.playbackStalledTimer = nil

                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                // Monitor playback status for stalling with detailed diagnostics
                statusObserver = audioPlayer?.observe(\.timeControlStatus, options: [.new]) { player, _ in
                    Task { @MainActor in
                        switch player.timeControlStatus {
                        case .waitingToPlayAtSpecifiedRate:
                            let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
                            Logger.audio.warning("⚠️ Audio playback stalling, reason: \(reason, privacy: .public)")
                            // Check for format errors (critical for diagnosing codec issues)
                            if let error = player.currentItem?.error {
                                Logger.audio.error("❌ Player item error: \(error.localizedDescription, privacy: .public)")
                            }
                        case .playing:
                            hasStartedPlaying = true
                            // Cancel stall timer once playback starts
                            self.playbackStalledTimer?.invalidate()
                            self.playbackStalledTimer = nil
                            Logger.audio.debug("▶️ Audio playback resumed")
                        case .paused:
                            break
                        @unknown default:
                            break
                        }
                    }
                }

                // Playback timeout - fail if playback doesn't start within 5 seconds
                // This prevents infinite stalling on problematic files
                self.playbackStalledTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard !hasStartedPlaying else { return }

                        Logger.audio.warning("⚠️ Playback timeout - audio failed to start within 5 seconds")

                        self?.isPlaying = false
                        self?.playbackState = .idle

                        resumeOnce(with: .failure(AudioError.playbackFailed))
                    }
                }

                // Observe when playback finishes successfully
                self.playbackSuccessObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isPlaying = false
                        self?.playbackState = .idle

                        Logger.audio.info("🔊 Playback completed")

                        resumeOnce(with: .success(durationSeconds))
                    }
                }

                // Observe playback failures
                self.playbackFailureObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] notification in
                    // Extract error outside Task to avoid concurrency issues
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error

                    Task { @MainActor [weak self] in
                        self?.isPlaying = false
                        self?.playbackState = .idle

                        Logger.audio.error("❌ Playback failed")

                        resumeOnce(with: .failure(error ?? AudioError.playbackFailed))
                    }
                }

                // Start playback
                audioPlayer?.play()

                Logger.audio.debug("🔊 Started AVPlayer playback")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cleanupPlayback(operationId: operationId)
            }
        }
    }

    /// Cleans up playback resources for a specific operation
    private func cleanupPlayback(operationId: UUID) async {
        // Only cleanup if this is the active operation (prevents TOCTOU race)
        guard case .playing(let activeId) = playbackState, activeId == operationId else { return }

        // Resume leaked continuation before destroying player
        resumePlaybackContinuation()

        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        playbackState = .idle

        Logger.audio.debug("🔊 Cleaned up playback (id: \(operationId, privacy: .public))")
    }

    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval {
        guard let data = Data(base64Encoded: base64) else {
            throw AudioError.invalidBase64
        }
        return try await playOpusAudio(data)
    }

    /// Stops playback and ensures cleanup completes before returning (blocking)
    func stopPlayback() async {
        // Early exit if not playing
        guard case .playing = playbackState else {
            Logger.audio.debug("🔊 stopPlayback called but not playing")
            return
        }

        // Resume leaked continuation before destroying player —
        // without this, the CheckedContinuation from playOpusAudio is never resumed
        // and Swift runtime crashes with "SWIFT TASK CONTINUATION MISUSE: leaked"
        resumePlaybackContinuation()

        // Pause and cleanup
        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        playbackState = .idle

        Logger.audio.info("🔊 Stopped playback")
    }

    /// Resume and clean up the active playback continuation with CancellationError.
    /// Safe to call multiple times — only the first call resumes.
    private func resumePlaybackContinuation() {
        // Clean up observers first — they could otherwise fire and double-resume
        if let observer = playbackSuccessObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackSuccessObserver = nil
        }
        if let observer = playbackFailureObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailureObserver = nil
        }
        playbackStalledTimer?.invalidate()
        playbackStalledTimer = nil

        // Resume the continuation so the awaiting code can proceed
        if let cont = playbackContinuation {
            playbackContinuation = nil
            cont.resume(throwing: CancellationError())
        } else {
            Logger.audio.debug("🔊 resumePlaybackContinuation: no active continuation (already resumed or never started)")
        }
    }

    // MARK: - Local TTS (AVSpeechSynthesizer)

    /// Speak text using built-in iOS TTS (no network required).
    /// Used for status messages like score announcements and help text.
    /// When VoiceOver is active, routes through accessibility announcements
    /// to prevent VoiceOver and AVSpeechSynthesizer fighting over the audio channel.
    func speakText(_ text: String) async {
        // Stop any current audio first
        await stopPlayback()
        speechSynthesizer.stopSpeaking(at: .immediate)

        Logger.audio.info("🗣️ Speaking: \(text, privacy: .public)")

        // When VoiceOver is active, use accessibility announcement instead
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            // Brief delay so the announcement has time to be spoken
            try? await Task.sleep(for: .milliseconds(500))

            Logger.audio.debug("🗣️ Routed through VoiceOver announcement")
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Resume any pending speech continuation to prevent leak
            // (can happen if speakText() is called while previous utterance is active)
            if let pending = speechCompletion {
                Logger.audio.warning("🗣️ Resuming leaked speechCompletion before starting new utterance")
                pending.resume()
            }
            speechCompletion = continuation
            speechSynthesizer.delegate = self
            speechSynthesizer.speak(utterance)
        }

        Logger.audio.debug("🗣️ Speech completed")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AudioService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechCompletion?.resume()
            speechCompletion = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechCompletion?.resume()
            speechCompletion = nil
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
            Logger.audio.error("❌ Recording error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }
}

// MARK: - Error Types

enum AudioError: LocalizedError {
    case noActiveRecording
    case recordingFailed
    case recordingTooShort
    case playbackFailed
    case permissionDenied
    case invalidBase64
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording"
        case .recordingFailed:
            return "Recording failed"
        case .recordingTooShort:
            return "Recording too short or empty"
        case .playbackFailed:
            return "Playback failed"
        case .permissionDenied:
            return "Microphone permission denied"
        case .invalidBase64:
            return "Invalid base64 audio data"
        case .deviceNotFound:
            return "Audio device not available"
        }
    }
}

// MARK: - Data SubSequence Helper

private extension Data.SubSequence {
    /// Convert Data.SubSequence back to Data
    var asData: Data { Data(self) }
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

    // Device management
    var availableInputDevices: [AudioDevice] = [.previewBuiltIn, .previewBluetooth]
    var currentInputDevice: AudioDevice?
    var currentOutputDeviceName: String = "iPhone"

    func setupAudioSession(mode: AudioMode) throws {
        // Mock implementation
    }

    func switchAudioMode(_ mode: AudioMode) async throws {
        // Mock implementation
    }

    func requestMicrophonePermission() async -> Bool {
        return true
    }

    func prepareForRecording() async {
        isPlaying = false
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

    func speakText(_ text: String) async {
        // Mock: no-op, just record that it was called
    }

    func startStreamingRecording(onChunk: @escaping PCMChunkHandler) throws {
        if shouldFailRecording {
            throw AudioError.recordingFailed
        }
        isRecording = true
    }

    func stopStreamingRecording() {
        isRecording = false
    }

    func refreshAvailableDevices() {
        // Mock: devices don't change
    }

    func setPreferredInputDevice(_ device: AudioDevice?) throws {
        currentInputDevice = device
    }
}
#endif
