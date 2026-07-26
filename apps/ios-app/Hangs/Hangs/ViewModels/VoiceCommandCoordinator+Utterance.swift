//
//  VoiceCommandCoordinator+Utterance.swift
//  Hangs
//
//  Issue #110 — the volatile-result policy, in one place instead of scattered
//  ifs across the consumer. The transcriber now reports VOLATILE hypotheses as
//  well as finals (build-33 root cause #1: waiting for the end-of-speech
//  endpoint meant the first "start" never fired, so the founder repeated
//  himself, which EXTENDED the segment and pushed finalization out past the
//  listening window). Volatile results buy latency, and this file pays for it:
//
//    1. AT MOST ONE COMMAND PER UTTERANCE — the invariant that makes volatile
//       results safe at all (`suppressionReason` / `noteCommandFired` /
//       `endUtterance`).
//    2. DESTRUCTIVE COMMANDS REQUIRE A FINAL RESULT (`requiresFinalResult`).
//    3. A VOLATILE MUST BE DELIVERED TWICE UNCHANGED before it may fire
//       (`noteVolatileTranscript`) — the growing-hypothesis hole the matcher's
//       content-token cap structurally cannot see.
//    4. A ~1.5 s per-command COOLDOWN as the second layer behind the latch.
//
//  State lives on the class (Swift forbids stored properties in an extension);
//  every read/write of it goes through the helpers here.
//

import Foundation

extension VoiceCommandCoordinator {
    // MARK: - Volatile-result Policy

    /// Whether a command may only fire from a FINAL result, on `screen`.
    ///
    /// A volatile hypothesis is revisable by design — the transcriber replaces
    /// it as more audio arrives — so acting on one is a bet that the word will
    /// survive. That bet is fine when the worst case merely ACCELERATES what
    /// would have happened anyway, and unacceptable when it destroys something.
    /// That is a property of the ACTION, so it is screen-scoped: the same word
    /// routes to different actions on different screens.
    static func requiresFinalResult(_ command: VoiceCommand, on screen: VoiceCommandScreen) -> Bool {
        // `ok` is the one word whose classification flips per screen. On the
        // confirmation sheet it SUBMITS the answer, and the 10 s auto-confirm
        // does NOT make that benign: that timer exists precisely so a wrong
        // transcription can be caught with "again", and an early `ok` removes
        // the escape before the founder can use it. Note the asymmetry it would
        // otherwise create — `again` (the escape) waits for a final, so ambient
        // speech would race the correction and win. "okay" is also the single
        // highest-frequency backchannel in conversation.
        if screen == .confirmation, command == .ok { return true }

        switch command {
        // Benign — worst case is an early version of the default outcome.
        case .start: // opens the mic; a stray one is undone by re-recording
            return false
        case .ok: // on the RESULT screen only (see the override above), where
            return false // advancing is the default outcome anyway
        case .next: // the result screen auto-advances anyway
            return false
        case .repeatQuestion: // replays audio; loses nothing
            return false

        // Destructive — a revised hypothesis cannot undo these.
        case .skip: // burns a freemium question (100/month) — unrecoverable
            return true
        case .again: // rerecordAnswer() DISCARDS the transcribed answer
            return true
        case .stop: // cancelProcessing() DISCARDS the in-flight answer
            return true
        }
    }

    /// Why a matched command was not routed. Emitted to Sentry (see
    /// `handleCommandTranscript`) because a true fire and a false fire log
    /// identically today, so field precision is otherwise unmeasurable — the
    /// suppression counters and the beginSkipUndoWindow/abortSkipUndoWindow
    /// pair are our only false-fire proxies.
    enum CommandSuppression: String {
        /// A command already fired for this utterance.
        case utteranceLatch = "utterance-latch"
        /// Destructive command seen on a revisable volatile hypothesis.
        case awaitingFinal = "awaiting-final"
        /// Volatile hypothesis that the transcriber has not yet repeated
        /// unchanged — still growing, so still a sentence prefix.
        case awaitingStable = "awaiting-stable"
        /// The same command fired less than `commandCooldown` ago.
        case cooldown
    }

    /// The gate in front of routing: `nil` means fire, otherwise the reason not
    /// to. Order matters — the utterance latch is checked first because it is
    /// the load-bearing invariant, and reporting it is what makes double-fire
    /// pressure visible.
    func suppressionReason(
        for command: VoiceCommand,
        on screen: VoiceCommandScreen,
        isFinal: Bool,
        isStableVolatile: Bool
    ) -> CommandSuppression? {
        if commandFiredThisUtterance { return .utteranceLatch }
        if !isFinal, Self.requiresFinalResult(command, on: screen) { return .awaitingFinal }
        if !isFinal, !isStableVolatile { return .awaitingStable }
        if let last = lastFiredCommand,
           last.command == command,
           now().timeIntervalSince(last.at) < Self.commandCooldown {
            return .cooldown
        }
        return nil
    }

    /// Record a volatile hypothesis and report whether it REPEATS the previous
    /// volatile of this utterance unchanged.
    ///
    /// WHY: the matcher's content-token cap only ever sees ONE delivered
    /// transcript, while the transcriber emits a GROWING hypothesis — so every
    /// utterance passes through a 1-token prefix state and the cap is a no-op on
    /// the leading edge of all speech. "Okay, tak to bolo dobré" arrives as
    /// volatile "okay" and would confirm the answer ~300 ms in; a radio
    /// "Starting now…" arrives as volatile "start". Length cannot separate those
    /// — STABILITY can: a sentence never presents the same hypothesis twice, it
    /// keeps growing, whereas a one-word command followed by silence is re-emitted
    /// unchanged long before the end-of-speech endpoint, so the latency win the
    /// volatile results were turned on for survives.
    ///
    /// Called for EVERY volatile transcript (including ones the matcher rejects)
    /// so the baseline tracks what the transcriber actually emitted.
    func noteVolatileTranscript(_ normalized: String) -> Bool {
        defer { lastVolatileText = normalized }
        return lastVolatileText == normalized
    }

    /// Latch the utterance and start the cooldown. Called ONLY on the path that
    /// actually routes a command.
    func noteCommandFired(_ command: VoiceCommand) {
        commandFiredThisUtterance = true
        lastFiredCommand = (command, now())
    }

    /// End the utterance in progress: a final result is the utterance boundary,
    /// so the latch (and only the latch — the cooldown deliberately spans
    /// utterances) is cleared. Also called when the consumer stops, since a torn
    /// -down listener leaves no utterance to be mid-way through.
    func endUtterance() {
        commandFiredThisUtterance = false
        lastVolatileText = nil // the next utterance's first volatile is unproven
    }
}
