//
//  VoiceCommandCoordinator+Routing.swift
//  Hangs
//
//  What a transcript MEANS, once one arrives: normalizing it, matching it
//  against the screen-scoped `VoiceCommandMatcher` under the volatile-result
//  policy in +Utterance, and fanning the recognized command out to its
//  per-screen action (77.8–77.9). Split out of
//  VoiceCommandCoordinator+Listening.swift (past the ~300-line cap); the seam is
//  the window itself — +Listening owns WHETHER we are listening and keeps the
//  consumer loop alive, this file owns what flows through it.
//

import Foundation
import os

extension VoiceCommandCoordinator {
    // MARK: - Transcript Handling

    /// Map one transcript — a volatile hypothesis OR a final — to a
    /// screen-scoped command (or ignore it). Guards on `currentCommandScreen` so
    /// a transcript that lands after the window closed (e.g. mid-transition into
    /// recording, or while feedback TTS plays) is dropped.
    ///
    /// **AT MOST ONE COMMAND PER UTTERANCE (#119).** This is the load-bearing
    /// invariant that makes volatile results safe. The transcriber emits a
    /// GROWING hypothesis and then one final, so a single spoken "start" reaches
    /// this method several times: the first transcript that resolves to a
    /// command AND clears `suppressionReason` fires it, and EVERY later
    /// transcript of that utterance — volatile or final — is suppressed until
    /// the final ends the utterance. Without the latch a single "ok … again"
    /// utterance would submit the answer from an early hypothesis and then
    /// discard it from a later one.
    func handleCommandTranscript(_ transcript: CommandTranscript) async {
        // The final result IS the utterance boundary, whatever happens below
        // (window closed / unmatched / suppressed) — the latch must never
        // outlive the utterance it belongs to.
        defer { if transcript.isFinal { endUtterance() } }

        // Release diagnostics: the command hot path was invisible in Sentry, so
        // "commands don't work" on-device could not be triaged remotely (only
        // availability was logged). A log at every exit so Sentry distinguishes:
        // window closed vs no vocab match vs suppressed vs matched — and, since
        // #119, whether the source was a volatile hypothesis or a final, plus the
        // token count that the matcher's content cap keys off. The two DROP exits
        // are sampled (`shouldLogDroppedTranscript`); the command-carrying ones
        // are not.
        let normalized = VoiceCommandMatcher.normalize(transcript.text)
        let tokens = normalized.split(separator: " ").count

        // Emission cadence (`noteTranscriptArrival`): stamped BEFORE any early
        // return so the interval measures what the transcriber emitted, not the
        // subset we acted on. `volatileSettleDelay` is bounded below by this
        // number, measured off-device and confirmed here. -1 == first transcript
        // of the utterance (no interval), never a real measurement.
        let sincePrevMs = noteTranscriptArrival()

        // #119 volatile stability (see `noteVolatileTranscript`): recorded for
        // EVERY volatile, including the ones dropped below, so the baseline is
        // what the transcriber emitted rather than what happened to match.
        let isStableVolatile = transcript.isFinal || noteVolatileTranscript(normalized)

        // ANY newer transcript supersedes a pending settle — it is fresher
        // evidence about the same utterance. A DIFFERENT volatile means the
        // sentence is still growing (this is the prefix protection); an
        // IDENTICAL one is the repeat signal, which fires below without waiting;
        // a FINAL decides on its own, immediately. Only the first of those three
        // is reported as a suppression — see `supersedePendingSettle`.
        supersedePendingSettle(normalized: normalized, isFinal: transcript.isFinal, tokens: tokens)

        guard let screen = currentCommandScreen else {
            if shouldLogDroppedTranscript(isFinal: transcript.isFinal) {
                SentryLog.info(
                    "voice cmd transcript dropped — window closed",
                    category: .voice,
                    attributes: droppedTranscriptAttributes(
                        normalized, isFinal: transcript.isFinal, tokens: tokens, sincePrevMs: sincePrevMs
                    )
                )
            }
            return
        }

        // Spoken-cancel path (77.10 carry-over): while a skip undo-window is
        // open on the question screen, a spoken cancel word ("stop"/"no")
        // aborts the pending skip — the spoken twin of the tap-abort. "stop" is
        // NOT in the question screen's normal command set, so this must be
        // checked BEFORE the matcher (which would otherwise drop it).
        if pendingSkipWindow != nil {
            let cancelTokens = VoiceCommandMatcher.normalize(transcript.text).split(separator: " ").map(String.init)
            if cancelTokens.contains(where: { VoiceCommandLexicon.isCancelWord($0) }) {
                emitEarcon(.commandAck) // acknowledge the recognized cancel
                noteMatchedForFeedback() // #122: visual twin of the ack earcon
                abortSkipUndoWindow()
                return
            }
        }

        guard let command = VoiceCommandMatcher.match(
            transcript: transcript.text, on: screen, isFinal: transcript.isFinal
        ) else {
            // #122: the "heard you, didn't understand" glow — throttled inside.
            noteUnmatchedForFeedback(normalized, isFinal: transcript.isFinal)
            if shouldLogDroppedTranscript(isFinal: transcript.isFinal) {
                var attributes = droppedTranscriptAttributes(
                    normalized, isFinal: transcript.isFinal, tokens: tokens, sincePrevMs: sincePrevMs
                )
                attributes["screen"] = String(describing: screen)
                SentryLog.info("voice cmd transcript unmatched", category: .voice, attributes: attributes)
            }
            return
        }

        if let suppression = suppressionReason(
            for: command, on: screen, isFinal: transcript.isFinal, isStableVolatile: isStableVolatile
        ) {
            // `awaitingStable` is a WAIT, not a rejection: the repeat signal may
            // never arrive (volatiles are emitted on CHANGE, not on a timer), so
            // hand this hypothesis to the settle timer instead of dropping it —
            // otherwise the command only ever fires from the end-of-speech
            // final and the latency fix is a no-op. Every other reason is final.
            if suppression == .awaitingStable {
                armVolatileSettle(command, text: normalized, on: screen)
            }
            // NOT sampled, unlike the two drop exits above: reaching here already
            // required a hit on the seven-word vocabulary, and the latch + the
            // 1.5 s cooldown bound how often that can repeat within an utterance.
            // These are the low-frequency events the quota is FOR — the
            // awaiting-stable / settle behaviour #119 is triaged on. Carries no
            // raw speech, only the matched command.
            SentryLog.info(
                "voice cmd suppressed",
                category: .voice,
                attributes: [
                    "screen": String(describing: screen), "command": command.rawValue,
                    "reason": suppression.rawValue, "final": transcript.isFinal, "tokens": tokens,
                    "sincePrevMs": sincePrevMs ?? -1,
                ]
            )
            return
        }

        fireCommand(
            command, on: screen, text: normalized,
            path: transcript.isFinal ? .finalResult : .volatileRepeat,
            sincePrevMs: sincePrevMs
        )
    }

    // MARK: - Drop-log Sampling

    /// Whether a transcript that will be DROPPED (window closed / no vocab match)
    /// may spend a Sentry event: every final, plus the first volatile of each
    /// utterance. Mirrors the producer-side sampling in
    /// `SilenceDetectionService+Engine`, and for the same reason — a volatile is
    /// emitted on every hypothesis change (several per second while ANY speech is
    /// audible) and the window stands open for most of a question, so a drive with
    /// the radio on would otherwise ship thousands of events per drive on a
    /// quota'd, rate-limited logger and crowd out the "voice cmd matched" /
    /// `sincePrevMs` events that are the only field confirmation of the
    /// off-device measurement. The producer's sampling alone does not cover this:
    /// it counts what the TRANSCRIBER emitted, this counts what the CONSUMER did
    /// with it, and only the latter is per-exit.
    func shouldLogDroppedTranscript(isFinal: Bool) -> Bool {
        if isFinal { return true }
        defer { loggedVolatileThisUtterance = true }
        return !loggedVolatileThisUtterance
    }

    /// Attributes shared by the two drop logs.
    ///
    /// Metadata only — never the transcript text itself, per the no-raw-speech
    /// rule in Logging.swift (the pre-GA temporary `text` exception was removed
    /// 2026-07-30).
    func droppedTranscriptAttributes(
        _ normalized: String, isFinal: Bool, tokens: Int, sincePrevMs: Int?
    ) -> [String: Any] {
        [
            "len": normalized.count, "final": isFinal, "tokens": tokens,
            "sincePrevMs": sincePrevMs ?? -1,
        ]
    }

    // MARK: - Fan-out

    /// A command was recognized on the current screen. Fires the
    /// `onCommandRecognized` observation hook (tests + future earcons), then
    /// routes it to an action (77.8–77.9). Routing is screen-scoped a second
    /// time via `routeCommand` so a transcript that lands as the window closes
    /// can't fire the wrong action.
    func handleRecognizedCommand(_ command: VoiceCommand) {
        Logger.voice.info("🎙️ Command recognized: \(command.rawValue, privacy: .public)")
        noteRecognizedCommand(command) // release diagnostics (#96 P2)
        emitEarcon(.commandAck) // 77.10 command-ack tone
        noteMatchedForFeedback() // #122: visual twin of the ack earcon
        onCommandRecognized?(command)
        routeCommand(command)
    }

    /// Map a recognized command to its per-screen action (77.8 / 77.9). Buttons
    /// + the 10 s auto-confirm + auto-advance remain the untouched fallbacks;
    /// this is additive. Async actions hop to a Task so the @MainActor-sync
    /// consumer path is never blocked on network/audio. Every fan-out target is
    /// an injected façade closure (decision 4).
    func routeCommand(_ command: VoiceCommand) {
        guard let screen = currentCommandScreen else {
            SentryLog.info(
                "voice cmd not routed — window closed after match",
                category: .voice,
                attributes: ["command": command.rawValue]
            )
            return
        }
        switch (screen, command) {
        // Home — spoken "start" begins the quiz.
        case (.home, .start):
            Task { [weak self] in await self?.startNewQuiz() }

        // Question — hands-free START recovery (P4a, founder-overridable flag).
        case (.question, .start):
            guard voiceStartOnQuestionEnabled else { return }
            cancelAnswerTimer()
            cancelThinkingTime()
            Task { [weak self] in await self?.startRecording() }

        // Question — replay the question audio + re-arm the listener via
        // repeatQuestion(). playQuestionAudio re-arms after TTS.
        case (.question, .repeatQuestion):
            Task { [weak self] in await self?.repeatQuestion() }

        // Question — skip via the ~2.5 s undo-window (commit / abort).
        case (.question, .skip):
            beginSkipUndoWindow()

        // Confirmation sheet — on top of the 10 s auto-confirm + buttons.
        case (.confirmation, .ok):
            Task { [weak self] in await self?.confirmAnswer() }

        case (.confirmation, .again):
            rerecordAnswer()

        case (.confirmation, .stop):
            cancelProcessing()

        // Confirmation sheet — freeze it (#171 Track D). Not offered as a
        // spoken RESUME: pausing stops the listener, so "pokračuj" would never
        // be heard; the sheet's Continue pill is the way back.
        case (.confirmation, .pause):
            pauseOnConfirmation()

        // Result — advance (on top of auto-advance + button).
        case (.result, .next), (.result, .ok):
            continueToNext()

        default:
            // Command not valid on this screen — inert. Logged so a matched
            // command that silently does nothing is visible in Sentry.
            SentryLog.info(
                "voice cmd inert on screen",
                category: .voice,
                attributes: ["screen": String(describing: screen), "command": command.rawValue]
            )
        }
    }
}
