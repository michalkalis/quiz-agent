//
//  SilenceDetectionService+Telemetry.swift
//  Hangs
//
//  #189 (TF feedback 2026-09-29) — telemetry only, no behaviour: the two field
//  questions a deaf answer recording leaves open.
//
//  • "Deaf analyzer": the energy detector heard the driver for a second or
//    more, yet the on-device transcriber returned nothing for the whole
//    recording — while Scribe transcribed the same WAV (the re-records after
//    the retry prompt). Buffers in vs results out, per engine (`.voice`
//    events carry the engine tag). Suspected: the analyzer is dropped on stop
//    without being finalized (+Engine `stopListening`); not changed yet.
//  • P8: the OS stopping or reconfiguring the listener engine behind our back
//    (a route change, an interruption ending) while `audioEngine` still says
//    "listening" — logged with what the quiz was doing at that moment.
//
//  Split out of +Engine / +VAD, both at or past the ~300-line cap.
//

@preconcurrency import AVFoundation
import Foundation

extension SilenceDetectionService {
    /// The speech an answer recording must contain before zero transcriber
    /// results count as a deaf analyzer rather than a blip.
    private static let deafAnalyzerMinSpeechSecs: TimeInterval = 1.0

    // MARK: - Deaf analyzer

    /// Called as an answer recording's detection session closes.
    func logDeafAnalyzerIfNeeded(_ session: AnswerDetectionSession) {
        guard session.speechSecs >= Self.deafAnalyzerMinSpeechSecs,
              session.transcriberResults == 0 else { return }
        SentryLog.warn("deaf analyzer", category: .voice, attributes: [
            // Every tap buffer the level detector measured is also fed to
            // the analyzer (same tap, same buffer).
            "buffersIn": session.levelBuffers,
            "resultsOut": session.transcriberResults,
            "speechMs": Int((session.speechSecs * 1000).rounded()),
            "analyzerLive": analyzer != nil,
            "engineRunning": audioEngine?.isRunning ?? false,
        ])
    }

    // MARK: - P8: engine stopped or reconfigured by the OS

    /// Observe the listening window's engine for the system's configuration
    /// changes and the session's interruption endings. Replaces any previous
    /// window's observers; `removeEngineEventObservers` ends them.
    func observeEngineEvents(_ engine: AVAudioEngine) {
        removeEngineEventObservers()
        let center = NotificationCenter.default
        let configuration = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logEngineEvent("configurationChange", shouldResume: nil)
            }
        }
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { @Sendable [weak self] notification in
            // Decoded here: the notification's userInfo is not Sendable.
            guard let phase = AudioService.interruptionPhase(from: notification) else { return }
            Task { @MainActor [weak self] in
                guard case let .ended(shouldResume) = phase else { return }
                self?.logEngineEvent("interruptionEnded", shouldResume: shouldResume)
            }
        }
        engineEventObservers = [configuration, interruption]
    }

    func removeEngineEventObservers() {
        for observer in engineEventObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        engineEventObservers = []
    }

    private func logEngineEvent(_ event: String, shouldResume: Bool?) {
        var attributes: [String: Any] = [
            "event": event,
            "engineRunning": audioEngine?.isRunning ?? false,
            "answerRecording": answerSession != nil,
            // The quiz state as the black box last stamped it — this service
            // does not know the quiz, and every transition is recorded there.
            "quizState": QuizFlightRecorder.shared.entries.last?.state ?? "-",
            "inputPort": VoiceProcessingPolicy.currentInputPort(),
            "outputPort": VoiceProcessingPolicy.currentOutputPort(),
        ]
        if let shouldResume { attributes["shouldResume"] = shouldResume }
        SentryLog.warn("listener engine event", category: .audio, attributes: attributes)
    }
}
