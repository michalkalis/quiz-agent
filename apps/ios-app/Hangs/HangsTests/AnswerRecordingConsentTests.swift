//
//  AnswerRecordingConsentTests.swift
//  HangsTests
//
//  #197 (founder 2026-10-10): every beta tester is asked once whether their
//  answer recordings may go to the developer. What is protected: (1) an App
//  Store build never asks and never records or uploads, even if a TestFlight
//  install left the switch on; (2) No means nothing ever leaves the phone;
//  (3) the question is asked once, never again whatever the answer; (4) a
//  recording the server refuses for good is dropped, so phones don't pile up
//  files; a refusal that can pass later keeps it.
//

import Foundation
@testable import Hangs
import Testing

private actor RefusingServer: VoiceSampleUploading {
    var received: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func uploadVoiceSample(stamp: String, wav _: Data, sidecarJSON _: Data) async throws {
        received.append(stamp)
        if let error { throw error }
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AnswerRecordingConsentTests-\(UUID().uuidString)", isDirectory: true)
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

/// Runs `body` on a clean consent state and restores the real flags after,
/// so the global pipeline state other suites read is untouched.
private func withCleanConsentState(_ body: () async -> Void) async {
    let keys = [AnswerRecordingConsent.askedKey, VoicePipelineFlags.Key.saveAnswerRecordings]
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    await body()
    for (key, value) in zip(keys, saved) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

@Suite("#197 beta consent for answer recordings", .serialized)
struct AnswerRecordingConsentTests {
    @Test("an App Store build never asks and never records or uploads, even with the switch left on")
    func appStoreBuildNeverAsksNorUploads() async {
        await withCleanConsentState {
            #expect(!AnswerRecordingConsent.shouldAsk(channelAllows: false))

            // A TestFlight install that said Yes, then replaced by the App Store build.
            AnswerRecordingConsent.record(consented: true)
            #expect(!VoicePipelineFlags.saveAnswerRecordings(channelAllows: false))

            let dir = tempDir()
            defer { AnswerRecordingStore.deleteAll(directory: dir) }
            let sidecar = AnswerRecordingStore.Sidecar(
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "sk",
                inputPort: "MicrophoneBuiltIn", voiceProcessing: false, sampleRate: 16000,
                durationMs: 900, questionId: nil
            )
            let stamp = AnswerRecordingStore.save(
                wav: Data(count: 44), sidecar: sidecar,
                enabled: VoicePipelineFlags.saveAnswerRecordings(channelAllows: false), directory: dir
            )
            #expect(stamp == nil, "nothing is recorded")

            saveRecording(at: 1_700_000_000, in: dir) // a leftover from the TestFlight install
            let server = RefusingServer()
            await AnswerRecordingUploader(
                transport: server, directory: dir,
                isEnabled: { VoicePipelineFlags.saveAnswerRecordings(channelAllows: false) }
            ).uploadPending()
            #expect(await server.received.isEmpty, "nothing is uploaded")
        }
    }

    @Test("a beta tester is asked once; Yes turns the switch on and the question never returns")
    func yesEnablesAndIsAskedOnce() async {
        await withCleanConsentState {
            #expect(AnswerRecordingConsent.shouldAsk(channelAllows: true))
            AnswerRecordingConsent.record(consented: true)
            #expect(VoicePipelineFlags.saveAnswerRecordings(channelAllows: true))
            #expect(!AnswerRecordingConsent.shouldAsk(channelAllows: true))
        }
    }

    @Test("No keeps the switch off, nothing is ever uploaded, and the question never returns")
    func noNeverUploads() async {
        await withCleanConsentState {
            AnswerRecordingConsent.record(consented: false)
            #expect(!AnswerRecordingConsent.shouldAsk(channelAllows: true))
            #expect(!VoicePipelineFlags.saveAnswerRecordings(channelAllows: true))

            let dir = tempDir()
            defer { AnswerRecordingStore.deleteAll(directory: dir) }
            saveRecording(at: 1_700_000_000, in: dir)
            let server = RefusingServer()
            await AnswerRecordingUploader(
                transport: server, directory: dir,
                isEnabled: { VoicePipelineFlags.saveAnswerRecordings(channelAllows: true) }
            ).uploadPending()
            #expect(await server.received.isEmpty)
        }
    }

    @Test("a tester who already turned the switch on by hand is not asked")
    func switchAlreadyOnIsNotAsked() async {
        await withCleanConsentState {
            VoicePipelineFlags.saveAnswerRecordings = true
            #expect(!AnswerRecordingConsent.shouldAsk(channelAllows: true))
        }
    }
}

@Suite("#197 permanent upload refusals")
struct AnswerRecordingRefusalTests {
    @Test("a permanent 4xx drops the recording and stops the pass", arguments: [400, 403, 413, 415])
    func permanentRefusalDropsTheFile(status: Int) async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let first = saveRecording(at: 1_700_000_000, in: dir)
        let second = saveRecording(at: 1_700_000_100, in: dir)
        let server = RefusingServer(error: NetworkError.serverError(statusCode: status, message: "refused"))

        await AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true }).uploadPending()

        #expect(await server.received == [first], "stops after the refusal")
        #expect(AnswerRecordingStore.completeStamps(directory: dir) == [second], "the refused one is gone, the next waits")
    }

    @Test("a refusal that can pass later keeps the recording", arguments: [401, 408, 429, 500, 503])
    func temporaryRefusalKeepsTheFile(status: Int) async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let stamp = saveRecording(at: 1_700_000_000, in: dir)
        let server = RefusingServer(error: NetworkError.serverError(statusCode: status, message: "later"))

        await AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true }).uploadPending()

        #expect(AnswerRecordingStore.completeStamps(directory: dir) == [stamp])
    }

    @Test("offline keeps the recording")
    func offlineKeepsTheFile() async {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }
        let stamp = saveRecording(at: 1_700_000_000, in: dir)
        let server = RefusingServer(error: URLError(.notConnectedToInternet))

        await AnswerRecordingUploader(transport: server, directory: dir, isEnabled: { true }).uploadPending()

        #expect(AnswerRecordingStore.completeStamps(directory: dir) == [stamp])
    }
}
