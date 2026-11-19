//
//  NetworkConditionTests.swift
//  HangsTests
//
//  #235.1 (a "bad network" switch for tests). Two bugs reached TestFlight
//  because every test ran on a server that answers at once and correctly.
//  The mock's network conditions are only worth having if each one looks to
//  the caller exactly like the real NetworkService on that network: the same
//  error, the same transient/permanent classification (that decides whether
//  the start retries or shows the error screen), and the wait on the injected
//  clock, never on real time.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

/// What one in-flight mock call has done so far, read between clock steps.
@MainActor
private final class CallOutcome {
    private(set) var response: QuizResponse?
    private(set) var error: Error?
    var finished: Bool { response != nil || error != nil }

    static func start(_ call: @escaping @MainActor () async throws -> QuizResponse) -> CallOutcome {
        let outcome = CallOutcome()
        Task { @MainActor in
            do { outcome.response = try await call() } catch { outcome.error = error }
        }
        return outcome
    }

    var urlErrorCode: URLError.Code? { (error as? URLError)?.code }
}

@Suite("Bad network on the mock (#235.1)")
@MainActor
struct NetworkConditionTests {
    private func makeNetwork(
        _ condition: NetworkCondition?,
        for calls: [MockNetworkCall] = MockNetworkCall.allCases
    ) -> (MockNetworkService, TestClock<Duration>) {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        network.setNetworkCondition(condition, for: calls)
        return (network, clock)
    }

    private func startQuiz(_ network: MockNetworkService) -> CallOutcome {
        CallOutcome.start { try await network.startQuiz(sessionId: "s", excludedQuestionIds: []) }
    }

    // WHY: the founder's tab bug only exists while the start is in flight. A
    // slow call must stay pending for its whole delay and then answer
    // normally, so a test can act inside that window.
    @Test("slow: pending for the whole delay, then the normal answer")
    func slowAnswersAfterDelay() async {
        let (network, clock) = makeNetwork(.slow(.seconds(5)))
        let call = startQuiz(network)
        await pumpUntil({ network.capturedStartQuizExcludedIds != nil }, "the call never reached the mock")

        await clock.advance(by: .milliseconds(4999))
        #expect(!call.finished, "a slow call answered before its delay")
        await clock.advance(by: .milliseconds(1))
        await pumpUntil { call.finished }

        #expect(call.response?.currentQuestion?.id == "q_002")
    }

    // WHY: on device a request that never answers ends with URLSession's
    // timeout, which the start path retries as transient. Only the request
    // timeout may end it, not anything sooner.
    @Test("timeout: nothing until the request timeout, then URLError.timedOut (transient)")
    func timeoutSurfacesTimedOut() async {
        let (network, clock) = makeNetwork(.timeout)
        let call = startQuiz(network)
        await pumpUntil { network.capturedStartQuizExcludedIds != nil }

        await clock.advance(by: NetworkCondition.requestTimeout - .milliseconds(1))
        #expect(!call.finished, "a timed-out call gave up before the request timeout")
        await clock.advance(by: .milliseconds(1))
        await pumpUntil { call.finished }

        #expect(call.urlErrorCode == .timedOut)
        #expect(TransientRetry.isTransient(call.error!))
    }

    // WHY: offline fails at once on device; a test must see that without
    // moving the clock, or it would be modelling a slow network instead.
    @Test("offline: fails at once with URLError.notConnectedToInternet")
    func offlineFailsAtOnce() async {
        let (network, _) = makeNetwork(.offline)
        let call = startQuiz(network)
        await pumpUntil { call.finished }

        #expect(call.urlErrorCode == .notConnectedToInternet)
    }

    // WHY: a dropped connection fails AFTER the request reached the server
    // (it may have acted on it), which is what makes retries risky.
    @Test("dropped: the request is recorded, then URLError.networkConnectionLost after the delay")
    func droppedLosesConnectionMidRequest() async {
        let (network, clock) = makeNetwork(.dropped(after: .seconds(2)))
        let call = CallOutcome.start {
            _ = try await network.createSession(
                maxQuestions: 5, difficulty: "medium", language: "en", categories: [], userId: nil,
                includeImages: false, skipLocalQuestions: false, packId: nil, ageBand: nil
            )
            return QuizResponse.previewStartQuiz
        }
        await pumpUntil { network.createSessionCallCount == 1 }

        await clock.advance(by: .milliseconds(1999))
        #expect(!call.finished)
        await clock.advance(by: .milliseconds(1))
        await pumpUntil { call.finished }

        #expect(call.urlErrorCode == .networkConnectionLost)
    }

    // WHY: the retry decision hangs on the status code: a waking machine's
    // 502-504 is retried, any other 5xx goes straight to the error screen.
    @Test("server error: NetworkError.serverError with the status the retry classifies", arguments: [
        (500, false), (503, true),
    ])
    func serverErrorCarriesStatus(statusCode: Int, transient: Bool) async throws {
        let (network, _) = makeNetwork(.serverError(statusCode: statusCode))
        let call = startQuiz(network)
        await pumpUntil { call.finished }

        let error = try #require(call.error)
        guard case let .serverError(code, _)? = error as? NetworkError else {
            Issue.record("expected NetworkError.serverError, got \(error)")
            return
        }
        #expect(code == statusCode)
        #expect(TransientRetry.isTransient(error) == transient)
    }

    // WHY: a body that does not decode is a permanent failure on device; a
    // retry could never fix it, so the caller must not treat it as transient.
    @Test("malformed: NetworkError.decodingError, never retried")
    func malformedIsPermanentDecodingError() async throws {
        let (network, _) = makeNetwork(.malformed)
        let call = startQuiz(network)
        await pumpUntil { call.finished }

        let error = try #require(call.error)
        guard case .decodingError? = error as? NetworkError else {
            Issue.record("expected NetworkError.decodingError, got \(error)")
            return
        }
        #expect(!TransientRetry.isTransient(error))
    }

    // WHY: a condition scoped to one call must leave the rest of the app on a
    // good network, or a "slow start" scenario would also stall Home.
    @Test("a condition on one call leaves the others instant")
    func conditionIsScopedToItsCalls() async throws {
        let (network, _) = makeNetwork(.offline, for: [.startQuiz])

        _ = try await network.createSession(
            maxQuestions: 5, difficulty: "medium", language: "en", categories: [], userId: nil,
            includeImages: false, skipLocalQuestions: false, packId: nil, ageBand: nil
        )
        let call = startQuiz(network)
        await pumpUntil { call.finished }
        #expect(call.urlErrorCode == .notConnectedToInternet)
    }

    // WHY: deterministic interleavings need ANY call held at the network and
    // let go on the test's cue, not only the four that once had gates.
    @Test("hold: any call waits until released, later calls pass straight through")
    func holdParksAnyCallUntilReleased() async {
        let (network, _) = makeNetwork(nil)
        let hold = network.hold(.startQuiz)
        let first = startQuiz(network)
        await pumpUntil { hold.heldCount == 1 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(!first.finished, "a held call answered without a release")

        hold.release()
        await pumpUntil { first.finished }
        #expect(first.response != nil)

        let second = startQuiz(network)
        await pumpUntil { second.finished }
        #expect(second.response != nil)
        #expect(hold.arrivals == 2)
    }

    // WHY: Home's Cancel cancels the start task; on device URLSession then
    // throws URLError.cancelled, which the start maps to Home, not the error
    // screen. A held call must end the same way, never hang the test.
    @Test("hold: a cancelled held call ends with URLError.cancelled")
    func cancelledHeldCallThrowsCancelled() async {
        let (network, _) = makeNetwork(nil)
        let hold = network.hold(.endSession)
        let task = Task { @MainActor in try await network.endSession(sessionId: "s") }
        await pumpUntil { hold.heldCount == 1 }

        task.cancel()
        let result = await task.result

        #expect((result.error as? URLError)?.code == .cancelled)
        #expect(hold.heldCount == 0)
    }

    // WHY: XCUITests reach the same profiles only through launch arguments;
    // a flag that parsed to nothing would let a scenario pass on a good network.
    @Test("--ui-test-network sets the profile, delay and calls")
    func launchArgumentsSetCondition() {
        let network = MockNetworkService()
        network.applyLaunchNetworkCondition(arguments: [
            "--ui-test", "--ui-test-network", "slow", "--ui-test-network-delay", "2.5",
            "--ui-test-network-calls", "createSession,startQuiz",
        ])
        #expect(network.networkConditions == [
            .createSession: .slow(.milliseconds(2500)),
            .startQuiz: .slow(.milliseconds(2500)),
        ])

        let everywhere = MockNetworkService()
        everywhere.applyLaunchNetworkCondition(arguments: ["--ui-test-network", "server-error"])
        #expect(everywhere.networkConditions.count == MockNetworkCall.allCases.count)
        #expect(everywhere.networkConditions[.getUsage] == .serverError(statusCode: 500))

        let none = MockNetworkService()
        none.applyLaunchNetworkCondition(arguments: ["--ui-test"])
        #expect(none.networkConditions.isEmpty)
    }
}

private extension Result {
    var error: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
