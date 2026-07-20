//
//  AudioService.swift
//  Hangs
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

// @preconcurrency: AVAudioNodeTapBlock / AVAudioConverterInputBlock are not
// `@Sendable`-annotated in AVFoundation. Without this, Swift 6 strict concurrency
// infers @MainActor isolation for closures passed to `installTap`/`converter.convert`
// in a @MainActor class, and the runtime isolation check fires
// `dispatch_assert_queue(main)` when AVAudio invokes the tap on an audio thread →
// crash. See Sentry CARQUIZ-1 + Swift migration guide "Handle Unmarked Sendable Closures".
@preconcurrency import AVFoundation
import AVKit
import Combine
import Foundation
import os
import Sentry
import UIKit

/// Callback for streaming PCM audio chunks (raw 16kHz 16-bit mono PCM data)
typealias PCMChunkHandler = @Sendable (Data) -> Void

/// Protocol for audio operations
@MainActor
protocol AudioServiceProtocol: AnyObject, Sendable {
    var isRecording: Bool { get }
    var isPlaying: Bool { get }

    /// True while a streaming PCM engine (`AVAudioEngine`) is live. The feedback
    /// dictation sheet and the quiz share ONE engine, so this is the mutual
    /// single-engine guard (#64/#77/#109): the quiz refuses to start recording while
    /// the feedback sheet is dictating, and vice-versa.
    var isStreamingEngineActive: Bool { get }

    /// Invoked on the main actor when an audio-session interruption (`.began` —
    /// e.g. an incoming phone call) tears down an active *streaming* recording.
    /// The owner (QuizViewModel) uses it to leave `.recording` and reset streaming
    /// STT so no recording is stranded after the call (#67 Part A).
    var onInterruptionBegan: (@MainActor @Sendable () -> Void)? { get set }

    // Device management
    var availableInputDevices: [AudioDevice] { get }
    var currentInputDevice: AudioDevice? { get }
    var currentOutputDeviceName: String { get }

    func setupAudioSession(mode: AudioMode) throws
    func deactivateSession()
    func switchAudioMode(_ mode: AudioMode) async throws
    func requestMicrophonePermission() async -> Bool
    func prepareForRecording() async // Stops playback and waits for hardware settle
    func startRecording() throws
    func stopRecording() async throws -> Data
    func playOpusAudio(_ data: Data) async throws -> TimeInterval
    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval
    func stopPlayback() async // Now async for proper cleanup

    // Streaming PCM recording (for ElevenLabs STT)
    func startStreamingRecording(onChunk: @escaping PCMChunkHandler) async throws
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

    /// See `AudioServiceProtocol.onInterruptionBegan`. Set by the owner (QuizViewModel).
    var onInterruptionBegan: (@MainActor @Sendable () -> Void)?

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
            if case let .playing(id) = self { return id }
            return nil
        }
    }

    private var playbackState: PlaybackState = .idle

    // Stream continuation for active playback.
    // AsyncThrowingStream.Continuation.finish() is safe to call multiple times (subsequent calls are no-ops),
    // eliminating the double-resume crashes that CheckedContinuation caused.
    private var playbackStreamContinuation: AsyncThrowingStream<TimeInterval, Error>.Continuation?

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVPlayer?
    private var currentAudioMode: AudioMode = .default

    // Timestamps for Sentry breadcrumb durations (metadata only — no audio bytes).
    private var recordingStartedAt: Date?
    private var playbackStartedAt: Date?

    // Session-level NotificationCenter observer tokens.
    // NSObjectProtocol is not Sendable in Swift 6, and `deinit` runs nonisolated even
    // on a @MainActor class — boxed in OSAllocatedUnfairLock (same pattern as the
    // streaming PCM accumulator below) so deinit can read them without
    // `nonisolated(unsafe)`. Set once on @MainActor (setupAudioSession), read once
    // in deinit — always uncontended.
    private let routeChangeObserver = OSAllocatedUnfairLock<NSObjectProtocol?>(initialState: nil)
    private let interruptionObserver = OSAllocatedUnfairLock<NSObjectProtocol?>(initialState: nil)

    deinit {
        // Clean up observers
        if let observer = routeChangeObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = interruptionObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Audio Session Setup

    /// The `AVAudioSession.CategoryOptions` for a given audio mode.
    ///
    /// Pure (no session activation, no I/O) so the option set is unit-testable on the
    /// simulator without touching a live `AVAudioSession` — RS-18 / #59.3. The literal
    /// "real instance + setupAudioSession" guard was reworked to this seam because
    /// `setupAudioSession` calls `setActive(true)`, which is the suspected cause of the
    /// HangsTests hang on the sim.
    ///
    /// #104 founder decision (car Bluetooth audio bugs) — the two modes now carry
    /// deliberately different Bluetooth contracts:
    /// - **Media Mode**: A2DP output only, no `.allowBluetoothHFP`. The car never
    ///   negotiates a Bluetooth SCO link, so it never shows a "phone call" UI. Input
    ///   falls back to the iPhone's built-in mic (A2DP is output-only) — users who
    ///   want the Bluetooth/AirPods mic should switch to Call Mode instead. This
    ///   intentionally supersedes the #59.3 blanket-HFP fix that put HFP in every
    ///   mode.
    /// - **Call Mode**: `.allowBluetoothHFP` + `.allowBluetoothA2DP`. The car/BT mic
    ///   is reachable via HFP and the car shows a "phone call" UI, which the user
    ///   accepts by design.
    nonisolated static func categoryOptions(for mode: AudioMode) -> AVAudioSession.CategoryOptions {
        // Duck background audio (Spotify/podcasts) while the quiz is active.
        // .duckOthers lowers music; .interruptSpokenAudioAndMixWithOthers pauses
        // podcasts (two simultaneous voices = unintelligible). Apple HIG recommends
        // this combination for apps with spoken-audio prompts.
        let duckingOptions: AVAudioSession.CategoryOptions = [
            .duckOthers,
            .interruptSpokenAudioAndMixWithOthers,
        ]

        var options: AVAudioSession.CategoryOptions
        switch mode.id {
        case "media":
            // Media Mode: A2DP output only. No HFP — the car never opens a Bluetooth
            // SCO link, so no "phone call" UI. Input is the iPhone's built-in mic;
            // AirPods-mic users should use Call Mode instead (#104 founder decision).
            options = [.defaultToSpeaker, .allowBluetoothA2DP]
        case "call":
            // Call Mode: HFP + A2DP (Bluetooth mic enabled; shows "phone call" in car,
            // accepted by design).
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        default:
            // Fallback to call mode.
            options = [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        }
        options.formUnion(duckingOptions)
        return options
    }

    func setupAudioSession(mode: AudioMode) throws {
        let session = AVAudioSession.sharedInstance()

        // Store current mode
        currentAudioMode = mode

        // Configure audio session options based on selected mode (pure helper above).
        let options = Self.categoryOptions(for: mode)

        switch mode.id {
        case "media":
            Logger.audio.info("🎤 Audio session: Media Mode (A2DP output, built-in mic, no HFP)")
        case "call":
            Logger.audio.info("🎤 Audio session: Call Mode (HFP + A2DP)")
        default:
            Logger.audio.warning("⚠️ Unknown audio mode '\(mode.id, privacy: .public)', defaulting to Call Mode")
        }

        // Configure for background playback and recording
        // .defaultToSpeaker forces output to speaker instead of receiver (louder audio)
        // .allowBluetoothHFP enables Bluetooth microphone input (Hands-Free Profile)
        // .allowBluetoothA2DP enables high-quality Bluetooth playback (A2DP)
        // Ducking options are applied above — replaces previous .mixWithOthers
        // because mixing at equal volume made TTS inaudible over music.
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: options
        )

        try session.setActive(true)

        // Observe audio route changes (Bluetooth connect/disconnect).
        // setupAudioSession is called repeatedly (switchAudioMode, the
        // withPlaybackCategory recovery path) — remove the previous observer first
        // or duplicate registrations pile up and every handler fires N times.
        if let existingRouteObserver = routeChangeObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(existingRouteObserver)
        }
        let routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Already on main queue, can call directly
            self?.handleRouteChange(notification)
        }
        routeChangeObserver.withLock { $0 = routeObserver }

        // Observe audio session interruptions (phone calls, Siri, other apps) —
        // same duplicate-registration guard as the route observer above.
        if let existingInterruptionObserver = interruptionObserver.withLock({ $0 }) {
            NotificationCenter.default.removeObserver(existingInterruptionObserver)
        }
        let interruptObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        interruptionObserver.withLock { $0 = interruptObserver }

        Logger.audio.info("🎤 Audio session configured for background playback and recording")
    }

    /// Deactivate the audio session and notify other apps so background music
    /// (Spotify, podcasts) can resume at full volume after the quiz ends.
    /// Safe to call when already inactive — failures are logged, never thrown.
    func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            Logger.audio.info("🔇 Audio session deactivated (notified others)")
        } catch {
            Logger.audio.error("❌ Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
            let crumb = Breadcrumb(level: .error, category: "audio.session_deactivate")
            crumb.message = "setActive(false) failed"
            crumb.data = ["error": error.localizedDescription]
            SentryBreadcrumb.add(crumb)
        }
    }

    /// Whether `withPlaybackCategory` should swap to `.playback` for a TTS utterance.
    ///
    /// When `.allowBluetoothHFP` is in the option set (Call Mode), the session must
    /// HOLD `.playAndRecord` for the whole quiz so the SCO link stays up stably — the
    /// car shows one steady call with no flapping, and TTS plays over that call link.
    /// Swapping categories per-utterance would open/close the Bluetooth SCO link on
    /// every question and make the car call UI flap on/off.
    ///
    /// When HFP is absent (Media Mode), the swap cannot touch the Bluetooth profile —
    /// A2DP stays the output in both `.playAndRecord` and `.playback` — so swapping
    /// is safe and buys back the ~6dB `.playAndRecord` output attenuation (commit
    /// 331c47c).
    nonisolated static func shouldSwapCategoryForTTS(options: AVAudioSession.CategoryOptions) -> Bool {
        !options.contains(.allowBluetoothHFP)
    }

    /// Run a block with the session temporarily switched to `.playback + .spokenAudio`
    /// (with ducking) and restore the previous category on exit — Media Mode only
    /// (see `shouldSwapCategoryForTTS`).
    ///
    /// `.playAndRecord` attenuates output by ~6dB even when no recording is active,
    /// which made TTS inaudible over music. Switching to `.playback` for the
    /// duration of TTS gives full output volume. The restore in `defer` runs on
    /// every exit path (return, throw, cancellation), so the recording phase is
    /// unaffected.
    ///
    /// In Call Mode (HFP present) the swap is skipped entirely — swapping category
    /// per-utterance would open/close the Bluetooth SCO link on every question and
    /// make the car call UI flap; the session instead holds `.playAndRecord` for the
    /// whole quiz and TTS plays over the stable call link.
    ///
    /// Early-returns when the session is already in `.playback` (e.g. nested calls
    /// or a unit-test environment that pre-set the category).
    private func withPlaybackCategory<T>(_ body: () async throws -> T) async throws -> T {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playback {
            return try await body()
        }

        if !Self.shouldSwapCategoryForTTS(options: session.categoryOptions) {
            // Call Mode: no category change, so no SCO renegotiation. Still guards
            // the same post-mic-engine AVPlayer stall the swap path guards below —
            // without reactivating, AVPlayer can stall in .waitingToPlayAtSpecifiedRate
            // and the 5s stall timer fires AudioError.playbackFailed.
            try session.setActive(true)
            return try await body()
        }

        let previousCategory = session.category
        let previousMode = session.mode
        let previousOptions = session.categoryOptions

        let ttsOptions: AVAudioSession.CategoryOptions = [
            .duckOthers,
            .interruptSpokenAudioAndMixWithOthers,
        ]

        try session.setCategory(.playback, mode: .spokenAudio, options: ttsOptions)
        // A category change does not reactivate the session. After the mic engine
        // has run, AVPlayer otherwise stalls in .waitingToPlayAtSpecifiedRate and the
        // 5s stall timer fires AudioError.playbackFailed → TTS never speaks. Mirror
        // the setActive(true) that setupAudioSession does after its setCategory.
        try session.setActive(true)

        let switchCrumb = Breadcrumb(level: .info, category: "audio.category_switch")
        switchCrumb.message = "Switched to .playback for TTS"
        switchCrumb.data = [
            "from": previousCategory.rawValue,
            "to": AVAudioSession.Category.playback.rawValue,
        ]
        SentryBreadcrumb.add(switchCrumb)

        defer {
            // Restore must surface errors loudly — if it fails, the next recording
            // session breaks silently. No `try?` swallow.
            do {
                try session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
                // Reactivate after restoring — a name-only restore leaves the session
                // wired for .playback (no input), which silently breaks the next recording.
                try session.setActive(true)
                Logger.audio.debug("🔊 Restored audio category: \(previousCategory.rawValue, privacy: .public)")
            } catch {
                Logger.audio.error("❌ Failed to restore audio category \(previousCategory.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                let crumb = Breadcrumb(level: .error, category: "audio.category_restore")
                crumb.message = "setCategory restore failed"
                crumb.data = [
                    "target": previousCategory.rawValue,
                    "error": error.localizedDescription,
                ]
                SentryBreadcrumb.add(crumb)
                // Recovery: a failed restore can strand the session in .playback (no mic).
                // Re-establish a known-good record-capable session for the current mode.
                do {
                    try setupAudioSession(mode: currentAudioMode)
                    Logger.audio.info("🔊 Recovered audio session via setupAudioSession after failed restore")
                } catch {
                    Logger.audio.error("❌ Audio session recovery failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return try await body()
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
            await stopPlayback() // Now async
        }

        // Deactivate current session
        try AVAudioSession.sharedInstance().setActive(false)

        // Reconfigure with new mode
        try setupAudioSession(mode: mode)

        Logger.audio.info("🔄 Audio mode switched to: \(mode.name, privacy: .public)")
    }

    private nonisolated func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else {
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

    /// What an interruption's `.began` phase must tear down. Pure + static so the
    /// routing decision is unit-testable without real audio hardware (the streaming
    /// engine is never live on the Simulator). #67 Part A: the streaming PCM path
    /// must route to `stopStreamingRecording()`, NOT the batch `stopRecording()`,
    /// which never tears down the AVAudioEngine — the stranded-recording-after-a-call bug.
    enum InterruptionTeardown: Equatable {
        case streaming
        case batch
        case none
    }

    static func interruptionTeardown(isStreaming: Bool, isRecording: Bool) -> InterruptionTeardown {
        if isStreaming { return .streaming }
        if isRecording { return .batch }
        return .none
    }

    /// Whether an interruption's `.ended` phase should reactivate the audio session.
    /// Pure so the decision is unit-testable without a live `AVAudioSession` (mirrors
    /// `interruptionTeardown` above). #100.3: previously `.ended` only logged and never
    /// reactivated, so a mic tap on the same question afterward ran against a session
    /// iOS had deactivated and failed with "Recording failed" — repeatable until a TTS
    /// replay happened to reactivate the session.
    nonisolated static func shouldResumeSession(options: AVAudioSession.InterruptionOptions) -> Bool {
        options.contains(.shouldResume)
    }

    /// Handle audio session interruptions (phone calls, Siri, other apps)
    private nonisolated func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }
        // Extracted here (not inside the Task) because `userInfo` ([AnyHashable: Any])
        // is not Sendable and can't be captured across the actor-isolation boundary.
        let optionsRawValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0

        Task { @MainActor in
            switch type {
            case .began:
                // Interruption started - stop any active operations to prevent corruption.
                // #67 Part A: route to the correct teardown. The streaming PCM path holds an
                // AVAudioEngine that the batch stopRecording() never stops — misrouting it
                // strands the recording after the call. Also notify the owner so the
                // view model leaves .recording and resets streaming STT.
                switch AudioService.interruptionTeardown(
                    isStreaming: self.audioEngine != nil,
                    isRecording: self.isRecording
                ) {
                case .streaming:
                    self.stopStreamingRecording()
                    self.onInterruptionBegan?()
                case .batch:
                    _ = try? await self.stopRecording()
                case .none:
                    break
                }
                if self.isPlaying {
                    await self.stopPlayback()
                }
                Logger.audio.warning("⚠️ Audio session interrupted")
            case .ended:
                // Interruption ended (e.g. a phone call hung up). If the system says
                // it's safe to resume, reactivate the session now — otherwise a mic
                // tap on the same question runs against a session iOS deactivated and
                // fails with "Recording failed" until a TTS replay reactivates it (#100.3).
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
                if AudioService.shouldResumeSession(options: options) {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        Logger.audio.info("✅ Audio session interruption ended, reactivated (.shouldResume)")
                    } catch {
                        Logger.audio.error("❌ Failed to reactivate audio session after interruption: \(error.localizedDescription, privacy: .public)")
                        let crumb = Breadcrumb(level: .error, category: "audio.session_reactivate")
                        crumb.message = "setActive(true) failed after interruption ended"
                        crumb.data = ["error": error.localizedDescription]
                        SentryBreadcrumb.add(crumb)
                    }
                } else {
                    Logger.audio.info("✅ Audio session interruption ended (no resume option)")
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
            Logger.audio.debug("🎤 No input devices available")
            return
        }

        availableInputDevices = inputs.map { AudioDevice.from(port: $0) }

        // Local var (not `self.availableInputDevices` inline) — the os.Logger string
        // interpolation builder is an autoclosure context, where SwiftFormat's
        // redundantSelf rule strips the required explicit `self.` on every reformat.
        let deviceNames = availableInputDevices.map { $0.name }
        Logger.audio.debug("🎤 Available input devices: \(deviceNames, privacy: .public)")

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

        // Local var — see the deviceNames comment above (autoclosure + redundantSelf).
        let deviceName = currentInputDevice?.name ?? "Automatic"
        Logger.audio.debug("🎤 Current input device: \(deviceName, privacy: .public)")
    }

    /// Set preferred input device
    /// - Parameter device: Device to use, or nil for automatic selection
    func setPreferredInputDevice(_ device: AudioDevice?) throws {
        let session = AVAudioSession.sharedInstance()

        if let device = device, !device.isAutomatic {
            // Find matching AVAudioSessionPortDescription
            guard let inputs = session.availableInputs,
                  let port = inputs.first(where: { $0.uid == device.id })
            else {
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
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

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
            AVSampleRateKey: 16000.0, // Voice-optimized (was 44100)
            AVNumberOfChannelsKey: 1, // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 32000, // 32kbps sufficient for 16kHz voice
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
        recordingStartedAt = Date()

        Logger.audio.info("🎤 Started recording to: \(fileName, privacy: .public)")

        let crumb = Breadcrumb(level: .info, category: "audio.record_start")
        crumb.message = "Batch M4A recording started"
        crumb.data = ["format": "m4a", "sample_rate": 16000]
        SentryBreadcrumb.add(crumb)
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

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let crumb = Breadcrumb(level: .info, category: "audio.record_stop")
        crumb.message = "Batch M4A recording stopped"
        crumb.data = [
            "duration_ms": Int(duration * 1000),
            "bytes": data.count,
        ]
        SentryBreadcrumb.add(crumb)

        return data
    }

    // MARK: - Streaming PCM Recording (AVAudioEngine)

    private var audioEngine: AVAudioEngine?

    /// See `AudioServiceProtocol.isStreamingEngineActive` — the shared-engine
    /// liveness signal that backs the mutual single-engine guard (#109).
    var isStreamingEngineActive: Bool { audioEngine != nil }

    /// Monotonic token invalidating in-flight streaming starts. `startStreamingRecording`
    /// suspends for up to ~2s in the settle wait with `audioEngine` still nil; a
    /// teardown arriving in that window (scene-phase background, stop command) would
    /// otherwise be a no-op and the engine would start *after* it, leaving the mic
    /// hot. `stopStreamingRecording` bumps this even when no engine is live, and the
    /// start bails after the wait when the generation moved.
    private(set) var streamingGeneration = 0

    /// Pure hardware-format validity check. The format can read 0 Hz / 0 ch
    /// transiently right after an audio route change (Bluetooth connect/disconnect,
    /// a category switch) while the route settles. Unit-testable without live
    /// hardware.
    nonisolated static func isValidHardwareFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    /// Outcome of `waitForValidHardwareFormat`: how many reads it took to settle, or
    /// that it never settled within the timeout.
    enum HardwareFormatWaitOutcome: Equatable {
        case success(attempts: Int)
        case timeout
    }

    /// Bounded settle-wait: calls `readFormat` immediately, then again roughly every
    /// `intervalMs` until `isValidHardwareFormat` passes or `timeoutMs` total has
    /// elapsed. Extracted from `startStreamingRecording` so the retry policy is
    /// unit-testable with a scripted reader — no live `AVAudioEngine`/`AVAudioSession`
    /// required.
    nonisolated static func waitForValidHardwareFormat(
        intervalMs: UInt64 = 150,
        timeoutMs: UInt64 = 2000,
        readFormat: () -> (sampleRate: Double, channelCount: AVAudioChannelCount),
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0 * 1_000_000) }
    ) async throws -> HardwareFormatWaitOutcome {
        var attempts = 0
        var elapsedMs: UInt64 = 0
        while true {
            attempts += 1
            let format = readFormat()
            if isValidHardwareFormat(sampleRate: format.sampleRate, channelCount: format.channelCount) {
                return .success(attempts: attempts)
            }
            elapsedMs += intervalMs
            guard elapsedMs <= timeoutMs else {
                return .timeout
            }
            try await sleep(intervalMs)
        }
    }

    /// Start streaming PCM recording via AVAudioEngine.
    /// Calls `onChunk` with raw 16kHz 16-bit mono PCM data at regular intervals.
    /// Use `stopStreamingRecording()` to stop.
    ///
    /// The hardware input format can read 0 Hz / 0 ch transiently while an audio
    /// route settles (e.g. right after a Bluetooth connect/disconnect or a category
    /// switch) — `waitForValidHardwareFormat` retries for up to ~2s before giving up.
    func startStreamingRecording(onChunk: @escaping PCMChunkHandler) async throws {
        // Single-engine invariant (#64/#77/#109): never overwrite a live engine. A
        // second concurrent start — e.g. a quiz auto-record timer firing while the
        // feedback sheet already holds the mic — must fail loud here rather than
        // silently strand the first engine by overwriting `audioEngine` below (the
        // two-engine crash class). The callers' mutual guards should prevent ever
        // reaching this, but this is the structural backstop.
        guard audioEngine == nil else {
            Logger.audio.error("🎤 Streaming start refused — an audio engine is already active")
            throw AudioError.recordingFailed
        }

        // Target format: 16kHz, 16-bit, mono (matching ElevenLabs pcm_16000)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioError.recordingFailed
        }

        // Capture the generation before suspending; a stopStreamingRecording() during
        // the settle wait bumps it, and the check below aborts the start.
        let startedGeneration = streamingGeneration

        // AVAudioEngine caches the input format from when it was instantiated, so a
        // fresh read requires a fresh engine — each probe below creates and discards
        // its own engine rather than re-querying a single inputNode.
        let waitStart = Date()
        let outcome = try await Self.waitForValidHardwareFormat(
            readFormat: {
                let probeFormat = AVAudioEngine().inputNode.outputFormat(forBus: 0)
                return (probeFormat.sampleRate, probeFormat.channelCount)
            }
        )

        switch outcome {
        case let .success(attempts) where attempts > 1:
            let elapsedMs = Int(Date().timeIntervalSince(waitStart) * 1000)
            Logger.audio.info("🎤 Streaming: hardware format settled after \(attempts, privacy: .public) attempts (\(elapsedMs, privacy: .public)ms)")
            let settleCrumb = Breadcrumb(level: .info, category: "audio.record_start")
            settleCrumb.message = "input format settled after \(elapsedMs)ms"
            settleCrumb.data = ["attempts": attempts, "elapsed_ms": elapsedMs]
            SentryBreadcrumb.add(settleCrumb)
        case .success:
            break
        case .timeout:
            let probeFormat = AVAudioEngine().inputNode.outputFormat(forBus: 0)
            Logger.audio.error("🎤 Streaming: invalid hardware format: \(probeFormat.sampleRate, privacy: .public)Hz, \(probeFormat.channelCount, privacy: .public)ch")
            throw AudioError.recordingFailed
        }

        // A teardown raced the settle wait — recording must stay stopped, and the
        // caller must NOT fall back to batch recording (see the CancellationError
        // handling in QuizViewModel+Recording).
        guard startedGeneration == streamingGeneration else {
            Logger.audio.info("🎤 Streaming: start cancelled by teardown during settle wait")
            throw CancellationError()
        }

        // Real engine used for the recording itself — created fresh (mirrors the
        // probes above) after the format has settled.
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard Self.isValidHardwareFormat(sampleRate: hardwareFormat.sampleRate, channelCount: hardwareFormat.channelCount) else {
            // Rare race: the route flipped invalid again right after the wait
            // succeeded. Fail loud rather than start a converter on a bad format.
            Logger.audio.error("🎤 Streaming: hardware format went invalid again after settling: \(hardwareFormat.sampleRate, privacy: .public)Hz, \(hardwareFormat.channelCount, privacy: .public)ch")
            throw AudioError.recordingFailed
        }

        Logger.audio.debug("🎤 Streaming: hardware format: \(hardwareFormat.sampleRate, privacy: .public)Hz, \(hardwareFormat.channelCount, privacy: .public)ch")
        Logger.audio.debug("🎤 Streaming: target format: \(targetFormat.sampleRate, privacy: .public)Hz, \(targetFormat.channelCount, privacy: .public)ch")

        // Create a converter from hardware format to target format
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioError.recordingFailed
        }

        // Buffer for accumulating PCM data before sending.
        // OSAllocatedUnfairLock<Data> is Sendable and eliminates nonisolated(unsafe).
        // The tap callback IS serial (AVAudioEngine guarantee), so the lock is always
        // uncontended — overhead is negligible (a single atomic compare-and-swap).
        let chunkInterval = Config.sttStreamingChunkIntervalMs
        let samplesPerChunk = Int(16000.0 * Double(chunkInterval) / 1000.0) // e.g., 4000 samples for 250ms
        let accumulator = OSAllocatedUnfairLock(initialState: Data())

        // Install a tap on the input node.
        // `@Sendable` marks the closure non-isolated — critical, otherwise Swift 6
        // infers @MainActor from the enclosing class and the runtime isolation check
        // crashes when AVAudio invokes the tap on its audio thread (Sentry CARQUIZ-1).
        let bufferSize = AVAudioFrameCount(hardwareFormat.sampleRate * Double(chunkInterval) / 1000.0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { @Sendable buffer, _ in
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

            // Extract raw PCM bytes and accumulate
            guard let channelData = convertedBuffer.int16ChannelData else { return }
            let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
            let newData = Data(bytes: channelData[0], count: byteCount)

            let targetBytes = samplesPerChunk * MemoryLayout<Int16>.size
            accumulator.withLock { data in
                data.append(newData)
                if data.count >= targetBytes {
                    let chunk = Data(data.prefix(targetBytes))
                    data = data.dropFirst(targetBytes).asData
                    onChunk(chunk)
                }
            }
        }

        engine.prepare()
        try engine.start()

        audioEngine = engine
        isRecording = true
        recordingStartedAt = Date()

        Logger.audio.info("🎤 Streaming PCM recording started (16kHz, 16-bit, mono)")

        let crumb = Breadcrumb(level: .info, category: "audio.record_start")
        crumb.message = "Streaming PCM recording started"
        crumb.data = ["format": "pcm_s16le", "sample_rate": 16000]
        SentryBreadcrumb.add(crumb)
    }

    /// Stop streaming PCM recording. Also invalidates any in-flight
    /// `startStreamingRecording` that is still inside its settle wait — the bump
    /// must happen even when no engine is live yet, or that start would come up
    /// after this teardown and leave the mic recording.
    func stopStreamingRecording() {
        streamingGeneration += 1
        guard let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isRecording = false

        Logger.audio.info("🎤 Streaming PCM recording stopped")

        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let crumb = Breadcrumb(level: .info, category: "audio.record_stop")
        crumb.message = "Streaming PCM recording stopped"
        crumb.data = ["duration_ms": Int(duration * 1000)]
        SentryBreadcrumb.add(crumb)
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

    /// Performs the actual audio playback with proper cancellation support.
    ///
    /// Uses AsyncThrowingStream instead of CheckedContinuation. Key safety property:
    /// stream.continuation.finish() is idempotent — calling it from multiple sources
    /// (completion notification, failure notification, stall timer, stopPlayback) is safe.
    /// CheckedContinuation.resume() called twice would crash; this cannot.
    private func performPlayback(data: Data, operationId: UUID) async throws -> TimeInterval {
        // Switch to .playback for the duration of TTS so we don't pay the ~6dB
        // attenuation .playAndRecord applies. The defer in withPlaybackCategory
        // restores the previous category on every exit path.
        return try await withPlaybackCategory {
            try await self.performPlaybackBody(data: data, operationId: operationId)
        }
    }

    private func performPlaybackBody(data: Data, operationId: UUID) async throws -> TimeInterval {
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

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Use AVPlayer for codec support (MP3, AAC, etc.)
        let playerItem = AVPlayerItem(url: tempURL)

        // Configure buffering for smoother playback
        playerItem.preferredForwardBufferDuration = 5.0 // Buffer 5 seconds ahead

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

        let (stream, continuation) = AsyncThrowingStream<TimeInterval, Error>.makeStream()
        playbackStreamContinuation = continuation

        // KVO: monitor playback status for stalling diagnostics (logging only)
        let statusObserver = audioPlayer?.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            let stallReason = player.reasonForWaitingToPlay?.rawValue
            let itemError = player.currentItem?.error
            Task { @MainActor in
                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    Logger.audio.warning("⚠️ Audio playback stalling: \(stallReason ?? "unknown", privacy: .public)")
                    if let itemError {
                        Logger.audio.error("❌ Player item error: \(itemError.localizedDescription, privacy: .public)")
                    }
                case .playing:
                    Logger.audio.debug("▶️ Audio playback started")
                default:
                    break
                }
            }
        }

        // Stall timeout: fail only if playback never reached .playing within 5 seconds.
        // Without the status check this timer fires unconditionally and aborts any
        // TTS longer than 5s — which caused the thinking-timer to start mid-read
        // while audio kept playing in the background.
        // If playback already completed or was stopped, continuation.finish(throwing:)
        // is a no-op — safe.
        let stalledTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.audioPlayer?.timeControlStatus != .playing else { return }
                Logger.audio.warning("⚠️ Playback timeout - audio failed to start within 5 seconds")
                continuation.finish(throwing: AudioError.playbackFailed)
            }
        }

        // Completion notification: yield duration and close stream
        let successObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.playbackState = .idle
                Logger.audio.info("🔊 Playback completed")
                self?.emitPlaybackEndBreadcrumb(reason: "completed")
                continuation.yield(durationSeconds)
                continuation.finish()
            }
        }

        // Failure notification: close stream with error
        let failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.playbackState = .idle
                Logger.audio.error("❌ Playback failed")
                continuation.finish(throwing: error ?? AudioError.playbackFailed)
            }
        }

        // Clean up all local observers/timer when this scope exits — whether via return,
        // throw, or Task cancellation. The continuation is already cleared by stopPlayback()
        // or cleanupPlayback() before this defer runs.
        defer {
            NotificationCenter.default.removeObserver(successObserver)
            NotificationCenter.default.removeObserver(failureObserver)
            statusObserver?.invalidate()
            stalledTimer.invalidate()
            playbackStreamContinuation = nil
        }

        audioPlayer?.play()
        playbackStartedAt = Date()
        Logger.audio.debug("🔊 Started AVPlayer playback")

        let startCrumb = Breadcrumb(level: .info, category: "audio.playback_start")
        startCrumb.message = "AVPlayer playback started"
        startCrumb.data = [
            "bytes": data.count,
            "duration_s": Int(durationSeconds),
        ]
        SentryBreadcrumb.add(startCrumb)

        return try await withTaskCancellationHandler {
            // Await first event from the stream:
            // - .yield(duration) + .finish() → return duration (success)
            // - .finish(throwing: error) → throw error (failure or cancellation)
            // - stream finished without yield → throw CancellationError (stopped)
            for try await playedDuration in stream {
                return playedDuration
            }
            throw CancellationError()
        } onCancel: {
            Task { @MainActor [weak self] in
                await self?.cleanupPlayback(operationId: operationId)
            }
        }
    }

    /// Cleans up playback resources for a specific operation (called from Task cancellation handler).
    /// Finishing the stream causes the awaiting `for try await` to exit; subsequent finish() calls are no-ops.
    private func cleanupPlayback(operationId: UUID) async {
        guard case let .playing(activeId) = playbackState, activeId == operationId else { return }

        playbackStreamContinuation?.finish(throwing: CancellationError())
        playbackStreamContinuation = nil

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

    /// Stops playback and signals the stream to exit.
    /// stream.continuation.finish(throwing:) is idempotent — no crash if called multiple times.
    func stopPlayback() async {
        guard case .playing = playbackState else {
            Logger.audio.debug("🔊 stopPlayback called but not playing")
            return
        }

        // Signal the stream: causes `for try await` in performPlayback to throw CancellationError.
        // The defer in performPlayback will then remove observers and clean up local state.
        playbackStreamContinuation?.finish(throwing: CancellationError())
        playbackStreamContinuation = nil

        audioPlayer?.pause()
        audioPlayer = nil
        isPlaying = false
        playbackState = .idle

        Logger.audio.info("🔊 Stopped playback")
        emitPlaybackEndBreadcrumb(reason: "stopped")
    }

    /// Emit a playback_end breadcrumb with duration since playbackStartedAt.
    /// No-op if no start timestamp (e.g. stopPlayback called after natural end).
    private func emitPlaybackEndBreadcrumb(reason: String) {
        guard let start = playbackStartedAt else { return }
        let duration = Date().timeIntervalSince(start)
        playbackStartedAt = nil
        let crumb = Breadcrumb(level: .info, category: "audio.playback_end")
        crumb.message = "AVPlayer playback \(reason)"
        crumb.data = [
            "duration_ms": Int(duration * 1000),
            "reason": reason,
        ]
        SentryBreadcrumb.add(crumb)
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_: AVAudioRecorder, successfully _: Bool) {
        Task { @MainActor in
            isRecording = false
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_: AVAudioRecorder, error: Error?) {
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
