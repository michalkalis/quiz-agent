//
//  VoiceAllowanceContractTests.swift
//  HangsTests
//
//  Free tier split (2026-11-21): what the screens show when the voice answers
//  are used up (D1 typing instead of the mic, D2 the counter only in the
//  Profile plan card), and the wire contract with the server.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Screens

@Suite("Free voice answers used up: screens (2026-11-21)")
@MainActor
struct VoiceAllowanceScreenTests {
    private func spentViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.usageInfo = voiceTestUsage(voiceRemaining: 0)
        return vm
    }

    // WHY: with the voice answers used up, Answer must lead to typing, never
    // to a mic the server refuses.
    @Test("Answer never opens the mic when the voice answers are used up")
    func answerOpensTyping() async throws {
        let vm = spentViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(viewWithAccessibilityIdentifier: "question.record").find(ViewType.Button.self).tap()
            for _ in 0 ..< 50 {
                await Task.yield()
            } // let a started recording land
            #expect(vm.quizState == .askingQuestion, "the mic opened")
            // The typed field itself is @State of the screen: RS-47 asserts it.
        }
    }

    @Test("the notice and its Plus link are on the question that ran out")
    func noticeOnQuestion() async throws {
        let vm = spentViewModel()
        vm.startRecordingOrTimer()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect((try? tree.find(viewWithAccessibilityIdentifier: "question.voiceLimitNotice")) != nil)
            #expect((try? tree.find(viewWithAccessibilityIdentifier: "question.voiceLimitPlus")) != nil)
            // WHY: one label per concept, the Plus offer reads the same as on
            // every other Plus button, and promises no "unlimited" (Plus is capped).
            #expect((try? tree.find(text: "Get Trubbo Plus")) != nil)
        }
    }

    // WHY: D2, the counter lives in the Profile plan card next to the free
    // questions, and only when voice is limited.
    @Test("the plan card shows voice answers left only when voice is limited", arguments: [
        (voiceTestUsage(voiceRemaining: 12), true),
        (voiceTestUsage(voiceRemaining: 0), true),
        (voiceTestUsage(voiceRemaining: nil, voiceLimit: nil), false),
        (voiceTestUsage(voiceRemaining: nil, voiceLimit: nil, status: "active"), false),
    ])
    func planCardVoiceLine(usage: UsageInfo, shows: Bool) throws {
        let card = HomePlanCard(usage: usage)
        let line = try? card.inspect().find(viewWithAccessibilityIdentifier: "home.planVoiceAnswers")
        #expect((line != nil) == shows)
    }

    @Test("the voice line reads the remaining voice answers")
    func planCardVoiceLineText() throws {
        let card = HomePlanCard(usage: voiceTestUsage(voiceRemaining: 12))
        #expect((try? card.inspect().find(text: "By voice: 12 of 30 left")) != nil)
    }
}

// MARK: - Wire contract

@Suite("Free voice answers used up: wire contract (2026-11-21)", .serialized)
struct VoiceAllowanceWireTests {
    private func makeService() -> NetworkService {
        NetworkService(baseURL: "http://test.invalid", session: StubURLProtocol.makeSession())
    }

    @Test("session create declares voice-allowance")
    func declaresCapability() {
        let tokens = Set(NetworkService.clientCapabilities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(tokens.contains("voice-allowance"))
    }

    // WHY: the voice 429 must not be read as the quota 429, which ends the
    // round and opens the paywall with questions left.
    @Test("a voice_limit_reached 429 decodes as .voiceLimitReached")
    func voiceLimitDecodes() async {
        let body = #"{"detail":{"code":"voice_limit_reached","message":"m","voice_answers_used":30,"voice_answers_limit":30,"resets_at":"2026-12-01T00:00:00+00:00"}}"#
        StubURLProtocol.handler = { _ in (.make(status: 429), Data(body.utf8)) }
        defer { StubURLProtocol.handler = nil }
        do {
            _ = try await makeService().submitVoiceAnswer(sessionId: "s1", audioData: Data([1]), fileName: "answer.wav", questionId: "q1")
            Issue.record("expected a throw")
        } catch let NetworkError.voiceLimitReached(limit) {
            #expect(limit == voiceTestRefusal)
        } catch {
            Issue.record("expected .voiceLimitReached, got \(error)")
        }
    }

    @Test("the quota 429 still decodes as .quotaLimitReached")
    func quotaStillDecodes() async {
        let body = #"{"detail":{"error":"quota_limit_reached","questions_used":150,"questions_limit":150,"resets_at":"2026-12-01T00:00:00+00:00","upgrade_available":true}}"#
        StubURLProtocol.handler = { _ in (.make(status: 429), Data(body.utf8)) }
        defer { StubURLProtocol.handler = nil }
        do {
            _ = try await makeService().submitVoiceAnswer(sessionId: "s1", audioData: Data([1]), fileName: "answer.wav", questionId: "q1")
            Issue.record("expected a throw")
        } catch NetworkError.quotaLimitReached {
        } catch {
            Issue.record("expected .quotaLimitReached, got \(error)")
        }
    }

    // WHY: older servers send no voice fields; the usage must still decode
    // and never read as "voice used up".
    @Test("usage decodes with and without the voice fields")
    func usageDecodes() throws {
        let base = #""user_id":"u","is_premium":false,"questions_used":1,"questions_limit":150,"remaining":149,"resets_at":"x","subscription_status":"none","credit_balance":0"#
        let old = try JSONDecoder().decode(UsageInfo.self, from: Data("{\(base)}".utf8))
        #expect(old.voiceAnswersLimit == nil)
        #expect(old.isVoiceAllowanceSpent == false)
        let new = try JSONDecoder().decode(UsageInfo.self, from: Data(#"{\#(base),"voice_answers_used":30,"voice_answers_limit":30,"voice_answers_remaining":0}"#.utf8))
        #expect(new.isVoiceAllowanceSpent)
        let unlimited = try JSONDecoder().decode(UsageInfo.self, from: Data(#"{\#(base),"voice_answers_used":3,"voice_answers_limit":null,"voice_answers_remaining":null}"#.utf8))
        #expect(unlimited.isVoiceAllowanceSpent == false)
    }
}
