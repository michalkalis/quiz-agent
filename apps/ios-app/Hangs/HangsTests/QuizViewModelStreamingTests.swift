//
//  QuizViewModelStreamingTests.swift
//  HangsTests
//
//  Unit tests for the ElevenLabs streaming-STT path through QuizViewModel:
//  startRecording → startStreamingRecording → startSTTEventListener → handleCommittedTranscript
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) to make Task scheduling
//  deterministic. Per audit A2-5: confirmation OUTSIDE, withMainSerialExecutor INSIDE.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

/// Returns a ViewModel + mocks ready for streaming-STT tests.
/// Session and question are pre-seeded; quizState is .askingQuestion so
/// startRecording() can fire immediately and route to startStreamingRecording().
@MainActor
private func makeViewModelWithSTT()
    -> (QuizViewModel, MockNetworkService, MockAudioService, MockElevenLabsSTTService) {
    let mockNetwork = Fixtures.makeFullMockNetwork()
    let mockAudio = MockAudioService()
    let mockPersistence = MockPersistenceStore()
    let mockSTT = MockElevenLabsSTTService()

    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: mockAudio,
        persistenceStore: mockPersistence,
        silenceDetectionService: nil,
        sttService: mockSTT
    )

    // Seed the minimum state the streaming path needs.
    // currentSession.language is passed to sttService.connect(token:languageCode:).
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion

    return (viewModel, mockNetwork, mockAudio, mockSTT)
}

/// Yields until `predicate()` is true or the deadline elapses. Used instead of
/// fixed `Task.yield()` counts because the streaming path crosses actor →
/// AsyncStream → listener Task → @MainActor handler — too many hops for a
/// fixed yield count to pump deterministically. With `withMainSerialExecutor`
/// in scope this becomes a deterministic spin on the same executor.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 1_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
    }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

// MARK: - Suite

@Suite("QuizViewModel Streaming STT Tests")
@MainActor
struct QuizViewModelStreamingTests {

    // MARK: - Test 1: Happy connect

    /// Regression: prevents a refactor from skipping the WebSocket connect step or
    /// leaving isStreamingSTT=false after a successful connect, which would make the UI
    /// show a spinner instead of the live-transcript overlay while the user speaks.
    @Test("startRecording via streaming path sets isStreamingSTT=true and clears liveTranscript")
    func happyConnectSetsStreamingFlag() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, _) = makeViewModelWithSTT()

            // startRecording() calls transition(.recording) then routes to startStreamingRecording()
            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "isStreamingSTT never flipped true")

            #expect(viewModel.isStreamingSTT == true)
            #expect(viewModel.liveTranscript == "")
            #expect(viewModel.quizState == .recording)
        }
    }

    // MARK: - Test 2: Partial transcript updates liveTranscript

    /// Regression: ensures partialTranscript events drive liveTranscript in real time.
    /// If the event-listener Task is accidentally cancelled early or the switch case is
    /// removed, live words silently disappear from the driving UI.
    @Test("partialTranscript event updates liveTranscript while state stays .recording")
    func partialTranscriptUpdatesLiveTranscript() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.partialTranscript("Par..."))
            await waitUntil({ viewModel.liveTranscript == "Par..." }, "partial transcript never reached liveTranscript")

            #expect(viewModel.liveTranscript == "Par...")
            // A partial must never advance the state machine — only committed text does
            #expect(viewModel.quizState == .recording)
        }
    }

    // MARK: - Test 3: Committed transcript transitions to .processing

    /// Regression: if handleCommittedTranscript is accidentally disconnected from the
    /// event listener (e.g. wrong enum case), the user's final answer is silently lost
    /// and the confirmation sheet never appears.
    @Test("committedTranscript transitions to .processing and shows confirmation")
    func committedTranscriptTransitionsToProcessing() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.committedTranscript("Paris"))
            // handleCommittedTranscript transitions to .processing as its final step.
            await waitUntil({ viewModel.quizState == .processing }, "never reached .processing")

            #expect(viewModel.transcribedAnswer == "Paris")
            #expect(viewModel.showAnswerConfirmation == true)
            #expect(viewModel.isStreamingSTT == false)
            #expect(viewModel.quizState == .processing)
        }
    }

    // MARK: - Test 4: Disconnected event clears streaming flags

    /// Regression: if the .disconnected case handler (Recording.swift:143-150) is removed
    /// or the isStreamingSTT guard is inverted, isStreamingSTT stays true after an
    /// unexpected WebSocket drop and the live-transcript overlay stays visible forever.
    @Test("disconnected event while streaming clears isStreamingSTT and liveTranscript")
    func disconnectedEventClearsStreamingFlags() async throws {
        await withMainSerialExecutor {
            let (viewModel, _, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            // Establish a partial so we can verify liveTranscript is cleared too
            await mockSTT.injectEvent(.partialTranscript("Lon..."))
            await waitUntil({ viewModel.liveTranscript == "Lon..." }, "partial never propagated")
            #expect(viewModel.isStreamingSTT == true)

            struct FakeNetworkError: Error {}
            await mockSTT.injectEvent(.disconnected(FakeNetworkError()))
            await waitUntil({ !viewModel.isStreamingSTT }, "disconnected handler never ran")

            #expect(viewModel.isStreamingSTT == false)
            #expect(viewModel.liveTranscript == "")
        }
    }
}
