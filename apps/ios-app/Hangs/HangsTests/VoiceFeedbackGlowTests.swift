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
//  action). Fully clock-driven (#180 track A): the coordinator runs on an
//  injected `TestClock`, so NO test here waits real time and the display
//  windows are pinned by advancing to just BEFORE the shipped 2.0 s / 1.2 s
//  boundary (glow still lit) and then past it (#133 audit).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Voice feedback glow (#122 Variant C)")
@MainActor
struct VoiceFeedbackGlowTests {
    /// The coordinator's clock IS the returned `TestClock`: the glow clear
    /// timer sleeps on it, so it can only expire when a test advances it — the
    /// tests that must observe a lit glow simply never advance that far.
    private func makeCoordinator() -> (QuizViewModel, VoiceCommandCoordinator, TestClock<Duration>) {
        let clock = TestClock()
        let vm = Fixtures.makeViewModel(clock: AnyClock(clock))
        return (vm, vm.voiceCommandCoordinator, clock)
    }

    // MARK: - Matched

    @Test("A recognized command lights the matched glow (visual twin of the ack earcon)")
    func matchedLightsOnRecognizedCommand() async {
        let (vm, coordinator, _) = makeCoordinator()
        vm.quizState = .askingQuestion

        // End-to-end through the transcript path: a final "skip" matches on the
        // question screen and must light the glow via the fire seam.
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))

        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("Matched glow clears at the max-display ceiling even if no action lands")
    func matchedClearsAtMaxDisplay() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .matched)

        await Task.yield() // let the clear timer reach its sleep
        await clock.advance(by: .milliseconds(1990)) // just inside the shipped 2.0 s ceiling
        #expect(
            coordinator.voiceFeedbackPhase == .matched,
            "the ceiling is the shipped max-display window — clearing earlier would flash the ack away"
        )

        await clock.advance(by: .milliseconds(11)) // …and past it (integer ms: a fractional Duration can land 1 as short of the boundary)
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle },
                        "matched glow must not outlive the max ceiling — a stuck action may not keep claiming it was heard")
    }

    @Test("Screen change clears a matched glow immediately once past the min floor")
    func screenChangePastFloorClears() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        await clock.advance(by: .seconds(0.7)) // past the 0.6 s floor

        coordinator.noteQuizStateChangedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("Screen change before the min floor keeps the glow (no sub-200 ms flash)")
    func screenChangeBeforeFloorKeepsGlow() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        await clock.advance(by: .seconds(0.1)) // well inside the floor

        coordinator.noteQuizStateChangedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("QuizViewModel.transition feeds the action-landed signal")
    func transitionWiring() async {
        let (vm, coordinator, clock) = makeCoordinator()
        vm.quizState = .askingQuestion

        coordinator.noteMatchedForFeedback()
        await clock.advance(by: .seconds(1.0))

        vm.transition(to: .recording)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    // MARK: - Unmatched throttle

    @Test("A content-bearing unmatched FINAL lights the amber glow")
    func unmatchedFinalLights() async {
        let (vm, coordinator, _) = makeCoordinator()
        vm.quizState = .askingQuestion

        await coordinator.handleCommandTranscript(
            CommandTranscript(text: "completely unrelated words", isFinal: true))

        #expect(coordinator.voiceFeedbackPhase == .unmatched)
    }

    @Test("A volatile hypothesis never lights the unmatched glow")
    func volatileNeverLights() {
        let (_, coordinator, _) = makeCoordinator()
        coordinator.noteUnmatchedForFeedback("some words", isFinal: false)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("A filler-only utterance never lights the unmatched glow")
    func fillerOnlyNeverLights() {
        let (_, coordinator, _) = makeCoordinator()
        coordinator.noteUnmatchedForFeedback("um uh hmm", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("Unmatched glow is throttled to once per cooldown")
    func cooldownThrottles() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("first miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        coordinator.voiceFeedbackPhase = .idle // simulate the display expiring
        await clock.advance(by: .seconds(1.0)) // inside the 4 s cooldown
        coordinator.noteUnmatchedForFeedback("second miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)

        await clock.advance(by: .seconds(4.0)) // past the cooldown
        coordinator.noteUnmatchedForFeedback("third miss", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)
    }

    @Test("The same transcript never lights twice in a row")
    func sameTranscriptSuppressed() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("same words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        coordinator.voiceFeedbackPhase = .idle
        await clock.advance(by: .seconds(10)) // far past the cooldown
        coordinator.noteUnmatchedForFeedback("same words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle) // identical → suppressed

        coordinator.noteUnmatchedForFeedback("different words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched) // different → allowed
    }

    @Test("A live matched glow outranks an unmatched candidate")
    func matchedOutranksUnmatched() {
        let (_, coordinator, _) = makeCoordinator()

        coordinator.noteMatchedForFeedback()
        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("Unmatched glow auto-clears after its fixed display window")
    func unmatchedAutoClears() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)

        await Task.yield() // let the clear timer reach its sleep
        await clock.advance(by: .milliseconds(1190)) // just inside the shipped 1.2 s window
        #expect(
            coordinator.voiceFeedbackPhase == .unmatched,
            "one slow amber breath = the shipped unmatched window; a shorter one would be a flicker"
        )

        await clock.advance(by: .milliseconds(11)) // …and past it (integer ms: a fractional Duration can land 1 as short of the boundary)
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle },
                        "unmatched glow must clear after its display window — a longer one would keep breathing through cabin talk")
    }

    // MARK: - Reset

    @Test("reset() clears the glow but keeps the cooldown closed")
    func resetClearsGlowKeepsCooldown() async {
        let (_, coordinator, clock) = makeCoordinator()

        coordinator.noteUnmatchedForFeedback("some words", isFinal: true)
        coordinator.reset()
        #expect(coordinator.voiceFeedbackPhase == .idle)

        // A reset must not re-open the throttle window.
        await clock.advance(by: .seconds(1.0))
        coordinator.noteUnmatchedForFeedback("other words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }
}
