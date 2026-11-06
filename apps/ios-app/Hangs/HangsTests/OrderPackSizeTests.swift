//
//  OrderPackSizeTests.swift
//  HangsTests
//
//  #228.6: the buyer picks a 10 or 30 question pack on the summary. These
//  tests encode WHY the behaviour matters:
//  - `pack_10` may not be on sale yet (App Store Connect approval). Until
//    StoreKit returns it, the summary must be exactly the 30-only one of
//    before: a switch to a product that can't be bought dead-ends the order.
//  - The size the buyer sees is the size they pay for and the size they get:
//    the chosen product goes to StoreKit, and the order carries that product,
//    because the server sizes the pack from the receipt.
//  - Prices are StoreKit's localized strings for each size, never a number
//    the app made up.
//  - An earlier paid but unordered purchase is spent before any new charge,
//    so it, not the switch, decides the size.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("OrderPackViewModel — pack size (#228.6)")
struct OrderPackSizeTests {
    private static let bothPrices: [PackSize: String] = [.ten: "3,49 €", .thirty: "8,99 €"]

    private func summaryViewModel(
        orders: MockPackOrderService = MockPackOrderService(),
        purchase: MockPackPurchaseService,
        analytics: AnalyticsClient = NoopAnalyticsClient()
    ) async -> OrderPackViewModel {
        let vm = OrderPackViewModel(
            service: orders,
            purchaseService: purchase,
            adminKeyAvailable: { false },
            orderLanguages: { Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes) },
            refreshLanguages: {},
            clock: AnyClock(ImmediateClock()),
            analytics: analytics
        )
        vm.prompt = "Slovak castles and their legends"
        vm.selectDifficulty(.medium)
        vm.advanceToSummary()
        await vm.loadPrice()
        return vm
    }

    @Test("without pack_10 in StoreKit the switch is hidden and the order stays a 30 pack")
    func switchHiddenUntilPack10IsOnSale() async {
        let orders = MockPackOrderService()
        let purchase = MockPackPurchaseService(prices: [.thirty: "8,99 €"])
        let vm = await summaryViewModel(orders: orders, purchase: purchase)

        #expect(vm.offersSizeChoice == false)
        vm.selectSize(.ten)
        #expect(vm.size == .thirty, "a size the App Store doesn't sell can't be chosen")
        #expect(vm.packPrice == "8,99 €")

        await vm.submit()

        #expect(purchase.purchasedSizes == [.thirty])
        #expect(orders.capturedIntents.map(\.size) == [.thirty])
        #expect(orders.capturedIntents.first?.paymentProof?.productId == "pack_30")
    }

    @Test("picking 10 buys pack_10 and orders a 10 question pack")
    func chosenSizeFlowsToPurchaseAndOrder() async {
        let orders = MockPackOrderService()
        let purchase = MockPackPurchaseService(prices: Self.bothPrices)
        let analytics = MockAnalyticsClient()
        let vm = await summaryViewModel(orders: orders, purchase: purchase, analytics: analytics)

        #expect(vm.offersSizeChoice)
        #expect(vm.size == .thirty, "30 stays preselected")
        vm.selectSize(.ten)
        await vm.submit()

        #expect(purchase.purchasedSizes == [.ten], "the payment sheet must charge for the size on screen")
        let intent = orders.capturedIntents.first
        #expect(intent?.size == .ten)
        #expect(intent?.paymentProof?.productId == "pack_10", "the server sizes the pack from this product")
        #expect(analytics.events == [.purchaseResult(
            productId: "pack_10", kind: .customPack, outcome: .success, questionCount: 10
        )])
    }

    @Test("the price follows the chosen size and comes from StoreKit")
    func priceFollowsSize() async {
        let vm = await summaryViewModel(purchase: MockPackPurchaseService(prices: Self.bothPrices))

        #expect(vm.packPrice == "8,99 €")
        vm.selectSize(.ten)
        #expect(vm.packPrice == "3,49 €")
        vm.selectSize(.thirty)
        #expect(vm.packPrice == "8,99 €")
    }

    @Test("a waiting paid purchase decides the size and hides the switch")
    func pendingProofFixesTheSize() async {
        let earlier = PackPaymentProof(transactionId: "990000000000888", productId: "pack_10", jws: "earlier.jws")
        let orders = MockPackOrderService()
        let purchase = MockPackPurchaseService(pending: earlier, prices: Self.bothPrices)
        let vm = await summaryViewModel(orders: orders, purchase: purchase)

        #expect(vm.size == .ten, "the summary must show the pack that was already paid for")
        #expect(vm.offersSizeChoice == false)

        await vm.submit()

        #expect(purchase.purchaseCallCount == 0, "never a second charge")
        #expect(orders.capturedIntents.first?.size == .ten)
    }

    @Test("the sign-in prompt names the size bought before the first snapshot lands")
    func signInPromptUsesBoughtSize() async {
        let orders = MockPackOrderService(getResult: .failure(.init()))
        let vm = await summaryViewModel(orders: orders, purchase: MockPackPurchaseService(prices: Self.bothPrices))
        vm.selectSize(.ten)
        await vm.submit()

        guard case let .customPack(_, questionCount, _) = vm.takeAcceptedPaidOrder() else {
            Issue.record("a paid, accepted order must be offered to keep")
            return
        }
        #expect(questionCount == 10)
    }

    @Test("a new order starts from 30 again")
    func sizeResetsForNewOrder() async {
        let vm = await summaryViewModel(purchase: MockPackPurchaseService(prices: Self.bothPrices))
        vm.selectSize(.ten)
        await vm.submit()
        #expect(vm.playableSnapshot != nil)

        vm.prepareForPresentation(defaultLanguage: "en")

        #expect(vm.state == .editing)
        #expect(vm.size == .thirty)
    }
}
