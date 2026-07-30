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
}

extension VoiceCommandCoordinator {
    // MARK: - Inputs (called from the routing seams)

    /// A command fired, or a spoken cancel was accepted: light the teal glow.
    /// Called wherever `emitEarcon(.commandAck)` fires.
    func noteMatchedForFeedback() {
        matchedGlowStartedAt = now()
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
        guard VoiceCommandMatcher.hasContentTokens(normalized) else { return }
        guard normalized != lastUnmatchedGlowText else { return }
        if let last = lastUnmatchedGlowAt,
           now().timeIntervalSince(last) < unmatchedGlowCooldown { return }
        lastUnmatchedGlowAt = now()
        lastUnmatchedGlowText = normalized
        voiceFeedbackPhase = .unmatched
        scheduleGlowClear(after: unmatchedGlowDisplay)
    }

    /// The "action landed" signal, called on every applied quiz-state
    /// transition: once the screen visibly changed, the matched glow has done
    /// its job — clear it as soon as the min-display floor allows instead of
    /// holding the full max window.
    func noteQuizStateChangedForFeedback() {
        guard voiceFeedbackPhase == .matched, let startedAt = matchedGlowStartedAt else { return }
        let remaining = matchedGlowMinDisplay - now().timeIntervalSince(startedAt)
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
        guard voiceFeedbackPhase != .idle else { return }
        voiceFeedbackPhase = .idle
        matchedGlowStartedAt = nil
    }

    /// (Re)arm the single clear timer — re-adding under the same TaskKey
    /// cancels the previous timer, so the newest deadline always wins.
    private func scheduleGlowClear(after delay: TimeInterval) {
        // The seam is read (not reached through `self`) so the timer keeps its
        // weak-self semantics: a released coordinator still clears nothing.
        let sleep = glowSleep
        let task = Task { [weak self] in
            await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.clearFeedbackGlow()
        }
        taskBag.add(task, key: .voiceFeedbackGlow)
    }
}
