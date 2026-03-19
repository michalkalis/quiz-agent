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

        // Observe audio session interruptions (phone calls, Siri, other apps)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
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
            // Refresh available devices on main actor
            Task { @MainActor in
                self.refreshAvailableDevices()
            }
        case .oldDeviceUnavailable:
            // Bluetooth disconnected - gracefully fall back to built-in mic
            if Config.verboseLogging {
                print("🎧 Bluetooth device disconnected, using built-in microphone")
            }
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
                if Config.verboseLogging {
                    print("⚠️ Audio session interrupted")
                }
            case .ended:
                // Interruption ended - log but don't auto-resume (let user restart)
                if Config.verboseLogging {
                    print("✅ Audio session interruption ended")
                }
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
            if Config.verboseLogging {
                print("🎤 No input devices available")
            }
            return
        }

        availableInputDevices = inputs.map { AudioDevice.from(port: $0) }

        if Config.verboseLogging {
            print("🎤 Available input devices: \(availableInputDevices.map { $0.name })")
        }

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

        if Config.verboseLogging {
            let deviceName = currentInputDevice?.name ?? "Automatic"
            print("🎤 Current input device: \(deviceName)")
        }
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

            if Config.verboseLogging {
                print("🎤 Set preferred input: \(device.name)")
            }
        } else {
            // Clear preference - let iOS choose automatically
            try session.setPreferredInput(nil)
            currentInputDevice = nil

            if Config.verboseLogging {
                print("🎤 Cleared preferred input (automatic selection)")
            }
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

        if Config.verboseLogging {
            print("🎤 Audio system ready for recording")
        }
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
            if Config.verboseLogging {
                print("⚠️ Recording attempt \(attempt) failed, retrying...")
            }

            // Exponential backoff: 100ms, 200ms, 400ms
            let delayNs = UInt64(100_000_000 * (1 << (attempt - 1)))

            // Use RunLoop to wait without blocking @MainActor
            // We can't use Task.sleep in a non-async function
            let delaySeconds = Double(delayNs) / 1_000_000_000
            RunLoop.current.run(until: Date().addingTimeInterval(delaySeconds))
        }

        guard started else {
            audioRecorder = nil
            if Config.verboseLogging {
                print("❌ Recording failed to start after 3 attempts")
                // Log audio session state for diagnostics
                let session = AVAudioSession.sharedInstance()
                print("   Session category: \(session.category.rawValue)")
                print("   Session mode: \(session.mode.rawValue)")
                print("   Input available: \(session.isInputAvailable)")
            }
            throw AudioError.recordingFailed
        }

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

        // Validate minimum recording size
        // M4A header alone is ~28 bytes, a 1-second 16kHz mono recording is ~2KB minimum
        // Use 500 bytes as threshold to catch empty/corrupt recordings
        let minimumValidSize = 500
        guard data.count >= minimumValidSize else {
            if Config.verboseLogging {
                print("❌ Recording too short: \(data.count) bytes (minimum: \(minimumValidSize))")
            }
            try? FileManager.default.removeItem(at: url)
            audioRecorder = nil
            throw AudioError.recordingTooShort
        }

        // Clean up temporary file
        try? FileManager.default.removeItem(at: url)

        audioRecorder = nil

        if Config.verboseLogging {
            print("🎤 Recording data: \(data.count) bytes")
        }

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
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        )!

        // Get the hardware input format
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        if Config.verboseLogging {
            print("🎤 Streaming: hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch")
            print("🎤 Streaming: target format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount)ch")
        }

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

        if Config.verboseLogging {
            print("🎤 Streaming PCM recording started (16kHz, 16-bit, mono)")
        }
    }

    /// Stop streaming PCM recording
    func stopStreamingRecording() {
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.audioEngine = nil
        isRecording = false

        if Config.verboseLogging {
            print("🎤 Streaming PCM recording stopped")
        }
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

        if Config.verboseLogging {
            print("🔊 Playing audio: \(data.count) bytes from \(tempURL.lastPathComponent)")
        }

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
                nonisolated(unsafe) var stalledTimer: Timer?
                var didResume = false
                var hasStartedPlaying = false

                // Helper to ensure continuation resumes only once
                func resumeOnce(with result: Result<TimeInterval, Error>) {
                    guard !didResume else { return }
                    didResume = true

                    // Clean up observers and timer
                    if let observer = successObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    if let observer = failureObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    statusObserver?.invalidate()
                    stalledTimer?.invalidate()

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
                            if Config.verboseLogging {
                                print("⚠️ Audio playback stalling, reason: \(reason)")
                            }
                            // Check for format errors (critical for diagnosing codec issues)
                            if let error = player.currentItem?.error {
                                print("❌ Player item error: \(error.localizedDescription)")
                            }
                        case .playing:
                            hasStartedPlaying = true
                            // Cancel stall timer once playback starts
                            stalledTimer?.invalidate()
                            stalledTimer = nil
                            if Config.verboseLogging {
                                print("▶️ Audio playback resumed")
                            }
                        case .paused:
                            break
                        @unknown default:
                            break
                        }
                    }
                }

                // Playback timeout - fail if playback doesn't start within 5 seconds
                // This prevents infinite stalling on problematic files
                stalledTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard !hasStartedPlaying else { return }

                        if Config.verboseLogging {
                            print("⚠️ Playback timeout - audio failed to start within 5 seconds")
                        }

                        self?.isPlaying = false
                        self?.playbackState = .idle

                        resumeOnce(with: .failure(AudioError.playbackFailed))
                    }
                }

                // Observe when playback finishes successfully
                successObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.isPlaying = false
                        self?.playbackState = .idle

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
                        self?.isPlaying = false
                        self?.playbackState = .idle

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
        // Only cleanup if this is the active operation (prevents TOCTOU race)
        guard case .playing(let activeId) = playbackState, activeId == operationId else { return }

        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        playbackState = .idle

        if Config.verboseLogging {
            print("🔊 Cleaned up playback (id: \(operationId))")
        }
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
            if Config.verboseLogging {
                print("🔊 stopPlayback called but not playing")
            }
            return
        }

        // Pause and cleanup
        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        playbackState = .idle

        if Config.verboseLogging {
            print("🔊 Stopped playback")
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

        if Config.verboseLogging {
            print("🗣️ Speaking: \(text)")
        }

        // When VoiceOver is active, use accessibility announcement instead
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
            // Brief delay so the announcement has time to be spoken
            try? await Task.sleep(for: .milliseconds(500))

            if Config.verboseLogging {
                print("🗣️ Routed through VoiceOver announcement")
            }
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speechCompletion = continuation
            speechSynthesizer.delegate = self
            speechSynthesizer.speak(utterance)
        }

        if Config.verboseLogging {
            print("🗣️ Speech completed")
        }
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
