//
//  QuizSequenceDoubles.swift
//  HangsTests
//
//  #186 step 2 — the two services whose TIMING the sequences must own.
//
//  `MockNetworkService` answers at once and `MockAudioService` plays on real
//  time, so neither can hold an answer in flight until the sequence says so or
//  end a read-out at a chosen moment. These doubles park every submit and every
//  playback until an input (or the test clock) resolves it, honour
//  cancellation the way URLSession / the real player do, and report what they
//  saw to the run's invariant checks. The silence detector, persistence and
//  earcons stay the shared mocks.
//

import AVFoundation
import Clocks
import Foundation
@testable import Hangs
import os

/// Parks async calls until something resolves them. Lock-based: the
/// cancellation handler runs outside the main actor.
nonisolated final class ParkedCalls<Value: Sendable>: Sendable {
    nonisolated private enum Slot {
        case registered
        case resolved(Result<Value, Error>)
        case parked(CheckedContinuation<Value, Error>)
    }

    private let slots = OSAllocatedUnfairLock<[Int: Slot]>(uncheckedState: [:])
    private let cancelError: @Sendable () -> Error

    init(cancelError: @escaping @Sendable () -> Error) {
        self.cancelError = cancelError
    }

    func register(_ id: Int) {
        slots.withLockUnchecked { $0[id] = .registered }
    }

    func isOpen(_ id: Int) -> Bool {
        slots.withLockUnchecked { slots in
            if case .parked = slots[id] { return true }
            if case .registered = slots[id] { return true }
            return false
        }
    }

    func park(_ id: Int) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let early: Result<Value, Error>? = slots.withLockUnchecked { slots in
                    if case let .resolved(result) = slots[id] {
                        slots[id] = nil
                        return result
                    }
                    slots[id] = .parked(continuation)
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            resolve(id, .failure(cancelError()))
        }
    }

    /// Resolve `id` once; later resolutions are ignored. `false` = nothing open.
    @discardableResult
    func resolve(_ id: Int, _ result: Result<Value, Error>) -> Bool {
        let (wasOpen, continuation): (Bool, CheckedContinuation<Value, Error>?) = slots.withLockUnchecked { slots in
            switch slots[id] {
            case let .parked(continuation):
                slots[id] = nil
                return (true, continuation)
            case .registered:
                // Resolved before the caller parked (a cancel on entry).
                slots[id] = .resolved(result)
                return (true, nil)
            default:
                return (false, nil)
            }
        }
        continuation?.resume(with: result)
        return wasOpen
    }

    var openIds: [Int] {
        slots.withLockUnchecked { slots in
            slots.keys.filter { id in
                if case .resolved = slots[id] { return false }
                return true
            }.sorted()
        }
    }
}

// MARK: - The quiz on the "server"

enum SequenceQuiz {
    static func id(_ index: Int) -> String { String(format: "q_%03d", index) }

    static func index(of id: String?) -> Int? {
        id.flatMap { Int($0.dropFirst(2)) }
    }

    static func question(_ index: Int, _ config: QuizSequenceConfig) -> Question {
        let mcq = config.mcqQuestions.contains(index)
        return Question(
            id: id(index),
            question: "Question \(index)?",
            type: mcq ? .textMultichoice : .text,
            possibleAnswers: mcq ? ["a": "Mars", "b": "Jupiter", "c": "Venus"] : nil,
            difficulty: "medium",
            topic: "Harness",
            category: "test",
            // Carries the question's identity into the recap, which keeps no id.
            sourceUrl: sourceURL(index),
            sourceExcerpt: nil,
            mediaUrl: nil,
            imageSubtype: nil,
            explanation: nil,
            generatedBy: nil
        )
    }

    static func sourceURL(_ index: Int) -> String { "https://harness.test/source/\(id(index))" }

    /// The recap keeps the evaluation's explanation, so the harness writes the
    /// graded question's id there — the only way to check a deferred result.
    static func gradedNote(_ questionId: String?) -> String { "graded \(questionId ?? "-")" }

    static func session(finished: Bool, _ config: QuizSequenceConfig) -> QuizSession {
        Fixtures.makeActiveSession(id: "harness", phase: finished ? "finished" : "asking", maxQuestions: config.questionCount)
    }

    static let questionAudioPrefix = "https://harness.test/question/"
    static let feedbackAudioPrefix = "https://harness.test/feedback/"
}

// MARK: - Network

@MainActor
final class SequenceNetwork: NetworkServiceProtocol {
    struct Request {
        let id: Int
        let isVoice: Bool
        let questionId: String?
        let input: String?
        /// The client re-sending a request the server answered 503 (the
        /// bounded cold-wake retry) — the same submission, not a new one.
        let isResend: Bool
        /// The attempt that owned the quiz when the request went out.
        let attempt: AttemptID
    }

    let config: QuizSequenceConfig
    private(set) var requests: [Request] = []
    private let parked = ParkedCalls<QuizResponse> { URLError(.cancelled) }

    /// Set by the run: the view model's current attempt.
    var attemptProbe: @MainActor () -> AttemptID = { .none }
    /// Set by the run: every text submit, as it is sent.
    var onTextSubmit: @MainActor (Request) -> Void = { _ in }
    /// Answers (or cancellations) that reached their caller — part of the
    /// run's "did anything move" fingerprint.
    private(set) var delivered = 0
    /// Fault injection for the harness self-test: the server grades the
    /// question AFTER the one it was asked about.
    var gradesNextQuestion = false

    init(config: QuizSequenceConfig) {
        self.config = config
    }

    static func transcript(of request: Request) -> String { "answer \(request.id)" }

    func hasPending(voice: Bool) -> Bool {
        requests.contains { $0.isVoice == voice && parked.isOpen($0.id) }
    }

    func voiceRequest(forTranscript text: String) -> Request? {
        requests.first { $0.isVoice && Self.transcript(of: $0) == text }
    }

    /// Answer the oldest request still in flight on the reply's channel.
    func resolveOldest(_ reply: QuizReply, detail: String?) -> Bool {
        guard let request = requests.first(where: { $0.isVoice == reply.isVoice && parked.isOpen($0.id) }) else {
            return false
        }
        return parked.resolve(request.id, result(for: request, reply: reply, detail: detail))
    }

    /// Teardown: nothing may stay parked past its run.
    func failAll() {
        for id in parked.openIds {
            parked.resolve(id, .failure(URLError(.cancelled)))
        }
    }

    private func result(for request: Request, reply: QuizReply, detail: String?) -> Result<QuizResponse, Error> {
        switch reply {
        case .voiceTranscript:
            .success(response(for: request, answer: Self.transcript(of: request), verdict: .correct))
        case .voiceEmpty:
            .success(response(for: request, answer: "", verdict: .incorrect))
        case .voiceNotUnderstood:
            .failure(NetworkError.serverError(statusCode: 400, message: "speech not understood"))
        case .voiceServerError, .textServerError:
            .failure(NetworkError.serverError(statusCode: 500, message: "harness"))
        case .voiceColdWake, .textColdWake:
            coldWake(request)
        case .textEvaluated:
            .success(response(
                for: request,
                answer: request.input ?? "",
                verdict: request.input == "skip" ? .skipped : (detail == "incorrect" ? .incorrect : .correct)
            ))
        }
    }

    private func coldWake(_ request: Request) -> Result<QuizResponse, Error> {
        if let key = requestKeys[request.id] { coldWoken.insert(key) }
        return .failure(MockNetworkService.coldWakeError)
    }

    private func response(for request: Request, answer: String, verdict: Evaluation.EvaluationResult) -> QuizResponse {
        let index = SequenceQuiz.index(of: request.questionId) ?? 1
        let finished = index >= config.questionCount
        let next = finished ? nil : SequenceQuiz.question(index + 1, config)
        let graded = gradesNextQuestion ? SequenceQuiz.id(index + 1) : request.questionId
        return QuizResponse(
            success: true,
            message: "harness",
            session: SequenceQuiz.session(finished: finished, config),
            currentQuestion: next,
            evaluation: Evaluation(
                userAnswer: answer, result: verdict, points: verdict == .correct ? 1 : 0,
                correctAnswer: "Jupiter", questionId: graded, explanation: SequenceQuiz.gradedNote(graded)
            ),
            feedbackReceived: [],
            audio: AudioInfo(
                feedbackUrl: config.feedbackAudio ? SequenceQuiz.feedbackAudioPrefix + "\(request.id)" : nil,
                feedbackAudioBase64: nil,
                questionUrl: next.map { SequenceQuiz.questionAudioPrefix + $0.id },
                format: "mp3"
            )
        )
    }

    /// Submissions the server answered 503, by session/question/input.
    private var coldWoken: Set<String> = []

    private func send(sessionId: String, isVoice: Bool, questionId: String?, input: String?) async throws -> QuizResponse {
        try Task.checkCancellation()
        let key = "\(sessionId)/\(isVoice)/\(questionId ?? "-")/\(input ?? "")"
        let request = Request(
            id: requests.count + 1, isVoice: isVoice, questionId: questionId, input: input,
            isResend: coldWoken.remove(key) != nil, attempt: attemptProbe()
        )
        requestKeys[request.id] = key
        requests.append(request)
        parked.register(request.id)
        if !isVoice { onTextSubmit(request) }
        defer { delivered += 1 }
        return try await parked.park(request.id)
    }

    // MARK: NetworkServiceProtocol

    private var requestKeys: [Int: String] = [:]

    func submitVoiceAnswer(sessionId: String, audioData _: Data, fileName _: String, questionId: String?) async throws -> QuizResponse {
        try await send(sessionId: sessionId, isVoice: true, questionId: questionId, input: nil)
    }

    func submitTextInput(sessionId: String, input: String, audio _: Bool, questionId: String?) async throws -> QuizResponse {
        try await send(sessionId: sessionId, isVoice: false, questionId: questionId, input: input)
    }

    func createSession(maxQuestions _: Int, difficulty _: String, language _: String, categories _: [String], userId _: String?, includeImages _: Bool, packId _: String?) async throws -> QuizSession {
        SequenceQuiz.session(finished: false, config)
    }

    func questionAvailability(requestedCount: Int, difficulty _: String, language _: String, categories _: [String], includeImages _: Bool, excludedQuestionIds _: [String]) async throws -> QuestionAvailability {
        QuestionAvailability(available: requestedCount, requested: requestedCount, sufficient: true)
    }

    func startQuiz(sessionId _: String, excludedQuestionIds _: [String]) async throws -> QuizResponse {
        let first = SequenceQuiz.question(1, config)
        return QuizResponse(
            success: true, message: "harness", session: SequenceQuiz.session(finished: false, config),
            currentQuestion: first, evaluation: nil, feedbackReceived: [],
            audio: AudioInfo(feedbackUrl: nil, feedbackAudioBase64: nil, questionUrl: SequenceQuiz.questionAudioPrefix + first.id, format: "mp3")
        )
    }

    func nextQuestion(sessionId _: String, audio _: Bool) async throws -> QuizResponse {
        throw NetworkError.invalidResponse // the harness quiz never waits for a generating pack
    }

    /// Every other call that reached the "server" — part of the run's
    /// "did anything move" fingerprint, so a chain between two waits is seen.
    private(set) var calls = 0

    func downloadAudio(from urlString: String) async throws -> Data {
        calls += 1
        return Data(urlString.utf8)
    }

    func synthesizeSpeech(text: String) async throws -> Data {
        calls += 1
        return Data("tts:\(text)".utf8)
    }
    func submitFeedback(message _: String, metadataJSON _: String?, appVersion _: String?, screenshotPNG _: Data?, audioWAV _: Data?, logsText _: String?) async throws {}
    func endSession(sessionId _: String) async throws {}
    func extendSession(sessionId _: String, minutes _: Int) async throws {}
    func rateQuestion(sessionId _: String, rating _: Int) async throws {}
    func flagQuestion(sessionId _: String, reason _: String?) async throws {}
    func fetchElevenLabsToken() async throws -> String { "harness-token" }
    func syncEntitlements() async throws {}

    func getUsage() async throws -> UsageInfo {
        UsageInfo(
            userId: "harness", isPremium: true, questionsUsed: 0, questionsLimit: nil, remaining: nil,
            resetsAt: "2030-01-01T00:00:00Z", subscriptionStatus: "active", creditBalance: 0
        )
    }
}

// MARK: - Audio

/// One player, like the real service: a new clip supersedes the one playing,
/// `stopPlayback` / `prepareForRecording` cut it short (its caller gets a
/// `CancellationError`), cancelling the task that awaits a clip stops it too
/// (the real `cleanupPlayback`), and a clip that is left alone ends when the
/// TEST CLOCK has run its length.
@MainActor
final class SequenceAudio: AudioServiceProtocol {
    enum Clip: String {
        case question, speech, feedback
    }

    /// Why a clip ended early.
    enum Cut: String {
        case stopped, superseded, recordingPrep, interruption, callerCancelled
    }

    let clock: AnyClock<Duration>
    private let parked = ParkedCalls<TimeInterval> { CancellationError() }
    private var playing: (id: Int, clip: Clip, questionId: String?, timer: Task<Void, Never>)?
    private var nextId = 0

    /// Set by the run: a clip was cut short (stop, supersede, recording prep).
    /// Question read-outs that played to their end, in order (question ids).
    private(set) var completedQuestionClips: [String] = []
    /// Set by the run: a clip was cut short (and, for a read-out, whose question).
    var onCutShort: @MainActor (Clip, Cut, String?) -> Void = { _, _, _ in }

    var isRecording = false
    var isPlaying: Bool { playing != nil }
    /// Clips started + clips ended early — part of the run's fingerprint.
    private(set) var activity = 0
    var playingClip: Clip? { playing?.clip }
    var isStreamingEngineActive: Bool { false }
    var onInterruptionBegan: (@MainActor @Sendable () -> Void)?
    var onRouteChange: (@MainActor @Sendable (AudioRouteChange) -> Void)?
    var availableInputDevices: [AudioDevice] = [.previewBuiltIn]
    var currentInputDevice: AudioDevice?
    var currentOutputDeviceName = "iPhone"

    /// Question clips end only on `finishQuestionClip()` (a replayed dump).
    var questionClipsEndOnCue = false

    init(clock: AnyClock<Duration>) {
        self.clock = clock
    }

    /// A replayed `questionReadOut.end`: the question clip playing now ends.
    func finishQuestionClip() -> Bool {
        guard let current = playing, current.clip == .question else { return false }
        current.timer.cancel()
        finish(current.id)
        return true
    }

    static func length(of clip: Clip) -> Duration {
        switch clip {
        case .question: .seconds(4)
        case .speech: .milliseconds(1500)
        case .feedback: .seconds(3)
        }
    }

    func playOpusAudio(_ data: Data) async throws -> TimeInterval {
        let text = String(decoding: data, as: UTF8.self)
        let clip: Clip = text.hasPrefix(SequenceQuiz.questionAudioPrefix) ? .question
            : text.hasPrefix(SequenceQuiz.feedbackAudioPrefix) ? .feedback : .speech
        cutShort(.superseded)
        activity += 1
        let questionId = clip == .question ? String(text.dropFirst(SequenceQuiz.questionAudioPrefix.count)) : nil
        nextId += 1
        let id = nextId
        parked.register(id)
        let clock = clock
        let length = clip == .question && questionClipsEndOnCue ? .seconds(3600) : Self.length(of: clip)
        let timer = Task { [weak self] in
            guard (try? await clock.sleep(for: length)) != nil else { return }
            self?.finish(id)
        }
        playing = (id, clip, questionId, timer)
        defer { activity += 1 }
        do {
            return try await parked.park(id)
        } catch {
            // Still "playing" = nobody stopped it: the awaiting task was cancelled.
            if let current = playing, current.id == id {
                playing = nil
                current.timer.cancel()
                onCutShort(current.clip, .callerCancelled, current.questionId)
            }
            throw error
        }
    }

    private func finish(_ id: Int) {
        guard let current = playing, current.id == id else { return }
        playing = nil
        if let questionId = current.questionId { completedQuestionClips.append(questionId) }
        parked.resolve(id, .success(4))
    }

    private func cutShort(_ cut: Cut) {
        guard let current = playing else { return }
        activity += 1
        playing = nil
        current.timer.cancel()
        parked.resolve(current.id, .failure(CancellationError()))
        onCutShort(current.clip, cut, current.questionId)
    }

    func stopPlayback() async {
        cutShort(.stopped)
    }

    /// The real service stops playback and waits 200 ms for the hardware.
    func prepareForRecording() async {
        cutShort(.recordingPrep)
        try? await clock.sleep(for: .milliseconds(200))
    }

    /// A phone call: the system silences playback and the service tells the owner.
    func simulateInterruption() {
        cutShort(.interruption)
        onInterruptionBegan?()
    }

    /// The car's Bluetooth connecting (media output: voice processing off) or
    /// leaving (back to the speaker: on), as the service reports it.
    func simulateRouteChange(connected: Bool) {
        onRouteChange?(AudioRouteChange(
            reason: connected ? .newDeviceAvailable : .oldDeviceUnavailable,
            outputPort: connected ? "BluetoothA2DPOutput" : "Speaker",
            previousOutputPort: connected ? "Speaker" : "BluetoothA2DPOutput",
            voiceProcessingMode: connected ? .offOutput : .on
        ))
    }

    func teardown() {
        onCutShort = { _, _, _ in }
        cutShort(.stopped)
    }

    func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval {
        try await playOpusAudio(Data(base64Encoded: base64) ?? Data())
    }

    func setupAudioSession(mode _: AudioMode) throws {}
    func setupQuietListeningSession() throws {}
    func restoreSessionAfterVoiceProcessing() {}
    func deactivateSession() {}
    func switchAudioMode(_: AudioMode) async throws {}
    func requestMicrophonePermission() async -> Bool { true }
    func startRecording() throws { isRecording = true }

    func stopRecording() async throws -> Data {
        isRecording = false
        return Data()
    }

    func startStreamingRecording(onChunk _: @escaping PCMChunkHandler) async throws {
        throw AudioError.recordingFailed // the harness drives the batch path (#184 default)
    }

    func stopStreamingRecording() {}
    func refreshAvailableDevices() {}
    func setPreferredInputDevice(_ device: AudioDevice?) throws { currentInputDevice = device }
}
