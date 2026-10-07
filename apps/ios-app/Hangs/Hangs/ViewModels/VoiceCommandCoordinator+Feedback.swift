//
//  VoiceCommandCoordinator+Feedback.swift
//  Hangs
//
//  Issue #122 Track A — the ambient-glow feedback policy (approved Variant C,
//  docs/design/ui-variants-2026-07-28-decisions.md). Presentation-only by
//  decision: the listener window is never suppressed or re-armed from here.
//  `matched` rides the same seam that fires the `.commandAck` earcon so audio
//  and visual ack can never diverge; `unmatched` rides the final unmatched
//  transcript, throttled so ordinary cabin conversation cannot keep the
//  indicator breathing (#120 precision-over-recall).
//

import Clocks
import Foundation

/// The transient, app-wide voice-feedback presentation state (#122 Variant C,
/// rule V1: this treatment owns voice-command feedback app-wide). A SEPARATE
/// axis from `CommandCapturePhase`: the capture phase models the listener
/// lifecycle, this models the driver-facing "did it hear me" glow.
enum VoiceFeedbackPhase: String, Sendable, Equatable {
    case idle
    /// A command was recognized — teal wash + light sweep. Shown at least
    /// `matchedGlowMinDisplay` (a <200 ms action must not flash) and at most
    /// `matchedGlowMaxDisplay` (must not lie about a stuck action).
    case matched
    /// A content-bearing final matched nothing — one slow amber breath.
    case unmatched
    /// #122 follow-up (TF 2026-10-07, founder: no feedback that the app heard a
    /// command): speech started while a command window is armed — the bar's
    /// "I hear you" state. Lowest precedence; never touches the glow.
    case hearing
    /// A transcript matched a command that has not fired yet (waiting for the
    /// final / stability) — the bar shows a spinner + the command word.
    case recognizing

    /// Only matched/unmatched drive the ambient wash + sweep; hearing and
    /// recognizing live on the listen bar alone, so they render like idle there.
    var litsGlow: Bool { self == .matched || self == .unmatched }
}

extension VoiceCommandCoordinator {
    // MARK: - Inputs (called from the routing seams)

    /// A command fired, or a spoken cancel was accepted: light the teal glow.
    /// Called wherever `emitEarcon(.commandAck)` fires.
    func noteMatchedForFeedback() {
        matchedGlowStartedAt = clock.now
        recognizingCommand = nil
        voiceFeedbackPhase = .matched
        scheduleGlowClear(after: matchedGlowMaxDisplay)
    }

    /// A FINAL transcript matched nothing. Throttled per the locked variant-page
    /// answers: content-bearing finals only (≥1 non-filler token), at most one
    /// per `unmatchedGlowCooldown`, and never twice in a row for the same
    /// transcript — the mic is open through ordinary passenger conversation and
    /// an indicator that lights on every sentence is itself the distraction.
    func noteUnmatchedForFeedback(_ normalized: String, isFinal: Bool) {
        guard isFinal else { return }
        guard voiceFeedbackPhase != .matched else { return } // ack outranks a miss
        guard VoiceCommandMatcher.hasContentTokens(normalized, language: commandLanguage) else { return }
        guard normalized != lastUnmatchedGlowText else { return }
        if let last = lastUnmatchedGlowAt,
           last.duration(to: clock.now).timeInterval < unmatchedGlowCooldown { return }
        lastUnmatchedGlowAt = clock.now
        lastUnmatchedGlowText = normalized
        recognizingCommand = nil
        voiceFeedbackPhase = .unmatched
        scheduleGlowClear(after: unmatchedGlowDisplay)
    }

    /// #122 follow-up (TF 2026-10-07): the energy VAD heard speech start. Only
    /// while a command window is armed and the app itself is silent, and only
    /// from `.idle` (every other phase outranks it). A rejected blip emits no
    /// end event, so it self-clears after `hearingGlowMaxDisplay`.
    func noteSpeechStartedForFeedback() {
        guard currentCommandScreen != nil, !isPlayingTTS() else { return }
        guard voiceFeedbackPhase == .idle else { return }
        voiceFeedbackPhase = .hearing
        scheduleGlowClear(after: hearingGlowMaxDisplay)
    }

    /// Speech ended without a decision yet: the "hearing" cue has nothing left
    /// to say. Leaves recognizing/matched/unmatched alone.
    func noteSpeechEndedForFeedback() {
        guard voiceFeedbackPhase == .hearing else { return }
        taskBag.cancel(.voiceFeedbackGlow)
        clearFeedbackGlow()
    }

    /// A transcript resolved to a command that is waiting (final / stability /
    /// settle) — show the word + spinner. Not for cooldown / latch suppressions:
    /// those repeat a command that already fired. Lights from idle / hearing /
    /// unmatched; matched outranks it.
    func noteRecognizingForFeedback(_ command: VoiceCommand) {
        guard voiceFeedbackPhase != .matched else { return }
        recognizingCommand = command
        voiceFeedbackPhase = .recognizing
        scheduleGlowClear(after: recognizingGlowMaxDisplay)
    }

    /// A FINAL has been fully processed and nothing fired: the utterance is
    /// over, so a lingering hearing/recognizing cue would be stale.
    func noteFinalProcessedForFeedback() {
        guard voiceFeedbackPhase == .hearing || voiceFeedbackPhase == .recognizing else { return }
        taskBag.cancel(.voiceFeedbackGlow)
        clearFeedbackGlow()
    }

    /// The "action landed" signal, called on every applied quiz-state
    /// transition: once the screen visibly changed, the matched glow has done
    /// its job — clear it as soon as the min-display floor allows instead of
    /// holding the full max window.
    func noteQuizStateChangedForFeedback() {
        guard voiceFeedbackPhase == .matched, let startedAt = matchedGlowStartedAt else { return }
        let remaining = matchedGlowMinDisplay - startedAt.duration(to: clock.now).timeInterval
        if remaining <= 0 {
            clearFeedbackGlow()
        } else {
            scheduleGlowClear(after: remaining)
        }
    }

    /// Reset twin (T7): no glow survives a quiz/listener reset. The unmatched
    /// cooldown deliberately survives — a reset must not re-open the throttle.
    func resetFeedbackGlow() {
        taskBag.cancel(.voiceFeedbackGlow)
        clearFeedbackGlow()
    }

    // MARK: - Clear timer

    private func clearFeedbackGlow() {
        recognizingCommand = nil
        guard voiceFeedbackPhase != .idle else { return }
        voiceFeedbackPhase = .idle
        matchedGlowStartedAt = nil
    }

    /// (Re)arm the single clear timer — re-adding under the same TaskKey
    /// cancels the previous timer, so the newest deadline always wins.
    private func scheduleGlowClear(after delay: TimeInterval) {
        // The clock is captured (not reached through `self`) so the timer keeps
        // its weak-self semantics: a released coordinator still clears nothing.
        let clock = clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.clearFeedbackGlow()
        }
        taskBag.add(task, key: .voiceFeedbackGlow)
    }
}
