//
//  RerecordDuringSubmitTests.swift
//  HangsTests
//
//  #133 V14. The driver rejects a recording ("again" / Re-record) while its
//  upload is still in flight — reachable because the command screen maps
//  `.processing` to `.confirmation`, so the spoken "again" is accepted mid-submit.
//
//  What is at stake is the graded answer, not the sheet: the stale submission's
//  completion used to set pendingResponse/transcribedAnswer and arm the 10-second
//  auto-confirm on top of the live re-record. If that countdown fired once the
//  re-record had reached `.processing`, the REJECTED answer was graded and the
//  re-recorded one dropped on the floor.
//

import Foundation
@testable import Hangs
import Testing

/// One-shot async gate: `wait()` suspends until `open()` is called. Holds the
/// mocked upload in flight deterministically — a wall-clock sleep has no ordering
/// guarantee against other MainActor work and flaked under full-suite contention.
private actor OneShotGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Spin until `predicate` holds (sync @MainActor state).
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    _ comment: Comment? = nil,
    timeoutMillis: Int = 5000,
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

/// Let a just-resumed completion run its (dropping) tail before asserting.
@MainActor
private func drainHops() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}

@Suite("Rerecord vs in-flight voice submit (#133 V14)")
@MainActor
struct RerecordDuringSubmitTests {
    /// Seeds a voice submit parked inside the upload, with the quiz in `.processing`.
    /// Returns the gate that releases the response.
    private func makeSubmitInFlight() async -> (QuizViewModel, MockNetworkService, OneShotGate, Task<Void, Never>) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.recordingCoordinator.transientBackoffOverride = { _ in .zero }
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        let gate = OneShotGate()
        network.submitVoiceAnswerGate = { await gate.wait() }

        let submit = Task { await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2])) }
        await waitUntil({ network.submitVoiceAnswerCallCount == 1 }, "the upload never reached the network")
        #expect(vm.quizState == .processing, "the submit owns .processing while it is in flight")
        return (vm, network, gate, submit)
    }

    /// Fix (a): `rerecordAnswer` must cancel the in-flight `.voiceSubmission` the way
    /// `cancelProcessing` already does — the recording it answers was just rejected.
    @Test("rerecord mid-submit cancels the in-flight voice submission")
    func rerecordCancelsInFlightSubmission() async throws {
        let (vm, _, gate, submit) = await makeSubmitInFlight()
        #expect(vm.taskBag.contains(.voiceSubmission), "the submit registers itself for cancellation")

        vm.recordingCoordinator.rerecordAnswer()

        #expect(
            vm.taskBag.contains(.voiceSubmission) == false,
            "the rejected recording's upload must not outlive the rerecord"
        )

        await gate.open()
        await submit.value
    }

    /// The end-to-end defect: after the rerecord, the rejected answer's response must
    /// not come back on screen, and above all must not arm auto-confirm — that is the
    /// path that graded the rejected answer instead of the re-recorded one.
    @Test("rerecord mid-submit drops the rejected answer's result instead of resurfacing it")
    func rerecordDropsStaleSubmitResult() async throws {
        let (vm, _, gate, submit) = await makeSubmitInFlight()

        vm.recordingCoordinator.rerecordAnswer()
        await waitUntil({ vm.quizState != .processing }, "rerecord never left the submit's state")

        await gate.open() // the rejected submission's response lands now
        await submit.value
        await drainHops()

        #expect(vm.showAnswerConfirmation == false, "the rejected transcript must not return to the screen")
        #expect(vm.recordingCoordinator.pendingResponse == nil, "a rejected response must never become confirmable")
        #expect(
            vm.taskBag.contains(.autoConfirm) == false,
            "auto-confirm over a live re-record is what graded the rejected answer"
        )
        #expect(vm.autoConfirmCountdown == 0)
        #expect(vm.quizState.isShowingResult == false, "nothing was confirmed, so nothing may be graded")
    }

    /// Fix (b) in isolation: the guard is on OWNERSHIP of `.processing`, not on task
    /// cancellation, so it also covers the window where the response already passed
    /// `Task.checkCancellation()` before the state moved (and any other route out of
    /// `.processing` — Cancel, skip).
    @Test("a submit result landing after the coordinator left .processing is dropped")
    func resultLandingAfterStateMovedIsDropped() async throws {
        let (vm, _, gate, submit) = await makeSubmitInFlight()

        // Leave .processing WITHOUT cancelling the task, so the completion really runs.
        vm.quizState = .askingQuestion

        await gate.open()
        await submit.value
        await drainHops()

        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.recordingCoordinator.pendingResponse == nil)
        #expect(vm.taskBag.contains(.autoConfirm) == false)
    }

    /// The other half of the guard: an uninterrupted submit must still land on the
    /// confirmation sheet with the transcript and an armed auto-confirm countdown.
    @Test("an uninterrupted submit still surfaces the confirmation sheet and arms auto-confirm")
    func normalSubmitStillConfirms() async throws {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.recordingCoordinator.transientBackoffOverride = { _ in .zero }
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))

        #expect(network.submitVoiceAnswerCallCount == 1)
        #expect(vm.showAnswerConfirmation, "the driver must still get the sheet on the normal path")
        #expect(vm.transcribedAnswer == "Test", "the sheet shows the evaluated transcript")
        #expect(vm.recordingCoordinator.pendingResponse != nil)
        #expect(vm.taskBag.contains(.autoConfirm), "hands-free confirmation still arms itself")
    }
}
