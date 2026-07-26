//
//  SilenceDetectionService+Assets.swift
//  Hangs
//
//  Launch-time readiness for the command recognizer: the #105 speech-recognition
//  authorization flow and the #77/#120 on-device model-asset preparation for the
//  selected engine + locale. Split out of SilenceDetectionService.swift (past
//  the ~300-line cap after #120's engine-seam additions); the VAD state machine
//  and stream plumbing stay there, the analyzer lifecycle is in +Engine.swift.
//

import Foundation

// @preconcurrency: the legacy SFSpeechRecognizer.requestAuthorization completion
// fires on a TCC background queue; without this the inferred @MainActor
// isolation check traps at launch (see SilenceDetectionService.swift).
@preconcurrency import Speech

extension SilenceDetectionService {
    // MARK: - Authorization (#105)

    /// Requests the OS speech-recognition permission and then, if granted,
    /// proceeds into the existing asset-prepare flow. #105: the app declared
    /// `NSSpeechRecognitionUsageDescription` but never actually called
    /// `SFSpeechRecognizer.requestAuthorization` anywhere — a denied/never-asked
    /// permission silently strands the command listener with `.unknown`
    /// availability forever. Called once from AppState at launch, exactly like
    /// `prepareAssets()` used to be called alone; safe to re-enter (guarded by
    /// the same `.unknown` check inside `prepareAssets()`).
    func requestAuthorizationAndPrepareAssets() async {
        let status = await authorizationProvider()
        switch Self.authorizationDecision(for: status) {
        case .proceed:
            await prepareAssets()
        case let .unavailable(reason):
            markCommandsUnavailable(reason: reason)
        }
    }

    /// Pure status → decision mapping (#105), kept separate from the async
    /// system call so the decision logic is unit-testable without triggering
    /// the real permission dialog.
    enum AuthorizationDecision: Sendable, Equatable {
        case proceed
        case unavailable(reason: String)
    }

    nonisolated static func authorizationDecision(for status: SFSpeechRecognizerAuthorizationStatus) -> AuthorizationDecision {
        switch status {
        case .authorized, .notDetermined:
            return .proceed
        case .denied, .restricted:
            return .unavailable(
                reason: "Speech recognition permission denied — enable in iOS Settings > Privacy & Security > Speech Recognition"
            )
        @unknown default:
            return .unavailable(
                reason: "Speech recognition permission denied — enable in iOS Settings > Privacy & Security > Speech Recognition"
            )
        }
    }

    /// The real system dialog, bridged to async. `SFSpeechRecognizer` is the
    /// only authorization API for this stack — the iOS 26 SpeechAnalyzer/
    /// SpeechTranscriber/AssetInventory types expose no authorization API of
    /// their own (verified against the SDK headers/.swiftinterface, #105).
    /// `nonisolated` + `@Sendable` completion: the TCC callback fires on a
    /// background XPC queue; without both, the closure inherits @MainActor
    /// isolation from the enclosing class and the Swift 6 runtime isolation
    /// check traps at launch (same crash class as the AVAudio tap, CARQUIZ-1).
    nonisolated static func requestSystemAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Asset preparation (#77 device fix, engine-agnostic since #120)

    /// One-time launch check/install of the on-device model assets for the
    /// selected engine + locale (#120 — via the adapter). Without installed
    /// assets the transcriber never produces a result on a real device — the
    /// root cause of "commands never worked". The Slovak asset download surfaces
    /// through the SAME `.installingAssets` state the en-US path always used.
    /// Called once from AppState at launch (NOT from startListening, which runs
    /// per listening window); safe to re-enter (no-op after the first
    /// resolution).
    ///
    /// Locale is gated on `supportedLocales.contains` for BOTH engines — never
    /// `supportedLocale(equivalentTo:)`, which normalizes rather than tests
    /// membership and claims sk_SK even on the engine that lacks it (#120 trap).
    func prepareAssets() async {
        let locale = transcriberEngine.locale
        guard case .unknown = commandAvailability else { return }

        let supported = await transcriberEngine.supportedLocales()
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            markCommandsUnavailable(
                reason: "\(locale.identifier) not in \(transcriberEngine.engineTag) transcriber supportedLocales (\(supported.count) supported)"
            )
            return
        }

        let installed = await transcriberEngine.installedLocales()
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            assetsPrepared = true
            commandAvailability = .ready
            // Mirror to Sentry (#96 P2.3) so the founder's device confirms the
            // recognizer assets are present at launch — the pre-condition for
            // commands working at all.
            SentryLog.info("Voice command assets ready", category: .voice, attributes: ["source": "already-installed"])
            return
        }

        commandAvailability = .installingAssets
        SentryLog.info("Voice command assets installing", category: .voice, attributes: ["locale": locale.identifier])
        // The adapter declares asset needs with the SAME module factory the
        // analyzer will run — the installed assets must match the consumer.
        do {
            try await transcriberEngine.installAssets()
            assetsPrepared = true
            commandAvailability = .ready
            SentryLog.info("Voice command assets ready", category: .voice, attributes: ["source": "installed"])
        } catch {
            markCommandsUnavailable(reason: "Asset install failed: \(error.localizedDescription)")
        }
    }

    /// The inverse of `markCommandsUnavailable` for WINDOW-scoped failures: a
    /// listener that is now live proves the recognizer works, so restore `.ready`.
    ///
    /// WHY (field fix, 2026-07-26): `markCommandsUnavailable` is shared by durable
    /// device failures (permission, missing assets) and per-window ones (0 Hz mic
    /// on a cold launch, a refused engine start), and nothing ever cleared it. One
    /// transient miss latched "Unavailable" in Settings and killed the "LISTENING
    /// FOR COMMANDS" cue for the whole session while commands actually worked —
    /// Sentry shows fail-then-succeed on all five of the founder's launches.
    /// `assetsPrepared` is the gate: a device that never passed its pre-conditions
    /// must NOT be talked into `.ready` by a started engine.
    func recoverAvailabilityForLiveWindow() {
        guard assetsPrepared, case .unavailable = commandAvailability else { return }
        commandAvailability = .ready
        SentryLog.info("Voice commands recovered on a live window", category: .voice)
    }

    /// Fail-loud seam shared by all failure paths: flips the flag the UI reads
    /// and logs at error level so degrading to buttons is never silent.
    func markCommandsUnavailable(reason: String) {
        commandAvailability = .unavailable(reason: reason)
        // Mirror to Sentry (#96 P2) so a device that silently degrades to
        // buttons — the founder's exact symptom — surfaces in /check-crashes.
        SentryLog.error("Voice commands unavailable", category: .voice, attributes: ["reason": reason])
    }
}
