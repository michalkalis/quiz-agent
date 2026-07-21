//
//  SkipCancelWordTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free) — Session 4 carry-over wired in Session
//  5: the SPOKEN cancel path for the skip undo-window. While the question-screen
//  skip undo-window is open, a spoken cancel word ("stop"/"no", via
//  `VoiceCommandLexicon.isCancelWord`) aborts the pending skip — the spoken twin
//  of the tap-abort. After the window has expired (skip committed), a cancel word
//  has nothing to abort.
//
//  "stop" is NOT in the question screen's normal command set, so this path is
//  handled in `handleCommandTranscript` BEFORE the screen-scoped matcher.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeVM() -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
    vm.earconPlayer = MockEarconPlayer()
    return vm
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 6000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@Suite("Spoken cancel word aborts the skip undo-window (77.10 carry-over)")
@MainActor
struct SkipCancelWordTests {
    @Test("'stop' during an open undo-window aborts the pending skip")
    func stopAbortsOpenWindow() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10) // long window
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil)

            await vm.voiceCommandCoordinator.handleCommandTranscript("stop")

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "a spoken 'stop' must abort the pending skip")
            #expect(vm.quizState == .askingQuestion, "an aborted skip never leaves the question")
        }
    }

    @Test("'no' also aborts an open undo-window (cancel-word variant)")
    func noAbortsOpenWindow() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10)

            await vm.voiceCommandCoordinator.handleCommandTranscript("no")

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "'no' is a cancel-word variant and must abort")
            #expect(vm.quizState == .askingQuestion)
        }
    }

    @Test("a non-cancel utterance leaves the undo-window open")
    func nonCancelWordKeepsWindowOpen() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10)

            await vm.voiceCommandCoordinator.handleCommandTranscript("hello there")

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil, "only a cancel word may abort — not arbitrary speech")
        }
    }

    @Test("after the window expires the skip is committed; a later cancel word is inert")
    func cancelAfterExpiryIsInert() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 0.05) // short window → commits quickly

            await waitUntil({ vm.voiceCommandCoordinator.pendingSkipWindow == nil && vm.quizState != .askingQuestion },
                            "skip did not commit on undo-window expiry")
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "expiry commits the skip")

            // A cancel word now has no window to abort — it must be a harmless no-op.
            await vm.voiceCommandCoordinator.handleCommandTranscript("stop")
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil)
        }
    }

    /// #110 Bug 2: the expiry closure used to recheck only `pendingSkipWindow`,
    /// never `quizState` — so speaking/tapping during the window let expiry
    /// commit `skipQuestion()` mid-recording, leaving the streaming mic live
    /// into the result. Pinning the commit to `.askingQuestion` closes this.
    @Test("skip expiry during a recording in progress does not commit")
    func skipExpiryDuringRecordingDoesNotCommit() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 0.05) // short window → expires quickly
            vm.quizState = .recording // user started answering during the window

            await waitUntil({ vm.voiceCommandCoordinator.pendingSkipWindow == nil }, "expiry never fired")
            #expect(vm.quizState == .recording, "expiry must not commit skipQuestion mid-recording")
        }
    }

    /// #110 Bug 2 (cleanup): starting a voice answer supersedes any pending skip.
    @Test("startRecording cancels a pending skip window")
    func startRecordingCancelsPendingSkipWindow() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10) // long window — must not expire on its own
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil)

            await vm.recordingCoordinator.startRecording()

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "starting to answer must supersede a pending skip")
        }
    }

    /// #110 Bug 2 (cleanup): submitting an MCQ tap answer supersedes any pending skip.
    @Test("submitMCQAnswer cancels a pending skip window")
    func submitMCQCancelsPendingSkipWindow() async {
        await withMainSerialExecutor {
            let vm = makeVM()
            vm.quizState = .askingQuestion
            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10) // long window — must not expire on its own
            #expect(vm.voiceCommandCoordinator.pendingSkipWindow != nil)

            await vm.submitMCQAnswer(key: "a", value: "Test Answer")

            #expect(vm.voiceCommandCoordinator.pendingSkipWindow == nil, "submitting an MCQ answer must supersede a pending skip")
        }
    }
}
