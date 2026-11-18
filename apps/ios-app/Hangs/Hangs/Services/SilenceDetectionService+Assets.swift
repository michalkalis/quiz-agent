//
//  SilenceDetectionService+Assets.swift
//  Hangs
//
//  Readiness for the command recognizer: the #105/#237 speech-recognition
//  authorization flow (asked only when the player turns commands on) and the
//  #77/#120 on-device model-asset preparation for the selected engine + locale. Split out of SilenceDetectionService.swift (past
//  the ~300-line cap after #120's engine-seam additions); the VAD state machine
//  and stream plumbing stay there, the analyzer lifecycle is in +Engine.swift.
//

import Foundation

import os

// @preconcurrency: the legacy SFSpeechRecognizer.requestAuthorization completion
// fires on a TCC background queue; without this the inferred @MainActor
// isolation check traps at launch (see SilenceDetectionService.swift).
@preconcurrency import Speech

extension SilenceDetectionService {
    // MARK: - Authorization (#105, #237 — only when the player asks)

    /// Launch-time readiness WITHOUT a prompt (#237, founder 2026-11-17: the
    /// speech-recognition alert at first launch, before onboarding, was bad
    /// UX and did not say what it was for). Reads the current status:
    /// authorized → prepare the model as before; never asked → `.permissionNeeded`
    /// (the onboarding and the listen bar offer "Turn on"); denied/restricted →
    /// `.permissionDenied` (the bar offers iOS Settings). The prompt itself is
    /// `enableCommands()`'s alone.
    func prepareCommandsIfAuthorized() async {
        let status = authorizationStatusProvider()
        guard status == .authorized else {
            let next = Self.permissionAvailability(for: status)
            if commandAvailability != next { commandAvailability = next }
            return
        }
        if commandAvailability.awaitsPermission { commandAvailability = .unknown }
        await prepareAssets()
    }

    /// See the protocol. The prompt only while the status is undecided — iOS
    /// would not show it again anyway, and a denied player is sent to Settings
    /// by the caller instead.
    func enableCommands() async -> Bool {
        var status = authorizationStatusProvider()
        if status == .notDetermined {
            status = await authorizationProvider()
        }
        SentryLog.info("Voice commands enable requested", category: .voice, attributes: ["status": status.rawValue])
        guard status == .authorized else {
            commandAvailability = .permissionDenied
            return false
        }
        if commandAvailability.awaitsPermission { commandAvailability = .unknown }
        // Not awaited: the model download can take a while, and neither the
        // onboarding nor the quiz may wait on it. Re-entry while it runs is a
        // no-op (one download).
        if assetPreparationTask == nil {
            assetPreparationTask = Task { [weak self] in
                await self?.prepareAssets()
                self?.assetPreparationTask = nil
            }
        }
        return true
    }

    /// #175 (founder 2026-09-09): the command grammar follows the QUIZ
    /// language, so the recognizer may have to change between quizzes. Swaps
    /// the adapter, resets availability and re-runs the readiness check for the
    /// new locale. Refused while a listening window is open or starting — the
    /// analyzer is built from `transcriberEngine` per window (+Engine), so a
    /// swap mid-window would orphan modules; the per-window start path calls
    /// this again, so the switch lands on the next window.
    ///
    /// #237: never prompts. While commands wait on the permission it re-reads
    /// the status on every window start (no prompt, cheap), so a player who
    /// allowed speech recognition in iOS Settings gets commands on return.
    func setCommandEngine(_ selection: CommandEngineSelection) async {
        guard !transcriberEngine.matches(selection) else {
            if commandAvailability.awaitsPermission { await prepareCommandsIfAuthorized() }
            return
        }
        guard audioEngine == nil, !startInFlight else {
            Logger.voice.warning("🔇 SilenceDetection: engine switch to \(selection.rawValue) deferred — a listening window is open (#175)")
            return
        }
        let engine = selection.makeAdapter()
        transcriberEngine = engine
        assetsPrepared = false
        commandAvailability = .unknown
        VoiceTelemetryContext.set(engine: engine.engineTag, locale: engine.locale.identifier)
        SentryLog.info(
            "Voice command engine switched", category: .voice,
            attributes: ["engine": engine.engineTag, "locale": engine.locale.identifier]
        )
        await prepareCommandsIfAuthorized()
    }

    /// Pure status → availability mapping for a status that is not
    /// `.authorized` (#237), kept apart from the system call so it is
    /// unit-testable without the dialog.
    nonisolated static func permissionAvailability(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> VoiceCommandAvailability {
        switch status {
        case .notDetermined: .permissionNeeded
        case .authorized: .unknown
        case .denied, .restricted: .permissionDenied
        @unknown default: .permissionDenied
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
    /// resolution). #237: reached only once speech recognition is allowed.
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
        // Mirror to Sentry (#96 P2) so a device that silently degrades to
        // buttons — the founder's exact symptom — surfaces in /check-crashes.
        SentryLog.error("Voice commands unavailable", category: .voice, attributes: ["reason": reason])
        // #237: a failed listening window says nothing about the permission —
        // overwriting it would take the player's "Turn on" / "Settings" button
        // away for the rest of the session.
        guard !commandAvailability.awaitsPermission else { return }
        commandAvailability = .unavailable(reason: reason)
    }
}
