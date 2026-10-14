//
//  AudioService+MicCapture.swift
//  Hangs
//
//  #204.4 echo-cancelled input and #204.5 front cardioid mic on the live
//  session (rules: MicCapturePolicy). Reconciled at the quiz session's setup
//  and at the no-engine choke point `restoreSessionAfterVoiceProcessing`,
//  which every listener stop/start passes — so a car that connects or drops
//  mid-quiz is picked up before the next mic engine starts. With both
//  switches off this is two property reads and never touches the session.
//

@preconcurrency import AVFoundation
import Foundation

/// What the mic-capture reconcile applied, so it neither repeats nor undoes
/// someone else's settings.
struct MicCaptureState: Equatable {
    /// The quiz session's audio mode id; nil outside a quiz (quiet Home
    /// listening), where nothing here applies.
    var quizModeId: String?
    /// The built-in mic port this service pinned as the preferred input.
    var pinnedBuiltInMicUID: String?
    /// The input the front/cardioid setting was last applied to.
    var frontMicAppliedInputUID: String?
}

extension AudioService {
    func reconcileMicCapture() {
        guard let quizModeId = micCapture.quizModeId,
              let audioMode = AudioMode.forId(quizModeId)
        else { return }
        reconcileEchoCancelledInput(audioMode)
        reconcileFrontCardioidMic(audioModeId: quizModeId)
    }

    /// Leaving the quiz session: drop the echo-cancelled preference and our
    /// mic pin so the quiet Home session runs exactly as before.
    func resetMicCapture() {
        let session = AVAudioSession.sharedInstance()
        micCapture.quizModeId = nil
        if session.prefersEchoCancelledInput {
            try? session.setPrefersEchoCancelledInput(false)
        }
        releaseBuiltInMicPin(session)
        micCapture.frontMicAppliedInputUID = nil
    }

    // MARK: - 204.4 Echo-cancelled input

    private func reconcileEchoCancelledInput(_ audioMode: AudioMode) {
        let session = AVAudioSession.sharedInstance()
        let wanted = MicCapturePolicy.wantsEchoCancelledInput(
            outputs: session.currentRoute.outputs.map(\.portType),
            enabled: VoiceExperimentStore.shared.isOn(.aec)
        )
        let desired = Self.quizSessionConfiguration(for: audioMode, echoCancelledInput: wanted)
        guard desired != appliedSessionConfiguration || session.prefersEchoCancelledInput != wanted else { return }

        var failure: String?
        do {
            // The preference is valid only in `.default` mode: switch the mode
            // first when turning it on, drop the preference first when off.
            if wanted {
                try session.setCategory(desired.category, mode: desired.mode, options: desired.options)
                try session.setPrefersEchoCancelledInput(true)
                try session.setActive(true)
            } else {
                try session.setPrefersEchoCancelledInput(false)
                try session.setCategory(desired.category, mode: desired.mode, options: desired.options)
            }
        } catch {
            failure = error.localizedDescription
        }
        appliedSessionConfiguration = desired
        // #204.9: the one moment the session is in the mode where iOS reports
        // the device capability (`aec_applicable` on every later capture).
        if wanted, failure == nil, session.mode == .default {
            VoiceExperimentStore.shared.noteEchoCancelledInputCapability(session.isEchoCancelledInputAvailable)
        }

        var attributes: [String: Any] = [
            "wanted": wanted,
            "available": session.isEchoCancelledInputAvailable,
            "prefers": session.prefersEchoCancelledInput,
            "enabled": session.isEchoCancelledInputEnabled,
            "outputPort": VoiceProcessingPolicy.currentOutputPort(),
            "sessionMode": VoiceProcessingPolicy.modeName(session.mode),
        ]
        if let failure { attributes["error"] = failure }
        SentryLog.info("echo cancelled input reconciled", category: .audio, attributes: attributes)
    }

    // MARK: - 204.5 Front built-in mic, cardioid

    private func reconcileFrontCardioidMic(audioModeId: String) {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first
        let wanted = MicCapturePolicy.wantsFrontCardioidMic(
            inputs: session.currentRoute.inputs.map(\.portType),
            enabled: VoiceExperimentStore.shared.isOn(.frontMic),
            voiceProcessing: VoiceProcessingPolicy.currentMode().armsVoiceProcessing
        )
        let foreignPreferredInput = session.preferredInput.map { $0.uid != micCapture.pinnedBuiltInMicUID } ?? false
        let pin = wanted && MicCapturePolicy.shouldPinBuiltInMic(
            audioModeId: audioModeId,
            hasForeignPreferredInput: foreignPreferredInput
        )
        if !pin { releaseBuiltInMicPin(session) }
        guard wanted, let input else {
            micCapture.frontMicAppliedInputUID = nil
            return
        }
        // Applied once per input; again only when a pin we want went away.
        let pinMissing = pin && micCapture.pinnedBuiltInMicUID == nil
        guard micCapture.frontMicAppliedInputUID != input.uid || pinMissing,
              let port = session.availableInputs?.first(where: { $0.portType == .builtInMic })
        else { return }

        var failures: [String] = []
        let front = port.dataSources?.first { $0.orientation == .front }
        let cardioid = front?.supportedPolarPatterns?.contains(.cardioid) ?? false
        if let front {
            if cardioid {
                do { try front.setPreferredPolarPattern(.cardioid) } catch { failures.append("polar: \(error.localizedDescription)") }
            }
            do { try port.setPreferredDataSource(front) } catch { failures.append("source: \(error.localizedDescription)") }
        }
        if pin {
            do {
                try session.setPreferredInput(port)
                micCapture.pinnedBuiltInMicUID = port.uid
            } catch {
                failures.append("input: \(error.localizedDescription)")
            }
        }
        micCapture.frontMicAppliedInputUID = input.uid

        let selected = session.currentRoute.inputs.first?.selectedDataSource
        var attributes: [String: Any] = [
            "frontAvailable": front != nil,
            "cardioidSupported": cardioid,
            "pinnedInput": micCapture.pinnedBuiltInMicUID != nil,
            "micDataSource": selected?.orientation?.rawValue ?? "none",
            "micPolarPattern": selected?.selectedPolarPattern?.rawValue ?? "none",
            "outputPort": VoiceProcessingPolicy.currentOutputPort(),
        ]
        if !failures.isEmpty { attributes["error"] = failures.joined(separator: "; ") }
        SentryLog.info("front cardioid mic applied", category: .audio, attributes: attributes)
    }

    /// Undo our built-in mic pin — only while it is still ours.
    private func releaseBuiltInMicPin(_ session: AVAudioSession) {
        guard let pinned = micCapture.pinnedBuiltInMicUID else { return }
        micCapture.pinnedBuiltInMicUID = nil
        guard session.preferredInput?.uid == pinned else { return }
        try? session.setPreferredInput(nil)
    }
}
