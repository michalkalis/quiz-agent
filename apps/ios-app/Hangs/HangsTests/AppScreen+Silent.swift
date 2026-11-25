//
//  AppScreen+Silent.swift
//  HangsTests
//
//  "No sound" (founder 2026-11-22): Home with the switch on, and the open and
//  multiple-choice question of a silent quiz (typed field open, no Answer,
//  no countdown, no mute).
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeSilent() -> AnyView {
        switch self {
        case .homeSilent: Self.silentHome()
        case .questionSilent: Self.silentQuestion(Question.preview)
        case .questionSilentMCQ: Self.silentQuestion(Question.previewMCQ)
        default: preconditionFailure("\(self) is not a silent mode screen")
        }
    }

    private static func silentHome() -> AnyView {
        let usage = UsageInfo(
            userId: "snapshot-subject",
            isPremium: false,
            questionsUsed: 12,
            questionsLimit: 30,
            remaining: 18,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400 + 12 * 3600)),
            subscriptionStatus: "none",
            creditBalance: 0
        )
        let network = MockNetworkService()
        network.stubbedUsage = usage
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
        vm.usageInfo = usage
        vm.settings.silentMode = true
        return AnyView(HomeView(viewModel: vm))
    }

    private static func silentQuestion(_ question: Question) -> AnyView {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.settings.silentMode = true
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return AnyView(QuestionView(viewModel: vm, debugSurfaces: false))
    }
}
