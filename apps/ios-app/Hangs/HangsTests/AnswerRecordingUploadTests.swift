//
//  AnswerRecordingUploadTests.swift
//  HangsTests
//
//  #197 — car answer recordings go to the backend for replay tests. What is
//  protected: (1) gameplay never waits on the upload — a dead network while
//  driving must not hold the answer sheet; (2) a recording leaves the phone
//  only once the server has it (deleted after a 2xx, kept otherwise, retried
//  on the next kick); (3) nothing is sent while the switch is off; (4) the
//  sidecar carries the app's decision the replay is scored against.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

/// A server that records each call and, when gated, holds it until released.
private actor FakeVoiceSampleServer: VoiceSampleUploading {
    var received: [String] = []
    var failing: Set<String> = []
    private var gated: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(gated: Bool = false) {
        self.gated = gated
    }

    func fail(_ stamp: String) {
        failing.insert(stamp)
    }

    func release() {
        gated = false
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func uploadVoiceSample(stamp: String, wav _: Data, sidecarJSON _: Data) async throws {
        received.append(stamp)
        if gated { await withCheckedContinuation { waiters.append($0) } }
        if failing.contains(stamp) { throw URLError(.notConnectedToInternet) }
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AnswerRecordingUploadTests-\(UUID().uuidString)", isDirectory: true)
}

@discardableResult
private func saveRecording(at seconds: TimeInterval, in dir: URL) -> String {
    let sidecar = AnswerRecordingStore.Sidecar(
        recordedAt: Date(timeIntervalSince1970: seconds),
        language: "sk", inputPort: "MicrophoneBuiltIn", voiceProcessing: false,
        sampleRate: 16000, durationMs: 900, questionId: "q_001"
    )
    return AnswerRecordingStore.save(wav: Data(count: 44), sidecar: sidecar, enabled: true, directory: dir)!
}

@Suite("#197 answer recording upload")
struct AnswerRecordingUploaderTests {
    @Test("a sent recording is deleted; one the server did not take stays for the next try")
    func deletesOnlyAfterSuccess() async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let first = saveRecording(at: 1_700_000_000, in: dir)
        let second = saveRecording(at: 1_700_000_100, in: dir)
        let server = FakeVoiceSampleServer()
        await server.fail(second)

        let uploader = AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true })
        await uploader.uploadPending()

        #expect(await server.received == [first, second], "oldest first")
        #expect(AnswerRecordingStore.completeStamps(directory: dir) == [second], "the failed one must survive for a retry")
    }

    @Test("with the switch off nothing leaves the phone")
    func disabledSendsNothing() async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        saveRecording(at: 1_700_000_000, in: dir)
        let server = FakeVoiceSampleServer()

        await AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { false }).uploadPending()

        #expect(await server.received.isEmpty)
        #expect(AnswerRecordingStore.recordingCount(directory: dir) == 1)
    }

    @Test("a WAV whose sidecar is missing is not sent")
    func incompletePairIsSkipped() async throws {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let stamp = saveRecording(at: 1_700_000_000, in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(stamp).json"))
        let server = FakeVoiceSampleServer()

        await AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true }).uploadPending()

        #expect(await server.received.isEmpty)
    }

    @Test("the decision and the served answer land in the sidecar the replay reads")
    func outcomeIsRecorded() throws {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let stamp = saveRecording(at: 1_700_000_000, in: dir)

        AnswerRecordingStore.recordOutcome(
            .init(decision: "incorrect", transcript: "Jupiter", correctAnswer: "Saturn"),
            to: stamp, directory: dir
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(
            AnswerRecordingStore.Sidecar.self,
            from: Data(contentsOf: dir.appendingPathComponent("\(stamp).json"))
        )
        #expect(sidecar.appDecision == "incorrect")
        #expect(sidecar.transcript == "Jupiter")
        #expect(sidecar.correctAnswer == "Saturn")
        #expect(sidecar.questionId == "q_001", "the save-time context must survive the update")
    }
}

@Suite("#197 upload never blocks gameplay")
@MainActor
struct AnswerRecordingUploadGameplayTests {
    /// WHY: in the car the upload runs on a flaky mobile link. If the answer
    /// path awaited it, a stalled upload would freeze the confirmation sheet.
    @Test("a stalled upload does not hold the voice answer: the sheet opens while the upload is still in flight")
    func stalledUploadDoesNotBlockSubmission() async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        saveRecording(at: 1_700_000_000, in: dir)
        let server = FakeVoiceSampleServer(gated: true)
        let uploader = AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true })
        let viewModel = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock()),
            answerRecordingUploader: uploader
        )
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        viewModel.quizState = .askingQuestion
        viewModel.recordingCoordinator.savedRecordingStamp = "20231114-221320-000"

        await viewModel.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]), fileName: "answer.wav")

        #expect(viewModel.showAnswerConfirmation, "the answer reached the sheet without waiting for the upload")
        await pumpUntilUploadStarted(server)
        #expect(AnswerRecordingStore.recordingCount(directory: dir) == 1, "still in flight, so not deleted yet")

        await server.release()
    }

    private func pumpUntilUploadStarted(_ server: FakeVoiceSampleServer) async {
        for _ in 0 ..< 500 {
            if await !server.received.isEmpty { return }
            await Task.yield()
        }
        Issue.record("the decided recording never kicked the uploader")
    }
}
