//
//  HomePacksSectionTests.swift
//  HangsTests
//
//  #141 Home "my packs" entry. Why these tests matter:
//  - Cards appear only for something pack-shaped: a playable delivered pack,
//    or an order still generating (founder pick 2026-08-05: a fresh buyer must
//    see their order on Home before the first delivery). Failed orders never
//    become cards — Home is a play entry, MyPacksView owns failure comms.
//  - #200 (TF 2026-10-12): the section itself never disappears. The title
//    always shows with a state under it (loading, no pack yet, failed with
//    Retry), because a vanished section read as "my packs are gone".
//  - The play button must carry the row's OWN packId into the quiz-start
//    path; a wrong or nil packId silently starts a generic quiz instead of
//    the pack the user paid for.
//  - An in-progress row must never offer a tappable play control — there is
//    no pack to play yet.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Fixtures

private func order(
    status: String,
    orderId: String,
    packId: String? = nil,
    actualCount: Int? = nil,
    packGenerationStatus: String? = nil
) -> OrderSnapshot {
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
        job: nil,
        actualCount: actualCount,
        packGenerationStatus: packGenerationStatus
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

    @Test("#182: an in_progress order WITH a pack is playable and surfaces")
    func generatingWithPackSurfaces() {
        let visible = HomePacksSection.visibleOrders([
            order(status: "in_progress", orderId: "g1", packId: "p1", actualCount: 5, packGenerationStatus: "generating"),
        ])
        #expect(visible.count == 1)
        #expect(visible[0].isPlayable)
    }

    @Test("#182: a failed order that produced a partial pack still stays off Home")
    func failedWithPackHidden() {
        let orders = [
            order(status: "failed", orderId: "f1", packId: "p1", actualCount: 7, packGenerationStatus: "failed"),
        ]
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

    @Test("tapping play starts the quiz with that row's own pack and its size")
    func playCarriesPackId() async throws {
        let vm = await loadedViewModel([order(status: "delivered", orderId: "d1", packId: "pack-xyz", actualCount: 30)])
        var played: [PackPlay] = []
        let view = HomePacksSection(viewModel: vm) { played.append($0) }

        try view.inspect()
            .find(viewWithAccessibilityIdentifier: "home.myPacks.play")
            .button().tap()
        // #200: the size lets the start ask before replaying a played-through pack.
        #expect(played == [PackPlay(packId: "pack-xyz", questionCount: 30)])
    }

    // #188 G14: Home and the pack list said two different things ("Preparing…"
    // vs "In progress") for the same order; both now read `statusLabel`.
    @Test("an in-progress row shows the pack-list status word and offers no tappable play control")
    func inProgressRowNotPlayable() async throws {
        let vm = await loadedViewModel([order(status: "in_progress", orderId: "g1")])
        let view = HomePacksSection(viewModel: vm) { _ in Issue.record("no play possible") }

        let tree = try view.inspect()
        _ = try tree.find(text: String(localized: "Preparing"))
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.play")
        }
    }

    // #182: the row must invite play the moment the first batch lands, and say
    // honestly how much of the pack is there — not "Preparing", which reads as
    // "nothing to do yet".
    @Test("#182: a still-generating row with a pack plays and shows the ready count")
    func generatingRowPlaysWithReadyCount() async throws {
        let vm = await loadedViewModel([
            order(status: "in_progress", orderId: "g1", packId: "pack-partial", actualCount: 5, packGenerationStatus: "generating"),
        ])
        var played: [PackPlay] = []
        let view = HomePacksSection(viewModel: vm) { played.append($0) }

        let tree = try view.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.readyCount")
        try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.play").button().tap()
        // #200: still growing, so no size: it can never count as played through.
        #expect(played == [PackPlay(packId: "pack-partial", questionCount: nil)])
    }

    @Test("the card always links through to the full My packs list")
    func showAllPresent() async throws {
        let vm = await loadedViewModel([order(status: "delivered", orderId: "d1", packId: "p1")])
        let view = HomePacksSection(viewModel: vm) { _ in }
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "home.myPacks.showAll")
    }

    @Test("a failed-only account gets the title and Show all, but no card")
    func failedOnlyRendersNoCard() async throws {
        let vm = await loadedViewModel([order(status: "failed", orderId: "f1")])
        let tree = try HomePacksSection(viewModel: vm) { _ in }.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "home.myPacksSection")
        _ = try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.showAll")
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.play")
        }
    }

    // TestFlight 2026-10-10: tapping a pack's play gave no feedback while the
    // session started, unlike Home's Start button — the founder tapped again.
    // The tapped pack must spin, and no play control may start a second quiz
    // while one is starting.
    @Test("while a pack's quiz starts, its play control spins and play is disabled")
    func startingPackSpinsAndBlocksPlay() async throws {
        let vm = await loadedViewModel([order(status: "delivered", orderId: "d1", packId: "pack-xyz")])
        var played: [PackPlay] = []
        let starting = HomePacksSection(
            viewModel: vm,
            quizStart: .init(isInFlight: true, packId: "pack-xyz")
        ) { played.append($0) }

        let play = try starting.inspect().find(viewWithAccessibilityIdentifier: "home.myPacks.play")
        _ = try play.find(ViewType.ProgressView.self)
        #expect(throws: (any Error).self) { try play.button().tap() }
        #expect(played.isEmpty, "a start in flight must not trigger another")

        let idle = HomePacksSection(viewModel: vm) { _ in }
        let idlePlay = try idle.inspect().find(viewWithAccessibilityIdentifier: "home.myPacks.play")
        #expect(throws: (any Error).self) { try idlePlay.find(ViewType.ProgressView.self) }
    }

    // TestFlight 2026-10-09: ordering a pack was reachable only from Settings.
    // The Home entry must exist for an account with NO packs yet — that is
    // exactly who needs it — and must open the order sheet.
    @Test("the create card shows with zero packs and opens the order flow")
    func createCardWithoutPacks() async throws {
        let vm = await loadedViewModel([])
        var opened = 0
        let view = HomePacksSection(
            viewModel: vm,
            createPack: .init(appConfig: AppConfigStore(fetch: { .permissive }), action: { opened += 1 })
        ) { _ in }

        let tree = try view.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.empty")
        try tree.find(viewWithAccessibilityIdentifier: "home.createPack").button().tap()
        #expect(opened == 1)
    }
}

// MARK: - #200 the section always shows

@Suite("HomePacksSection list state (#200)")
struct HomePacksSectionListStateTests {
    /// WHY: the founder saw the section vanish. Every combination must map to
    /// a visible state, and a list already on screen must survive a later
    /// failed refresh instead of turning into an error.
    @Test("loading, failed, empty and the list each have their own state")
    func everyCombinationIsVisible() {
        let delivered = order(status: "delivered", orderId: "d1", packId: "p1")
        #expect(HomePacksSection.listState(orders: [], isLoading: true, loadFailed: false) == .loading)
        #expect(HomePacksSection.listState(orders: [], isLoading: false, loadFailed: true) == .failed)
        #expect(HomePacksSection.listState(orders: [], isLoading: false, loadFailed: false) == .empty)
        #expect(HomePacksSection.listState(orders: [delivered], isLoading: false, loadFailed: true) == .packs([delivered]),
                "a failed refresh must not hide the packs already shown")
        #expect(HomePacksSection.listState(orders: [delivered], isLoading: true, loadFailed: false) == .packs([delivered]),
                "coming back to Home must not flash the spinner over the packs")
    }
}

@MainActor
@Suite("HomePacksSection states rendered (#200)")
struct HomePacksSectionStateRenderingTests {
    /// WHY: a cold pack API used to leave Home without the section and with no
    /// way back. The failure shows under the title and Retry loads again.
    @Test("a failed first load shows the title and a Retry that brings the packs")
    func failedLoadRetries() async throws {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResults: [
                .failure(.init("cold start")),
                .success([order(status: "delivered", orderId: "d1", packId: "p1")]),
            ]),
            clock: AnyClock(TestClock())
        )
        let loop = Task { await vm.start() }
        await pumpUntil({ vm.loadFailed }, "the first load never failed")
        loop.cancel()

        let tree = try HomePacksSection(viewModel: vm) { _ in }.inspect()
        _ = try tree.find(text: "my packs")
        try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.retry").button().tap()
        await pumpUntil({ !vm.orders.isEmpty }, "Retry never loaded the packs")
        #expect(!vm.loadFailed)
    }

    @Test("before the first answer the title shows with a loading line")
    func loadingShowsTitle() throws {
        let vm = MyPacksViewModel(service: MockPackOrderService())
        let tree = try HomePacksSection(viewModel: vm) { _ in }.inspect()
        _ = try tree.find(text: "my packs")
        _ = try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.loading")
    }

    /// WHY (#200): the card says how far this phone got in the pack.
    @Test("a pack this phone has started shows its played count")
    func cardShowsProgress() async throws {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResult: .success([
                order(status: "delivered", orderId: "d1", packId: "p1", actualCount: 30),
                order(status: "delivered", orderId: "d2", packId: "p2", actualCount: 30),
            ])),
            playedCount: { $0 == "p1" ? 10 : 0 }
        )
        await vm.refresh()

        let tree = try HomePacksSection(viewModel: vm) { _ in }.inspect()
        let progress = try tree.find(viewWithAccessibilityIdentifier: "home.myPacks.progress")
        #expect(try progress.text().string() == "Played 10 / 30")
        _ = try tree.find(text: "30 questions") // the unplayed pack keeps its question count
    }
}
