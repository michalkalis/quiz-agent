//
//  HomePacksSectionTests.swift
//  HangsTests
//
//  #141 Home "my packs" entry. Why these tests matter:
//  - The section must appear IFF the account has something pack-shaped to
//    show: a playable delivered pack, or an order still generating (founder
//    pick 2026-08-05: a fresh buyer must see their order on Home before the
//    first delivery). An empty account, a signed-out 401, or an account whose
//    only orders failed must NOT grow a dead section on Home — Home is a play
//    entry, MyPacksView owns failure comms.
//  - The play button must carry the row's OWN packId into the quiz-start
//    path; a wrong or nil packId silently starts a generic quiz instead of
//    the pack the user paid for.
//  - An in-progress row must never offer a tappable play control — there is
//    no pack to play yet.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Fixtures

private func order(status: String, orderId: String, packId: String? = nil) -> OrderSnapshot {
    OrderSnapshot(
        orderId: orderId,
        status: status,
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: "space for kids",
        theme: nil,
        createdAt: "2026-08-04T10:00:00Z",
        deliveredAt: nil,
        packId: packId,
        llmCostUsd: nil,
        searchCostCents: 0,
        job: nil
    )
}

@MainActor
private func loadedViewModel(_ orders: [OrderSnapshot]) async -> MyPacksViewModel {
    let vm = MyPacksViewModel(service: MockPackOrderService(listResult: .success(orders)))
    await vm.refresh()
    return vm
}

// MARK: - Visibility derivation

@Suite("HomePacksSection visibility")
struct HomePacksSectionVisibilityTests {

    @Test("no orders → nothing to surface (zero-pack accounts keep Home unchanged)")
    func emptyOrders() {
        #expect(HomePacksSection.visibleOrders([]).isEmpty)
    }

    @Test("failed/refunded-only accounts stay hidden — Home is not an order-status surface")
    func failureOnlyHidden() {
        let orders = [
            order(status: "failed", orderId: "f1"),
            order(status: "refunded", orderId: "r1"),
        ]
        #expect(HomePacksSection.visibleOrders(orders).isEmpty)
    }

    @Test("an order still generating surfaces before first delivery (founder pick 2026-08-05)")
    func inProgressSurfaces() {
        for status in ["pending", "in_progress"] {
            let visible = HomePacksSection.visibleOrders([order(status: status, orderId: "g1")])
            #expect(visible.count == 1)
        }
    }

    @Test("a delivered order without a packId is unplayable and must not render a row")
    func deliveredWithoutPackIdHidden() {
        let orders = [order(status: "delivered", orderId: "d1", packId: nil)]
        #expect(HomePacksSection.visibleOrders(orders).isEmpty)
    }

    @Test("at most three rows on Home — the rest live behind Show all")
    func capsAtThree() {
        let orders = (1...5).map { order(status: "delivered", orderId: "d\($0)", packId: "p\($0)") }
        let visible = HomePacksSection.visibleOrders(orders)
        #expect(visible.count == 3)
        // Newest-first service order is preserved, not re-sorted.
        #expect(visible.map(\.orderId) == ["d1", "d2", "d3"])
    }
}

// MARK: - Rendered rows

@MainActor
@Suite("HomePacksSection rendering")
struct HomePacksSectionRenderingTests {

    @Test("tapping play starts the quiz with that row's own packId")
    func playCarriesPackId() async throws {
        let vm = await loadedViewModel([order(status: "delivered", orderId: "d1", packId: "pack-xyz")])
        var played: [String] = []
        let view = HomePacksSection(viewModel: vm) { played.append($0) }

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: "home.myPacks.play")
            .button().tap()
        #expect(played == ["pack-xyz"])
    }

    @Test("an in-progress row shows Preparing… and offers no tappable play control")
    func inProgressRowNotPlayable() async throws {
        let vm = await loadedViewModel([order(status: "in_progress", orderId: "g1")])
        let view = HomePacksSection(viewModel: vm) { _ in Issue.record("no play possible") }

        let tree = try view.inspect()
        _ = try tree.find(text: "Preparing…")
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.play")
        }
    }

    @Test("the card always links through to the full My packs list")
    func showAllPresent() async throws {
        let vm = await loadedViewModel([order(status: "delivered", orderId: "d1", packId: "p1")])
        let view = HomePacksSection(viewModel: vm) { _ in }
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "home.myPacks.showAll")
    }

    @Test("a failed-only account renders no section at all")
    func failedOnlyRendersNothing() async throws {
        let vm = await loadedViewModel([order(status: "failed", orderId: "f1")])
        let view = HomePacksSection(viewModel: vm) { _ in }
        #expect(throws: (any Error).self) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "home.myPacksSection")
        }
    }
}
