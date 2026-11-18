//
//  Issue206LocalQuestionsTests.swift
//  HangsTests
//
//  #206 — the "Local questions" switch in the Categories sheet.
//
//  Why these tests matter:
//  - The switch only works if it leaves the device: the server filters local
//    questions per session, so a toggle that never reaches createSession is a
//    silent no-op that still shows Bratislava public transport to a player who
//    turned it off.
//  - The pre-start availability probe must use the same switch, or "Start with
//    N questions" promises a set the smaller universal pool cannot fill.
//  - Default is ON (founder 2026-10-15): a fresh install sends no skip.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("QuizViewModel — local questions switch rides the session requests (#206)")
struct LocalQuestionsRequestTests {
    private func makeViewModel(_ network: MockNetworkService) -> QuizViewModel {
        QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService()
        )
    }

    @Test("switch off asks the server to skip local questions, for the probe too")
    func switchOffSkipsLocalQuestions() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = makeViewModel(network)
        vm.settings.includeLocalQuestions = false

        await vm.startNewQuiz()

        #expect(network.capturedSkipLocalQuestions == true)
        #expect(network.capturedAvailabilitySkipLocalQuestions == true)
    }

    @Test("default settings keep local questions")
    func defaultKeepsLocalQuestions() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = makeViewModel(network)

        await vm.startNewQuiz()

        #expect(network.capturedSkipLocalQuestions == false)
    }
}

@MainActor
@Suite("HomeCategoryPicker — local questions switch (#206)")
struct HomeCategoryPickerLocalQuestionsTests {
    @Test("the switch is in the Categories sheet and flips the setting")
    func switchFlipsBinding() throws {
        var include = true
        let binding = Binding(get: { include }, set: { include = $0 })
        let view = HomeCategoryPicker(categories: .constant([]), includeLocalQuestions: binding)

        let row = try view.inspect().find(viewWithAccessibilityIdentifier: "home.categories.localQuestions")
        try row.find(ViewType.Toggle.self).tap()

        #expect(include == false)
    }
}
