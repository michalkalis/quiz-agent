//
//  FeedbackViewModelTests.swift
//  HangsTests
//
//  #109 in-app beta feedback (phase 2 — typing only). These tests encode WHY the
//  behaviour matters:
//  - A blank/whitespace note must never POST — the backend requires `message`
//    and a spinner on an empty report strands the tester.
//  - The message is TRIMMED before send: leading/trailing whitespace the editor
//    accumulates must not become the payload.
//  - A network failure must surface as `.failed(reason)` (visible), not a silent
//    swallow that looks like a successful send.
//  - Removing the screenshot must actually drop it from the payload — the tester
//    tapped remove because the shot was irrelevant or sensitive.
//  - The metadata JSON must carry the captured screen state (quiz_state,
//    session_id, quiz_language, audio_mode) so a report is debuggable.
//

import Foundation
import Testing
import UIKit
@testable import Hangs

@MainActor
private func makeFeedbackViewModel(
    network: MockNetworkService = MockNetworkService(),
    context: FeedbackContext = FeedbackContext(
        quizState: "recording",
        sessionId: "sess-123",
        quizLanguage: "sk",
        audioMode: "call"
    ),
    screenshot: UIImage? = nil,
    logs: String? = "test logs"
) -> FeedbackViewModel {
    FeedbackViewModel(
        networkService: network,
        context: context,
        screenshot: screenshot,
        logsProvider: { logs }
    )
}

private func makeImage() -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
    return renderer.image { ctx in
        UIColor.red.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
}

@MainActor
@Suite("FeedbackViewModel")
struct FeedbackViewModelTests {

    // MARK: - Send gating

    @Test("empty message cannot send — backend requires a non-empty note")
    func emptyMessageBlocksSend() async {
        let network = MockNetworkService()
        let vm = makeFeedbackViewModel(network: network)
        vm.message = "   \n  "
        #expect(!vm.canSend)
        await vm.send()
        #expect(network.submitFeedbackCallCount == 0)
        #expect(vm.sendState == .idle)
    }

    @Test("non-empty message enables send")
    func nonEmptyMessageEnablesSend() {
        let vm = makeFeedbackViewModel()
        vm.message = "the score readout was cut off"
        #expect(vm.canSend)
    }

    // MARK: - Happy path

    @Test("successful send transitions to .success and POSTs the trimmed message")
    func successfulSend() async {
        let network = MockNetworkService()
        let vm = makeFeedbackViewModel(network: network)
        vm.message = "  auto-record didn't re-arm after skip  "

        await vm.send()

        #expect(vm.sendState == .success)
        #expect(network.submitFeedbackCallCount == 1)
        #expect(network.capturedFeedbackMessage == "auto-record didn't re-arm after skip")
        #expect(network.capturedFeedbackLogs == "test logs")
    }

    @Test("screenshot is attached as PNG bytes when present")
    func screenshotAttached() async {
        let network = MockNetworkService()
        let vm = makeFeedbackViewModel(network: network, screenshot: makeImage())
        vm.message = "layout bug"

        await vm.send()

        #expect(network.capturedFeedbackScreenshot != nil)
        #expect((network.capturedFeedbackScreenshot?.count ?? 0) > 0)
    }

    // MARK: - Screenshot removal

    @Test("removing the screenshot drops it from the payload")
    func screenshotRemovalDropsAttachment() async {
        let network = MockNetworkService()
        let vm = makeFeedbackViewModel(network: network, screenshot: makeImage())
        vm.message = "no shot needed"

        vm.removeScreenshot()
        #expect(vm.screenshot == nil)

        await vm.send()
        #expect(network.capturedFeedbackScreenshot == nil)
    }

    // MARK: - Failure

    @Test("a network failure surfaces as .failed, not a silent success")
    func networkFailureSurfaces() async {
        let network = MockNetworkService()
        network.feedbackError = NetworkError.serverError(statusCode: 500, message: "boom")
        let vm = makeFeedbackViewModel(network: network)
        vm.message = "this should fail"

        await vm.send()

        #expect(network.submitFeedbackCallCount == 1)
        if case .failed = vm.sendState {
            // expected
        } else {
            Issue.record("expected .failed, got \(vm.sendState)")
        }
        #expect(vm.errorMessage != nil)
    }

    // MARK: - Metadata

    @Test("metadata carries the captured screen state")
    func metadataContainsScreenState() {
        let vm = makeFeedbackViewModel(
            context: FeedbackContext(
                quizState: "recording",
                sessionId: "sess-123",
                quizLanguage: "sk",
                audioMode: "call"
            )
        )
        let metadata = vm.buildMetadata()

        #expect(metadata["quiz_state"] == "recording")
        #expect(metadata["session_id"] == "sess-123")
        #expect(metadata["quiz_language"] == "sk")
        #expect(metadata["audio_mode"] == "call")
        #expect(metadata["ios_version"] != nil)
        #expect(metadata["device_model"] != nil)
        #expect(metadata["environment"] != nil)
        #expect(metadata["locale"] != nil)
    }

    @Test("no active session → metadata omits session_id rather than sending null")
    func metadataOmitsSessionWhenAbsent() {
        let vm = makeFeedbackViewModel(
            context: FeedbackContext(
                quizState: "idle",
                sessionId: nil,
                quizLanguage: "en",
                audioMode: "media"
            )
        )
        #expect(vm.buildMetadata()["session_id"] == nil)
    }

    @Test("the sent metadata JSON round-trips the captured screen state")
    func sentMetadataJSONRoundTrips() async throws {
        let network = MockNetworkService()
        let vm = makeFeedbackViewModel(network: network)
        vm.message = "check metadata"

        await vm.send()

        let json = try #require(network.capturedFeedbackMetadataJSON)
        let data = try #require(json.data(using: .utf8))
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(parsed["quiz_state"] == "recording")
        #expect(parsed["session_id"] == "sess-123")
        #expect(parsed["audio_mode"] == "call")
    }
}
