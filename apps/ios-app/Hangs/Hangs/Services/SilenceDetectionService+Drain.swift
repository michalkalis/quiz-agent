//
//  SilenceDetectionService+Drain.swift
//  Hangs
//
//  Teardown that finishes what the recognizer already heard. `stopListening`
//  used to cancel the result stream and drop the analyzer, so a final on its
//  way (a command said just before the window closed) was thrown away. Now
//  the mic still comes down at once — the app never listens under its own
//  speech — and the analyzer is finalized through the end of the audio it
//  already has, bounded by `drainBudget` so a teardown can never hang.
//
//  What a drained final may do is deliberately narrow. The coordinator stops
//  its consumer before the service stops, so nobody is listening for it; and
//  handing it to whatever window opens next would let, say, the tail of an
//  answer recording land on the answer sheet as a "new answer". It is kept
//  for the NEXT window only when that window listens on the same screen,
//  with the same recognizer, soon after (a restart: route change, engine
//  rebuild). Everything else is counted in the drain log and dropped.
//
//  None of this runs on the Simulator (no Slavic transcriber there); the
//  rules are pure and tested, the analyzer calls are owed a device check.
//

import Clocks
import Foundation
import os
import Speech

/// A final a torn-down window's analyzer delivered after the mic came down.
struct DrainedFinal {
    let transcript: CommandTranscript
    let screen: VoiceCommandScreen?
    let localeIdentifier: String
    let at: AnyClock<Duration>.Instant
}

enum DrainOutcome: String, Equatable, Sendable {
    /// The analyzer finalized everything it had heard within the budget.
    case finalized
    /// It did not; analysis was cancelled and whatever was pending is lost.
    case timedOut
    /// Finalizing threw; analysis was cancelled.
    case failed
}

extension SilenceDetectionService {
    /// How long a stopped window's analyzer may take to finalize what it
    /// already heard. A short command needs a fraction of that; the bound is
    /// what keeps a stuck analyzer from holding the next window back.
    nonisolated static let drainBudget: Duration = .milliseconds(800)

    /// How old a drained final may be when the next window opens. Older, it
    /// belongs to a moment the driver has already moved past (a question
    /// re-read, a feedback line) and would act out of the blue.
    nonisolated static let drainedFinalMaxAge: Duration = .milliseconds(1500)

    /// Stop this window's analyzer by finalizing instead of cancelling. The
    /// caller has already ended the input and taken the mic down.
    func drainAnalyzer() {
        listeningWindow += 1
        // A preheat still running means no audio was ever analyzed.
        analyzerTask?.cancel()
        analyzerTask = nil
        guard analyzerStarted, let analyzer, let transcription = transcriptionTask else {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            analyzer = nil
            analyzerStarted = false
            return
        }
        transcriptionTask = nil
        self.analyzer = nil
        analyzerStarted = false
        drainedFinal = nil
        let screen = commandScreen
        let locale = transcriberEngine.locale.identifier
        let clock = clock
        let startedAt = clock.now
        drainTask = Task { [weak self] in
            let outcome = await Self.finishWithinDeadline(
                clock: clock, budget: Self.drainBudget,
                finalize: { try await analyzer.finalizeAndFinishThroughEndOfInput() },
                cancel: { await analyzer.cancelAndFinishNow() }
            )
            transcription.cancel()
            self?.endDrain(outcome, screen: screen, locale: locale, startedAt: startedAt)
        }
    }

    /// A result of a window that is already torn down. Only its final can be
    /// worth keeping; the last one wins.
    func noteDrainedTranscript(_ transcript: CommandTranscript) {
        guard transcript.isFinal, !transcript.text.isEmpty else { return }
        drainedFinal = transcript
    }

    func endDrain(
        _ outcome: DrainOutcome, screen: VoiceCommandScreen?, locale: String,
        startedAt: AnyClock<Duration>.Instant
    ) {
        drainTask = nil
        let final = drainedFinal
        drainedFinal = nil
        pendingDrainedFinal = final.map {
            DrainedFinal(transcript: $0, screen: screen, localeIdentifier: locale, at: clock.now)
        }
        SentryLog.info("voice cmd drain", category: .voice, attributes: [
            "outcome": outcome.rawValue,
            "final": final != nil,
            "ms": Int((startedAt.duration(to: clock.now).timeInterval * 1000).rounded()),
            "screen": screen.map { String(describing: $0) } ?? "none",
        ])
    }

    /// The next window's consumer just subscribed: hand it the drained final
    /// if it is for this very screen and recognizer and still fresh. Any
    /// other pending final is dropped here, so none can outlive one window.
    func redeliverDrainedFinal() {
        guard let pending = pendingDrainedFinal else { return }
        pendingDrainedFinal = nil
        guard Self.redelivers(
            pending, to: commandScreen, localeIdentifier: transcriberEngine.locale.identifier, now: clock.now
        ) else { return }
        commandChannel.yield(pending.transcript)
    }

    /// The redelivery rule, pure so it is testable without an analyzer.
    nonisolated static func redelivers(
        _ pending: DrainedFinal, to screen: VoiceCommandScreen?, localeIdentifier: String,
        now: AnyClock<Duration>.Instant
    ) -> Bool {
        guard let screen, pending.screen == screen, pending.localeIdentifier == localeIdentifier else { return false }
        return pending.at.duration(to: now) <= drainedFinalMaxAge
    }

    /// Run `finalize`, but never wait for it longer than `budget` on `clock`.
    /// Past the budget, or when it throws, `cancel` is started (not awaited:
    /// it must not be able to hold the caller either). The finalize call is
    /// unstructured on purpose — a task group would wait for a call that
    /// ignores cancellation, which is the hang this exists to rule out.
    nonisolated static func finishWithinDeadline(
        clock: AnyClock<Duration>, budget: Duration,
        finalize: @escaping @Sendable () async throws -> Void,
        cancel: @escaping @Sendable () async -> Void
    ) async -> DrainOutcome {
        let decided = OSAllocatedUnfairLock(initialState: false)
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<DrainOutcome, Never>) in
            let decide: @Sendable (DrainOutcome) -> Void = { outcome in
                let first = decided.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: outcome) }
            }
            work = Task {
                do {
                    try await finalize()
                    decide(.finalized)
                } catch {
                    decide(.failed)
                }
            }
            timer = Task {
                try? await clock.sleep(for: budget)
                decide(.timedOut)
            }
        }
        timer?.cancel()
        if outcome != .finalized {
            work?.cancel()
            Task { await cancel() }
        }
        return outcome
    }
}
