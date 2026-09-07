//
//  QuestionFooterInspectorTests.swift
//  HangsTests
//
//  #131 Tracks B + C — the voice-answer question screen's footer, rebuilt after
//  the founder's 2026-07-29 TestFlight session:
//
//   B. ONE countdown from the end of the question read to submit or expiry, living
//      in the Record/Stop button. The THINK chip is gone; nothing the driver does
//      may blank the number.
//   C. Footer row = Record · Type · Skip; while recording the screen shows the
//      transcript card as its listening surface, not a second pink bar.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("QuestionView footer — countdown, row order, recording surface (#131)")
@MainActor
struct QuestionFooterInspectorTests {
    private func makeVoiceViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.preview // .text → voice body
        vm.quizState = .askingQuestion
        return vm
    }

    // MARK: - Track B: one countdown, in the button

    /// The founder's rule after the field test: the countdown must survive the
    /// switch into recording. It used to be cancelled with the think timer and the
    /// screen went numberless the instant the mic opened — which is exactly when a
    /// driver most needs to know how long they have. `answerWindowRemaining` is the
    /// single value the button renders; it must be non-zero on BOTH sides of the
    /// transition.
    @Test("the countdown survives the start of recording")
    func countdownSurvivesRecordStart() async throws {
        let vm = makeVoiceViewModel()
        vm.settings.thinkingTime = 10
        vm.thinkingTimeCountdown = 7
        #expect(vm.answerWindowRemaining == 7, "thinking window is what the button shows while idle")
        #expect(vm.answerWindowTotal == 10)

        await vm.toggleRecording() // manual Record tap

        #expect(vm.quizState == .recording)
        #expect(vm.answerWindowRemaining > 0, "the number must NOT blank when the mic opens")
        #expect(vm.answerWindowTotal > 0, "…and the button's fill must still have a window to drain")
    }

    /// The chip that used to carry it is gone from the voice screen — if it comes
    /// back the driver has two competing countdowns again.
    @Test("no THINK chip on the voice screen")
    func noThinkChipOnVoiceScreen() async throws {
        let vm = makeVoiceViewModel()
        vm.thinkingTimeCountdown = 8
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "THINK")
            }
        }
    }

    /// Expiry mid-recording stops the mic and submits what was heard, rather than
    /// silently leaving a recording running past its window.
    @Test("the recording window auto-stops and submits when it expires")
    func recordingWindowExpiryStopsAndSubmits() async throws {
        let (vm, _) = Fixtures.makeViewModelWithAudio()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .recording

        vm.quizTimersController.startAutoStopRecordingTimer(duration: 0.05)
        #expect(vm.recordingCountdown > 0, "the window is published the moment it is armed")

        for _ in 0 ..< 200 where vm.quizState == .recording {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(vm.quizState != .recording, "expiry must stop the recording, not just hide the number")
    }

    // MARK: - Track C: footer row order

    /// Founder-specified order. Asserted by relative index inside the row so a
    /// re-shuffle is caught, not just presence. #171 Track C1: the order is read
    /// off the accessibility identifiers now — Type and Skip no longer render a
    /// visible word to sort by.
    @Test("footer row reads Record · Type · Skip")
    func footerRowOrder() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let expected = ["question.record", "question.textInputToggle", "question.skip"]
            // All three present…
            for id in expected {
                #expect(throws: Never.self, "\(id) missing from the footer") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            // …and in the founder's order. `findAll` walks the tree in render
            // order, so the identifiers' relative positions are the row's order.
            let order = tree.findAll(where: { view in
                guard let id = try? view.accessibilityIdentifier() else { return false }
                return expected.contains(id)
            }).compactMap { try? $0.accessibilityIdentifier() }
            #expect(order == expected, "footer order drifted: \(order)")
        }
    }

    /// #171 Track C1 (founder, 2026-09-05 TestFlight): in Slovak the row's three
    /// words ("Nahrávať · Písať · Preskočiť") left the Record button too little
    /// width and its seconds pill — the one number a driver needs — was clipped.
    /// Type and Skip are icon-only now, so the row costs the same in every
    /// language. The words must be gone from the screen but NOT from VoiceOver.
    @Test("Type and Skip are icon-only, keeping their words as accessibility labels")
    func typeAndSkipAreIconOnly() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let visible = tree.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            #expect(!visible.contains("Type"), "the word 'Type' is what stole the Record button's width")
            #expect(!visible.contains("Skip"), "the word 'Skip' is what stole the Record button's width")
            #expect(visible.contains("Record"), "the primary button keeps its label")

            for (id, label) in [("question.textInputToggle", "Type"), ("question.skip", "Skip")] {
                let button = try tree.find(viewWithAccessibilityIdentifier: id)
                #expect(try button.accessibilityLabel().string() == label,
                        "\(id) must still announce '\(label)' to VoiceOver")
            }
        }
    }

    // MARK: - Track C: the recording surface

    /// The pink "LISTENING — SAY YOUR ANSWER" bar and the transcript card said the
    /// same thing twice while recording. The card won: it is where the words the
    /// driver just said actually appear, so it carries the listening affordance and
    /// the separate answer bar is gone.
    @Test("recording shows the transcript card and no docked answer bar")
    func recordingShowsTranscriptCardNotBar() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .recording
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.liveTranscript")
            }
            #expect(throws: (any Error).self, "the duplicate pink answer bar must be gone") {
                _ = try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }

    /// It must appear on the FIRST frame of recording. Gating it on the first STT
    /// partial (the old `isRecording && isStreamingSTT`) left a silent gap where
    /// the mic was live and the screen showed nothing about it — and on the batch
    /// recording path it never appeared at all.
    @Test("the recording surface appears before any transcript text streams in")
    func transcriptCardAppearsImmediately() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .recording
        vm.recordingCoordinator.isStreamingSTT = false // batch path, nothing streamed yet
        vm.recordingCoordinator.liveTranscript = ""
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.liveTranscript")
            }
            #expect(throws: Never.self, "and it says what to do") {
                try tree.find(text: "LISTENING — SAY YOUR ANSWER")
            }
        }
    }

    /// The command bar keeps its slot while idle — and now names the words.
    @Test("the command bar carries the concrete commands sub-line")
    func commandBarShowsCommands() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: nil
        )
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.commandListenerHint != nil, "precondition: a command window must be armed")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
        }
    }
}
