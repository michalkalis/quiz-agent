//
//  VoiceFeedbackGlowTests.swift
//  HangsTests
//
//  Issue #122 Track A — the ambient-glow feedback policy (Variant C). These
//  tests pin the locked variant-page answers: matched rides the same seam as
//  the `.commandAck` earcon; unmatched fires only for content-bearing FINALS,
//  at most once per cooldown, never twice in a row for the same transcript
//  (the mic is open through passenger conversation — an indicator that lights
//  on every sentence is itself the driving distraction); a matched glow honors
//  a min-display floor (no flash) and a max ceiling (no lying about a stuck
//  action). Fully clock- and timer-driven: `now` is a driven clock and the
//  glow clear timer's sleep is injected, so NO test here waits real time and
//  the assertions pin the shipped 2.0 s / 1.2 s windows (#133 audit).
//

import Foundation
@testable import Hangs
import Testing

/// Driven clock (same pattern as CommandListenerTests) — a reference box so
/// tests move "now" forward without a real `Task.sleep`.
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }
}

@Suite("Voice feedback glow (#122 Variant C)")
@MainActor
struct VoiceFeedbackGlowTests {
    /// - Parameter drivenGlowTimer: install the instant, recording clear-timer
    ///   seam. ONLY the two display-window tests want it — a timer that expires
    ///   the moment the test yields would clear the glow underneath the tests
    ///   that must observe it lit. Those keep the production timer, which cannot
    ///   fire inside their bodies (they never wait for it — the seam exists so
    ///   nothing in this suite waits out a real window).
    private func makeCoordinator(drivenGlowTimer: Bool = false)
        -> (QuizViewModel, VoiceCommandCoordinator, TestClock, SleepRecorder)
    {
        let vm = Fixtures.makeViewModel()
        let clock = TestClock()
        let timer = SleepRecorder()
        let coordinator = vm.voiceCommandCoordinator
        coordinator.now = { clock.now }
        // Installed before the first `await`, so no timer can already be armed
        // against the real clock.
        if drivenGlowTimer { coordinator.glowSleep = timer.sleep }
        return (vm, coordinator, clock, timer)
    }

    // MARK: - Matched

    @Test("A recognized command lights the matched glow (visual twin of the ack earcon)")
    func matchedLightsOnRecognizedCommand() async {
        let (vm, coordinator, _, _) = makeCoordinator()
        vm.quizState = .askingQuestion

        // End-to-end through the transcript path: a final "skip" matches on the
        // question screen and must light the glow via the fire seam.
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))

        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("Matched glow clears at the max-display ceiling even if no action lands")
    func matchedClearsAtMaxDisplay() async {
        let (_, coordinator, _, timer) = makeCoordinator(drivenGlowTimer: true)

        coordinator.noteMatchedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .matched)

        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle },
                        "matched glow must not outlive the max ceiling")
        #expect(
            timer.delays == [2.0],
            "the ceiling must be armed for the shipped max-display window — a stuck action may not keep claiming it was heard"
        )
    }

    @Test("Screen change clears a matched glow immediately once past the min floor")
    func screenChangePastFloorClears() {
        let (_, coordinator, clock, _) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        clock.now = clock.now.addingTimeInterval(0.7) // past the 0.6 s floor

        coordinator.noteQuizStateChangedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("Screen change before the min floor keeps the glow (no sub-200 ms flash)")
    func screenChangeBeforeFloorKeepsGlow() {
        let (_, coordinator, clock, _) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        clock.now = clock.now.addingTimeInterval(0.1) // well inside the floor

        coordinator.noteQuizStateChangedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("QuizViewModel.transition feeds the action-landed signal")
    func transitionWiring() {
        let (vm, coordinator, clock, _) = makeCoordinator()
        vm.quizState = .askingQuestion

        coordinator.noteMatchedForFeedback()
        clock.now = clock.now.addingTimeInterval(1.0)

        vm.transition(to: .recording)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    // MARK: - Unmatched throttle

    @Test("A content-bearing unmatched FINAL lights the amber glow")
    func unmatchedFinalLights() async {
        let (vm, coordinator, _, _) = makeCoordinator()
        vm.quizState = .askingQuestion

        await coordinator.handleCommandTranscript(
            CommandTranscript(text: "completely unrelated words", isFinal: true))

        #expect(coordinator.voiceFeedbackPhase == .unmatched)
    }

    @Test("A volatile hypothesis never lights the unmatched glow")
    func volatileNeverLights() {
        let (_, coordinator, _, _) = makeCoordinator()
        coordinator.noteUnmatchedForFeedback("some words", isFinal: false)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("A filler-only utterance never lights the unmatched glow")
    func fillerOnlyNeverLights() {
        let (_, coordinator, _, _) = makeCoordinator()
        coordinator.noteUnmatchedForFeedback("um uh hmm", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("Unmatched glow is throttled to once per cooldown")
    func cooldownThrottles() {
        let (_, coordinator, clock, _) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("first miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        coordinator.voiceFeedbackPhase = .idle // simulate the display expiring
        clock.now = clock.now.addingTimeInterval(1.0) // inside the 4 s cooldown
        coordinator.noteUnmatchedForFeedback("second miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)

        clock.now = clock.now.addingTimeInterval(4.0) // past the cooldown
        coordinator.noteUnmatchedForFeedback("third miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)
    }

    @Test("The same transcript never lights twice in a row")
    func sameTranscriptSuppressed() {
        let (_, coordinator, clock, _) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("same words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        coordinator.voiceFeedbackPhase = .idle
        clock.now = clock.now.addingTimeInterval(10) // far past the cooldown
        coordinator.noteUnmatchedForFeedback("same words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle) // identical → suppressed

        coordinator.noteUnmatchedForFeedback("different words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched) // different → allowed
    }

    @Test("A live matched glow outranks an unmatched candidate")
    func matchedOutranksUnmatched() {
        let (_, coordinator, _, _) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("Unmatched glow auto-clears after its fixed display window")
    func unmatchedAutoClears() async {
        let (_, coordinator, _, timer) = makeCoordinator(drivenGlowTimer: true)

        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle },
                        "unmatched glow must clear after its display window")
        #expect(
            timer.delays == [1.2],
            "one slow amber breath = the shipped unmatched window; a longer one would keep breathing through cabin talk"
        )
    }

    // MARK: - Reset

    @Test("reset() clears the glow but keeps the cooldown closed")
    func resetClearsGlowKeepsCooldown() {
        let (_, coordinator, clock, _) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        coordinator.reset()
        #expect(coordinator.voiceFeedbackPhase == .idle)

        // A reset must not re-open the throttle window.
        clock.now = clock.now.addingTimeInterval(1.0)
        coordinator.noteUnmatchedForFeedback("other words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }
}
