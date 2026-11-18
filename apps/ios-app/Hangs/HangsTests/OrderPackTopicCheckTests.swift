//
//  OrderPackTopicCheckTests.swift
//  HangsTests
//
//  #233: the topic check between the order form and the payment summary.
//  WHY: a blocked topic must never reach the pay button (the player would be
//  charged for a pack we refuse to make), a softened one must say so before
//  payment, and a broken check must never stop a purchase.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeViewModel(
    _ verdict: Result<TopicVerdict, MockPackOrderService.PackFailure>,
    analytics: MockAnalyticsClient = MockAnalyticsClient()
) -> (OrderPackViewModel, MockPackOrderService) {
    let service = MockPackOrderService(topicResult: verdict)
    let vm = OrderPackViewModel(
        service: service,
        purchaseService: MockPackPurchaseService(),
        adminKeyAvailable: { true },
        orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
        clock: AnyClock(ImmediateClock()),
        analytics: analytics
    )
    vm.prompt = "Topic under test"
    vm.selectDifficulty(.medium)
    return (vm, service)
}

@Suite("Order pack topic check (#233)")
@MainActor
struct OrderPackTopicCheckTests {
    @Test("a blocked topic stays on the form and never reaches payment")
    func blockedStaysOnForm() async {
        let (vm, _) = makeViewModel(.success(.blocked))
        await vm.continueFromForm()
        #expect(vm.state == .editing)
        #expect(vm.isTopicBlocked)
    }

    @Test("changing a blocked topic clears the notice and checks the new text")
    func editClearsBlock() async {
        let (vm, service) = makeViewModel(.success(.blocked))
        await vm.continueFromForm()
        vm.prompt = "Something else entirely"
        #expect(!vm.isTopicBlocked, "the notice belongs to the old text")
        await vm.continueFromForm()
        #expect(service.topicCheckCallCount == 2, "new text, new check")
    }

    @Test("a softened topic goes on to the summary with the toned-down note")
    func softenedContinues() async {
        let (vm, _) = makeViewModel(.success(.softened))
        await vm.continueFromForm()
        #expect(vm.state == .confirming)
        #expect(vm.isTopicSoftened)
    }

    @Test("an ordinary topic goes on without a note")
    func okContinues() async {
        let (vm, _) = makeViewModel(.success(.ok))
        await vm.continueFromForm()
        #expect(vm.state == .confirming)
        #expect(!vm.isTopicSoftened)
        #expect(!vm.isTopicBlocked)
    }

    @Test("a failed check lets the purchase through and is counted as an error")
    func failedCheckFailsOpen() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeViewModel(.failure(.init("offline")), analytics: analytics)
        await vm.continueFromForm()
        #expect(vm.state == .confirming)
        #expect(analytics.events(named: "pack_topic_checked") == [.packTopicChecked(verdict: "error")])
    }

    @Test("back from the summary and Continue again does not re-check the same text")
    func sameTextCheckedOnce() async {
        let analytics = MockAnalyticsClient()
        let (vm, service) = makeViewModel(.success(.softened), analytics: analytics)
        await vm.continueFromForm()
        vm.backToEdit()
        await vm.continueFromForm()
        #expect(vm.state == .confirming)
        #expect(service.topicCheckCallCount == 1)
        #expect(analytics.events(named: "pack_topic_checked") == [.packTopicChecked(verdict: "softened")])
    }
}
