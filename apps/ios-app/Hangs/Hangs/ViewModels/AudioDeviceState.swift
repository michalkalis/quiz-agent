//
//  AudioDeviceState.swift
//  Hangs
//
//  Audio device management + the shared silence-detection choke points.
//  TTS/feedback playback lives in AudioDeviceState+Playback.swift.
//

import Combine
import Foundation
import os

/// The audio slice of the quiz flow as its own child object (#113 T2,
/// decision 1 — the de-facto 5th sub-object): input-device management
/// (AudioDevicePickerView), audio-mode switching, and the
/// `start`/`stopSilenceDetectionListening` choke points every consumer
/// (RecordingCoordinator/VoiceCommandCoordinator/+ScenePhase) funnels through — pulled out
/// before those consumers so later extracts inject them (decision 3).
///
/// The façade (QuizViewModel) owns this child, re-publishes its
/// `objectWillChange`, and re-exposes the slice via permanent forwarding
/// accessors (decision 2) — views never bind it directly. Cross-cluster
/// state (settings, isPlayingQuestionTTS, quizState, timers…) stays
/// façade-resident and is reached ONLY through the injected closures below
/// (decision 4 — a child never holds a back-pointer to the view model).
@MainActor
final class AudioDeviceState: ObservableObject {
    // MARK: - Published State

    /// Sheet presentation state for microphone picker
    @Published var showingMicrophonePicker = false

    // MARK: - Device State (computed over AudioService)

    /// Available input devices from AudioService
    var availableInputDevices: [AudioDevice] {
        audioService.availableInputDevices
    }

    /// Currently selected input device (nil = automatic)
    var selectedInputDevice: AudioDevice? {
        audioService.currentInputDevice
    }

    /// Current output device name for display
    var currentOutputDeviceName: String {
        audioService.currentOutputDeviceName
    }

    /// Display name for current input device
    var currentInputDeviceName: String {
        if let device = audioService.currentInputDevice {
            return device.name
        }
        return String(localized: "Automatic", comment: "Fallback name when no audio input device is selected (iOS picks the best mic)")
    }

    /// Current audio mode, derived from persisted settings
    var selectedAudioMode: AudioMode {
        AudioMode.forId(settings().audioMode) ?? AudioMode.default
    }

    // MARK: - Dependencies (façade-owned service instances, shared)

    let audioService: AudioServiceProtocol
    let networkService: NetworkServiceProtocol
    let silenceDetectionService: SilenceDetectionServiceProtocol
    /// Façade-owned task registry (decision 4 — a register/cancel handle).
    /// Shared so `resetState()`'s blanket `cancelAll()` still covers the
    /// barge-in and question-replay tasks exactly as before the extraction.
    let taskBag: TaskBag

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let setAudioMode: @MainActor (String) -> Void
    let setPreferredInputDeviceId: @MainActor (String?) -> Void
    let setMuted: @MainActor (Bool) -> Void
    let isAppForeground: @MainActor () -> Bool
    let isAskingQuestion: @MainActor () -> Bool
    let isRerecording: @MainActor () -> Bool
    let isPlayingQuestionTTS: @MainActor () -> Bool
    let setPlayingQuestionTTS: @MainActor (Bool) -> Void
    let currentQuestionAudioUrl: @MainActor () -> String?
    let setCurrentQuestionAudioUrl: @MainActor (String?) -> Void
    let setErrorMessage: @MainActor (String) -> Void
    /// Barge-in fan-out target — recording/timer orchestration stays façade-resident.
    let onBargeIn: @MainActor () async -> Void
    let startCommandConsumer: @MainActor () -> Void
    let stopCommandConsumer: @MainActor () -> Void
    let startThinkingTimeCountdown: @MainActor () -> Void
    let startAnswerTimer: @MainActor () -> Void

    // MARK: - Initialization

    init(
        audioService: AudioServiceProtocol,
        networkService: NetworkServiceProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol,
        taskBag: TaskBag,
        settings: @escaping @MainActor () -> QuizSettings,
        setAudioMode: @escaping @MainActor (String) -> Void,
        setPreferredInputDeviceId: @escaping @MainActor (String?) -> Void,
        setMuted: @escaping @MainActor (Bool) -> Void,
        isAppForeground: @escaping @MainActor () -> Bool,
        isAskingQuestion: @escaping @MainActor () -> Bool,
        isRerecording: @escaping @MainActor () -> Bool,
        isPlayingQuestionTTS: @escaping @MainActor () -> Bool,
        setPlayingQuestionTTS: @escaping @MainActor (Bool) -> Void,
        currentQuestionAudioUrl: @escaping @MainActor () -> String?,
        setCurrentQuestionAudioUrl: @escaping @MainActor (String?) -> Void,
        setErrorMessage: @escaping @MainActor (String) -> Void,
        onBargeIn: @escaping @MainActor () async -> Void,
        startCommandConsumer: @escaping @MainActor () -> Void,
        stopCommandConsumer: @escaping @MainActor () -> Void,
        startThinkingTimeCountdown: @escaping @MainActor () -> Void,
        startAnswerTimer: @escaping @MainActor () -> Void
    ) {
        self.audioService = audioService
        self.networkService = networkService
        self.silenceDetectionService = silenceDetectionService
        self.taskBag = taskBag
        self.settings = settings
        self.setAudioMode = setAudioMode
        self.setPreferredInputDeviceId = setPreferredInputDeviceId
        self.setMuted = setMuted
        self.isAppForeground = isAppForeground
        self.isAskingQuestion = isAskingQuestion
        self.isRerecording = isRerecording
        self.isPlayingQuestionTTS = isPlayingQuestionTTS
        self.setPlayingQuestionTTS = setPlayingQuestionTTS
        self.currentQuestionAudioUrl = currentQuestionAudioUrl
        self.setCurrentQuestionAudioUrl = setCurrentQuestionAudioUrl
        self.setErrorMessage = setErrorMessage
        self.onBargeIn = onBargeIn
        self.startCommandConsumer = startCommandConsumer
        self.stopCommandConsumer = stopCommandConsumer
        self.startThinkingTimeCountdown = startThinkingTimeCountdown
        self.startAnswerTimer = startAnswerTimer
    }

    /// T7 unified reset model: clears this child's own scoped device-UI state.
    /// Not yet wired — the façade's `resetState`/`transition` invokes this once
    /// T7 (S6b) wires the per-child `reset()` calls.
    func reset() {
        showingMicrophonePicker = false
    }

    // MARK: - Silence Detection Choke Points

    /// Start listening for silence events and barge-in during question playback.
    /// Safe to call multiple times (the service itself no-ops if already listening).
    func startSilenceDetectionListening() async {
        let service = silenceDetectionService

        // Backgrounded → never arm the input tap. This is the choke point for
        // every direct caller (e.g. the post-TTS tail of playQuestionAudio,
        // which fires after background TTS finishes); `.active` re-arms via
        // syncCommandListenerWindow (mic-in-background fix).
        guard isAppForeground() else { return }

        await service.startListening()

        // Barge-in: if the user starts speaking during TTS on an external audio
        // route, stop playback and kick off recording immediately.
        let task = Task { [weak self] in
            for await _ in service.bargeInEvents {
                guard let self, !Task.isCancelled else { break }
                await self.onBargeIn()
            }
        }
        taskBag.add(task, key: .bargeIn)

        // #77 (77.5): the SAME shared engine/transcriber now also feeds the
        // English command listener — arm its consumer whenever we listen.
        startCommandConsumer()
    }

    /// Stop silence-detection listening and tear down the barge-in subscription.
    func stopSilenceDetectionListening() {
        taskBag.cancel(.bargeIn)
        stopCommandConsumer()
        silenceDetectionService.stopListening()
    }

    // MARK: - Audio Device Management

    /// Toggle audio mode between Call Mode and Media Mode
    func toggleAudioMode() {
        Task {
            let newMode = selectedAudioMode.id == "call"
                ? (AudioMode.forId("media") ?? AudioMode.default)
                : (AudioMode.forId("call") ?? AudioMode.default)

            do {
                try await audioService.switchAudioMode(newMode)
                setAudioMode(newMode.id)

                Logger.audio.info("🔄 Switched to \(newMode.name, privacy: .public)")
            } catch {
                setErrorMessage(String(localized: "Failed to switch audio mode: \(error.localizedDescription)", comment: "Inline error when switching audio output mode fails; placeholder is the underlying error"))

                Logger.audio.error("❌ Error switching audio mode: \(error, privacy: .public)")
            }
        }
    }

    /// Refresh available audio input devices
    func refreshAudioDevices() {
        audioService.refreshAvailableDevices()

        // Try to restore saved preferred device
        if let savedId = settings().preferredInputDeviceId {
            // Check if saved device is still available
            if let device = availableInputDevices.first(where: { $0.id == savedId }) {
                do {
                    try audioService.setPreferredInputDevice(device)
                    Logger.audio.info("🎤 Restored preferred input device: \(device.name, privacy: .public)")
                } catch {
                    Logger.audio.warning("⚠️ Failed to restore preferred input device: \(error, privacy: .public)")
                }
            } else {
                // Saved device not available, keep preference for reconnection
                Logger.audio.info("🎤 Saved input device not available, using automatic")
            }
        }
    }

    /// Set preferred input device
    /// - Parameter device: Device to use, or nil for automatic selection
    func setPreferredInputDevice(_ device: AudioDevice?) {
        do {
            try audioService.setPreferredInputDevice(device)

            // Persist preference (auto-persisted via $settings sink)
            setPreferredInputDeviceId(device?.id)

            Logger.audio.info("🎤 Set preferred input device: \(device?.name ?? "Automatic", privacy: .public)")
        } catch {
            setErrorMessage(String(localized: "Failed to set audio device: \(error.localizedDescription)", comment: "Inline error when selecting a preferred input device fails; placeholder is the underlying error"))

            Logger.audio.error("❌ Error setting preferred input device: \(error, privacy: .public)")
        }
    }

    /// Fail-loud reporter for TTS audio failures: the quiz deliberately keeps
    /// going without audio, which makes regressions (e.g. the missing bearer on
    /// audio downloads → hard 401) silent. Mirror every real failure to Sentry
    /// so /check-crashes surfaces the next one. Cancellation (barge-in, stop)
    /// is expected flow, not an error.
    nonisolated static func reportAudioFailure(_ error: Error, kind: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        SentryLog.error("TTS audio failed", category: .audio, attributes: [
            "kind": kind,
            "error": String(describing: error),
        ])
    }
}
