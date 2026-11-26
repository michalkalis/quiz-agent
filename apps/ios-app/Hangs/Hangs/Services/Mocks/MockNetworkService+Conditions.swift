//
//  MockNetworkService+Conditions.swift
//  Hangs
//
//  #235.1 (a "bad network" switch for tests): the mock answered every call at
//  once and correctly, so two bugs that only a slow or failing server shows
//  reached TestFlight. Every mock call now passes one entry point that can
//  hold it in flight (a gate, released by the test) and then apply a network
//  condition: slow, timeout, offline, dropped, server error, malformed.
//  Waits run on `networkClock`, so a logic test drives them with a
//  `TestClock`; under `--ui-test` they are real time.
//

import Clocks
import Foundation

#if DEBUG
    /// Every `MockNetworkService` call, by name: the key a gate or a condition
    /// is attached to. Raw values are the names `--ui-test-network-calls` takes.
    enum MockNetworkCall: String, CaseIterable, Sendable {
        case createSession, questionAvailability, startQuiz, submitVoiceAnswer, submitTextInput
        case nextQuestion, submitFeedback, downloadAudio, synthesizeSpeech, endSession
        case extendSession, rateQuestion, flagQuestion, transcribeDictation, getUsage
        case syncEntitlements, postAnalyticsEvents, fetchDailyChallenge, startDailyChallenge
        case createSharedQuiz, startSharedQuiz, sharedQuizResults
        case fetchDailyCrew, removeDailyCrewMember, extraCategories
    }

    /// What a bad network does to a call, shaped as the real `NetworkService`
    /// surfaces it to its caller.
    enum NetworkCondition: Equatable, Sendable {
        /// Answers normally, after `delay`.
        case slow(Duration)
        /// Never answers: the URLSession request timeout fires first.
        case timeout
        /// No connection at all: fails at once.
        case offline
        /// The connection drops `after` the request went out.
        case dropped(after: Duration)
        /// The server answers 5xx with a non-JSON body (edge-proxy page).
        case serverError(statusCode: Int)
        /// The server answers 200 with a body that does not decode.
        case malformed

        /// The real session's `timeoutIntervalForRequest` (NetworkService). A
        /// caller with a shorter limit of its own gives up first, as on device.
        static let requestTimeout: Duration = .seconds(30)

        /// The `--ui-test-network` profile names; `delay` feeds slow/dropped.
        init?(profile: String, delay: Duration) {
            switch profile {
            case "slow": self = .slow(delay)
            case "timeout": self = .timeout
            case "offline": self = .offline
            case "dropped": self = .dropped(after: delay)
            case "server-error": self = .serverError(statusCode: 500)
            case "malformed": self = .malformed
            default: return nil
            }
        }

        /// Returns when the call may go on with its normal answer, or throws
        /// what the real service would. A cancelled caller sees
        /// `URLError(.cancelled)`, as from `URLSession.data(for:)`.
        func apply(clock: AnyClock<Duration>) async throws {
            do {
                switch self {
                case let .slow(delay):
                    try await clock.sleep(for: delay)
                case .timeout:
                    try await clock.sleep(for: Self.requestTimeout)
                    throw URLError(.timedOut)
                case .offline:
                    throw URLError(.notConnectedToInternet)
                case let .dropped(after):
                    try await clock.sleep(for: after)
                    throw URLError(.networkConnectionLost)
                case let .serverError(statusCode):
                    throw NetworkError.serverError(statusCode: statusCode, message: "HTTP \(statusCode)")
                case .malformed:
                    throw NetworkError.decodingError(DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "The given data was not valid JSON.")
                    ))
                }
            } catch is CancellationError {
                throw URLError(.cancelled)
            }
        }
    }

    /// Holds every call that reaches it until the test calls `release()`;
    /// calls arriving after that pass straight through. A held call whose task
    /// is cancelled (Home "Cancel") ends with `URLError(.cancelled)`.
    @MainActor
    final class NetworkHold {
        private var released = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        /// Calls that reached the hold, released or not.
        private(set) var arrivals = 0

        /// Calls parked right now.
        var heldCount: Int { waiters.count }

        func wait() async throws {
            arrivals += 1
            if released { return }
            let id = UUID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        park(id, continuation)
                    }
                } onCancel: {
                    Task { @MainActor in self.cancel(id) }
                }
            } catch {
                throw URLError(.cancelled)
            }
        }

        private func park(_ id: UUID, _ continuation: CheckedContinuation<Void, Error>) {
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = continuation
            }
        }

        private func cancel(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }

        func release() {
            released = true
            let parked = waiters.values
            waiters.removeAll()
            parked.forEach { $0.resume() }
        }
    }

    /// #235.2: the game-together service's calls (`MockRoomService.conditions`).
    enum MockRoomCall: String, CaseIterable, Sendable {
        case createRoom, nearbyRooms, joinRoom, removePlayer, roomState, openQuestion
        case updateSettings, answer, answerByVoice, reportAway, setPaused, nextQuestion
    }

    /// #235.2: the same gates and conditions for the other mock services, so
    /// a test holds a room poll or a pack order exactly like a network call.
    @MainActor
    final class MockCallConditions<Call: Hashable & CaseIterable & Sendable> where Call.AllCases: Sendable {
        var gates: [Call: @Sendable () async throws -> Void] = [:]
        var networkConditions: [Call: NetworkCondition] = [:]
        var networkClock: AnyClock<Duration> = .continuous

        nonisolated init() {}

        @discardableResult
        func hold(_ call: Call) -> NetworkHold {
            let hold = NetworkHold()
            gates[call] = { try await hold.wait() }
            return hold
        }

        func setNetworkCondition(_ condition: NetworkCondition?, for calls: [Call] = Array(Call.allCases)) {
            for call in calls {
                networkConditions[call] = condition
            }
        }

        func simulateNetwork(_ call: Call) async throws {
            try await gates[call]?()
            try await networkConditions[call]?.apply(clock: networkClock)
        }
    }

    extension MockNetworkService {
        /// Holds `call` until the returned hold is released.
        @discardableResult
        func hold(_ call: MockNetworkCall) -> NetworkHold {
            let hold = NetworkHold()
            gates[call] = { try await hold.wait() }
            return hold
        }

        /// Puts `calls` (all of them by default) on `condition`; nil clears it.
        func setNetworkCondition(_ condition: NetworkCondition?, for calls: [MockNetworkCall] = MockNetworkCall.allCases) {
            for call in calls {
                networkConditions[call] = condition
            }
        }

        /// The one entry point every call passes once it is recorded and
        /// before it answers: its gate, then its condition.
        func simulateNetwork(_ call: MockNetworkCall) async throws {
            try await gates[call]?()
            try await networkConditions[call]?.apply(clock: networkClock)
        }

        /// `--ui-test-network <profile>` (slow, timeout, offline, dropped,
        /// server-error, malformed), optional `--ui-test-network-delay
        /// <seconds>` (slow and dropped, default 3) and
        /// `--ui-test-network-calls <name,name>` (default: every call). A
        /// misspelt name stops the launch: a scenario that silently ran on a
        /// good network would pass for the wrong reason.
        func applyLaunchNetworkCondition(arguments: [String] = CommandLine.arguments) {
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            guard let profile = value(after: "--ui-test-network") else { return }
            let seconds = value(after: "--ui-test-network-delay").flatMap(Double.init) ?? 3
            guard let condition = NetworkCondition(profile: profile, delay: .milliseconds(Int(seconds * 1000))) else {
                preconditionFailure("--ui-test-network: unknown profile \(profile)")
            }
            let calls = value(after: "--ui-test-network-calls")?.split(separator: ",").map { name in
                guard let call = MockNetworkCall(rawValue: String(name)) else {
                    preconditionFailure("--ui-test-network-calls: unknown call \(name)")
                }
                return call
            }
            setNetworkCondition(condition, for: calls ?? MockNetworkCall.allCases)
        }
    }
#endif
