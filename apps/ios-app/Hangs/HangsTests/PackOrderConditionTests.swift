//
//  PackOrderConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, custom pack order row). The order goes topic
//  check → payment → create → progress polling. On a bad network the topic
//  check must never block a purchase (it fails open), a failed create after
//  payment must offer "Try again" that reuses the same payment (never a
//  second charge or a second order), and the poll must end in a message
//  instead of spinning forever. Generic failures, the poll deadline, the
//  retry of a paid order and reopening the sheet are in OrderPackViewModelTests,
//  OrderPackTopicCheckTests and PackRetryDurabilityTests; these drive the
//  real conditions (timeout, offline, dropped, server error, malformed).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Custom pack order on a bad network (#235.2)")
@MainActor
struct PackOrderConditionTests {
    private let clock = TestClock<Duration>()
    private let service = MockPackOrderService()
    private let purchase = MockPackPurchaseService()

    nonisolated static let failures: [NetworkCondition] = [
        .timeout, .offline, .dropped(after: .seconds(2)), .serverError(statusCode: 500), .malformed,
    ]

    /// `paying: false` is the Debug admin path (no StoreKit step).
    private func makeVM(paying: Bool = true) -> OrderPackViewModel {
        service.conditions.networkClock = AnyClock(clock)
        let vm = OrderPackViewModel(
            service: service,
            purchaseService: purchase,
            adminKeyAvailable: { !paying },
            orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
            clock: AnyClock(clock)
        )
        vm.prompt = "Lighthouses of the North Sea"
        vm.selectDifficulty(.medium)
        return vm
    }

    private static func isFailedRetryable(_ vm: OrderPackViewModel) -> Bool {
        if case .failed(_, retryable: true) = vm.state { true } else { false }
    }

    // WHY: the topic check is a courtesy before payment. On a network that
    // fails it, the player still reaches the summary (within one request
    // timeout at most) and nothing has been charged yet.
    @Test("a topic check that fails on the network lets the player through to the summary, nothing charged", arguments: failures)
    func failedTopicCheckFailsOpen(condition: NetworkCondition) async {
        let vm = makeVM()
        service.conditions.setNetworkCondition(condition, for: [.checkTopic])
        let next = Task { await vm.continueFromForm() }

        await advanceUntil(clock, limit: .seconds(60)) { vm.state == .confirming }
        await next.value

        #expect(!vm.isCheckingTopic)
        #expect(purchase.purchaseCallCount == 0)
    }

    // WHY: while a slow check runs the form shows it is checking, and a
    // second "Continue" tap must not send a second check.
    @Test("a slow topic check shows it is checking and takes no second tap")
    func slowTopicCheckTakesOneTap() async {
        let vm = makeVM()
        let hold = service.conditions.hold(.checkTopic)
        let first = Task { await vm.continueFromForm() }
        await pumpUntil { hold.heldCount == 1 }

        #expect(vm.isCheckingTopic)
        await vm.continueFromForm()
        #expect(service.topicCheckCallCount == 1, "a second tap sent a second check")

        hold.release()
        await first.value
        #expect(vm.state == .confirming)
    }

    // WHY: the money case. The player paid, then the order request failed on
    // the network (a dropped request may even have reached the server). The
    // sheet must say so with "Try again", and the retry must carry the SAME
    // payment and idempotency key: one charge, one order.
    @Test("an order that fails on the network after payment is retried with the same payment", arguments: failures)
    func failedCreateRetriesWithSamePayment(condition: NetworkCondition) async {
        let vm = makeVM()
        vm.advanceToSummary()
        service.conditions.setNetworkCondition(condition, for: [.createOrder])
        let submit = Task { await vm.submit() }

        await advanceUntil(clock, limit: .seconds(60)) { Self.isFailedRetryable(vm) }
        await submit.value
        service.conditions.setNetworkCondition(nil, for: [.createOrder])
        await vm.retry()

        guard case .delivered = vm.state else {
            Issue.record("the retry did not deliver the pack: \(vm.state)")
            return
        }
        #expect(purchase.purchaseCallCount == 1, "the player was charged twice")
        #expect(service.capturedIntents.count == 2)
        #expect(Set(service.capturedIntents.map(\.idempotencyKey)).count == 1, "the retry could create a second order")
    }

    // WHY: the order is paid and generating, but progress polls keep failing.
    // The "Building your pack" spinner must end in a message (Try again, or
    // "check My packs later"), never spin for as long as the network is down.
    @Test("progress polls that keep failing end in a message, not an endless spinner", arguments: failures)
    func failingPollEnds(condition: NetworkCondition) async {
        let vm = makeVM(paying: false)
        vm.advanceToSummary()
        service.conditions.setNetworkCondition(condition, for: [.getOrder])
        let submit = Task { await vm.submit() }

        await advanceUntil(clock, limit: .seconds(240)) {
            if case .failed = vm.state { true } else { false }
        }
        await submit.value
        #expect(service.createOrderCallCount == 1)
    }

    // WHY: when the order watch is stopped (the order model is torn down),
    // a progress reply still on its way must not write the sheet's state, and
    // nothing keeps polling the server.
    @Test("a progress reply on its way when the watch stops changes nothing and polling ends")
    func stoppedPollIgnoresLateReply() async {
        let vm = makeVM(paying: false)
        vm.advanceToSummary()
        let hold = service.conditions.hold(.getOrder)
        let submit = Task { await vm.submit() }
        await pumpUntil { hold.heldCount == 1 }
        let before = vm.state

        vm.stop()
        hold.release()
        await submit.value
        await clock.advance(by: .seconds(10))

        #expect(vm.state == before, "a reply after the watch stopped was applied")
        #expect(hold.arrivals == 1, "the order was still polled after the watch stopped")
    }
}
