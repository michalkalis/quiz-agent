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
//    3. A VOLATILE MUST HAVE STOPPED GROWING before it may fire — the
//       growing-hypothesis hole the matcher's content-token cap structurally
//       cannot see. Two INDEPENDENT signals establish that, either one is
//       enough: the transcriber delivered the same normalized text twice
//       (`noteVolatileTranscript`, fires immediately), or the text stood
//       unchanged for `volatileSettleDelay` (`armVolatileSettle`). The second
//       exists because the first is not contractual — see `armVolatileSettle`.
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
        /// Volatile hypothesis not yet proven stopped-growing — so still a
        /// possible sentence prefix. Arms the settle fallback.
        case awaitingStable = "awaiting-stable"
        /// A pending settle was dropped because a newer transcript arrived.
        case settleSuperseded = "settle-superseded"
        /// The settle delay elapsed but the world moved on (screen changed, a
        /// different hypothesis won) — nothing was routed.
        case settleStale = "settle-stale"
        /// The same command fired less than `commandCooldown` ago.
        case cooldown
    }

    /// Which evidence fired a command. Logged on EVERY fire because the field
    /// question we cannot otherwise answer is whether volatile results are
    /// actually buying latency on device, or whether every command still comes
    /// from the end-of-speech final (the build-33 bug, silently restored).
    enum CommandFirePath: String {
        case finalResult = "final"
        case volatileRepeat = "volatile-repeat"
        case volatileSettle = "volatile-settle"
    }

    /// A volatile hypothesis that matched a command and is waiting out
    /// `volatileSettleDelay` to prove it has stopped growing.
    struct PendingVolatileSettle {
        let command: VoiceCommand
        /// The NORMALIZED text it matched from — re-validated against
        /// `lastVolatileText` when the delay elapses.
        let text: String
        /// The screen it matched on. A command must never land on a screen the
        /// founder left while we were waiting.
        let screen: VoiceCommandScreen
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
    /// volatile of this utterance unchanged — the FAST stability signal.
    ///
    /// WHY a stability gate at all: the matcher's content-token cap only ever
    /// sees ONE delivered transcript, while the transcriber emits a GROWING
    /// hypothesis — so every utterance passes through a 1-token prefix state and
    /// the cap is a no-op on the leading edge of all speech. "Okay, tak to bolo
    /// dobré" arrives as volatile "okay" and would confirm the answer ~300 ms
    /// in; a radio "Starting now…" arrives as volatile "start". Length cannot
    /// separate those — stopped-growing can: a sentence keeps growing, a
    /// finished one-word command does not.
    ///
    /// WHY only a signal and not THE gate: a repeat is proof, but its absence is
    /// not disproof. Apple documents volatile results as change-driven ("each
    /// phrase is sent one or more times as the interpretation gets better"), so
    /// the transcriber owes us nothing while the founder is silent. A probe of
    /// the shipped configuration did see a second delivery for every command
    /// word — but only because a punctuation refinement ("Start" → "Start.")
    /// collapses to the same string through `VoiceCommandMatcher.normalize`.
    /// That is luck, not contract. `armVolatileSettle` is the signal that does
    /// not depend on it.
    ///
    /// Called for EVERY volatile transcript (including ones the matcher rejects)
    /// so the baseline tracks what the transcriber actually emitted.
    func noteVolatileTranscript(_ normalized: String) -> Bool {
        defer { lastVolatileText = normalized }
        return lastVolatileText == normalized
    }

    // MARK: - Settle Fallback (the second, independent stability signal)

    /// Start the settle timer for a matched-but-unproven volatile: if this exact
    /// normalized text is still the newest hypothesis `volatileSettleDelay` from
    /// now, it has stopped growing and may fire.
    ///
    /// WHY: without it, the whole latency win rides on the transcriber choosing
    /// to re-deliver an unchanged hypothesis (see `noteVolatileTranscript`). If a
    /// model update, another locale or noisy car audio drops that re-delivery,
    /// every command silently falls back to the end-of-speech final — which IS
    /// the build-33 bug (the founder says "start" seven times, each repeat
    /// extending the segment and pushing finalization past the window). Elapsed
    /// silence is independent evidence: it needs no cooperation from the
    /// transcriber, only the absence of a newer hypothesis.
    func armVolatileSettle(_ command: VoiceCommand, text: String, on screen: VoiceCommandScreen) {
        pendingVolatileSettle = PendingVolatileSettle(command: command, text: text, screen: screen)
        let delay = volatileSettleDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.fireSettledVolatile()
        }
        taskBag.add(task, key: .volatileSettle)
    }

    /// Drop the pending settle and return what was dropped (for the caller's
    /// log). Any newer transcript is fresher evidence about the same utterance,
    /// and an ended utterance or a torn-down consumer leaves nothing for a
    /// settle to belong to.
    @discardableResult
    func cancelVolatileSettle() -> PendingVolatileSettle? {
        guard let pending = pendingVolatileSettle else { return nil }
        pendingVolatileSettle = nil
        taskBag.cancel(.volatileSettle)
        return pending
    }

    /// The settle delay elapsed. Re-validate everything that could have moved
    /// while we waited, then route through the SAME funnel a live transcript
    /// uses — the at-most-one-command-per-utterance latch and the cooldown are
    /// not optional for this path.
    func fireSettledVolatile() {
        guard let pending = pendingVolatileSettle else { return }
        pendingVolatileSettle = nil

        // `lastVolatileText`: a different hypothesis would have cancelled us, so
        // this only catches an ordering surprise. `currentCommandScreen`: the
        // founder can leave the screen while we wait (auto-advance, a tap, TTS
        // starting) — a command scoped to a screen he is no longer on is wrong.
        guard lastVolatileText == pending.text, currentCommandScreen == pending.screen else {
            logSettleNotRouted(pending, reason: .settleStale)
            return
        }
        if let suppression = suppressionReason(
            for: pending.command, on: pending.screen, isFinal: false, isStableVolatile: true
        ) {
            logSettleNotRouted(pending, reason: suppression)
            return
        }
        fireCommand(pending.command, on: pending.screen, text: pending.text, path: .volatileSettle)
    }

    /// Drop the pending settle because a newer transcript is in hand, and report
    /// it — the field needs to see how often a settle was armed and then talked
    /// over, otherwise "commands are slow" and "commands mis-fire" look the same
    /// in Sentry. No-op when nothing is parked.
    func supersedePendingSettle(isFinal: Bool, tokens: Int) {
        guard let pending = cancelVolatileSettle() else { return }
        SentryLog.info(
            "voice cmd suppressed",
            category: .voice,
            attributes: [
                "screen": String(describing: pending.screen), "command": pending.command.rawValue,
                "reason": CommandSuppression.settleSuperseded.rawValue,
                "final": isFinal, "tokens": tokens,
            ]
        )
    }

    private func logSettleNotRouted(_ pending: PendingVolatileSettle, reason: CommandSuppression) {
        SentryLog.info(
            "voice cmd suppressed",
            category: .voice,
            attributes: [
                "screen": String(describing: pending.screen), "command": pending.command.rawValue,
                "reason": reason.rawValue, "final": false, "path": CommandFirePath.volatileSettle.rawValue,
            ]
        )
    }

    /// The ONLY place a command is routed. Both volatile signals and the final
    /// path funnel through here so the latch, the cooldown seed, the earcon ack
    /// and the field log can never diverge per-path.
    func fireCommand(
        _ command: VoiceCommand, on screen: VoiceCommandScreen, text: String, path: CommandFirePath
    ) {
        SentryLog.info(
            "voice cmd matched",
            category: .voice,
            attributes: [
                "screen": String(describing: screen), "command": command.rawValue,
                "final": path == .finalResult, "tokens": text.split(separator: " ").count,
                "path": path.rawValue,
            ]
        )
        noteCommandFired(command) // latch the utterance + start the cooldown
        applyCaptureEvent(.recognize) // ack (no phase change) — earcon seam for 77.10
        handleRecognizedCommand(command)
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
        // A settle belongs to the utterance that armed it: a command must never
        // fire for an utterance that already ended or a listener that is gone.
        cancelVolatileSettle()
    }
}
