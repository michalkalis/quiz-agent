//
//  MyPacksViewModelTests.swift
//  HangsTests
//
//  #137 My packs list. Why these tests matter:
//  - The list must keep itself fresh: an order transitioning
//    in_progress → delivered while the screen is open has to update its row
//    without navigation, or the user stares at a stale "in progress" forever
//    (the founder's field report). The refresh loop must also STOP hitting the
//    network once every order is terminal — polling a settled list wastes
//    battery and backend quota.
//  - A transient list error mid-refresh must keep the last good list, not
//    blank the screen while a paid order is still generating.
//  - The raw wire status (`FAILED`, `IN_PROGRESS`…) must never reach the UI:
//    every known status maps to a localized label, and an unknown future
//    status degrades to its raw value instead of crashing the row.
//  - The loading spinner must span the full content width — without
//    `.frame(maxWidth: .infinity)` the ScrollView collapses to the spinner's
//    intrinsic width and it renders in a narrow strip (the broken layout in
//    the field report).
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
    packId: String? = nil,
    actualCount: Int? = nil,
    packGenerationStatus: String? = nil
) -> OrderSnapshot {
    OrderSnapshot(
        orderId: "order-\(status)",
        status: status,
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: nil,
        theme: nil,
        createdAt: "2026-08-04T10:00:00Z",
        deliveredAt: nil,
        packId: packId ?? (status == "delivered" ? "pack-1" : nil),
        llmCostUsd: nil,
        searchCostCents: 0,
        job: nil,
        actualCount: actualCount,
        packGenerationStatus: packGenerationStatus
    )
}

// MARK: - Status labels

@Suite("PackOrder status labels")
struct PackOrderStatusLabelTests {

    @Test("every known wire status maps to its localized label — never the raw wire value")
    func knownStatusesLocalized() {
        let expected: [String: String] = [
            // #188 G14: queued and generating are one state to the player.
            "pending": String(localized: "Preparing"),
            "in_progress": String(localized: "Preparing"),
            "delivered": String(localized: "Delivered"),
            "failed": String(localized: "Failed"),
            "refunded": String(localized: "Refunded"),
        ]
        for (wire, label) in expected {
            #expect(order(status: wire).statusLabel == label)
            // The raw uppercase/underscore wire value must never leak through.
            #expect(order(status: wire).statusLabel != wire)
        }
    }

    @Test("an unknown future status falls back to the raw value instead of hiding the row")
    func unknownStatusFallsBack() {
        #expect(order(status: "quarantined").statusLabel == "quarantined")
    }
}

// MARK: - Refresh loop

@MainActor
@Suite("MyPacksViewModel")
struct MyPacksViewModelTests {

    @Test("initial load populates orders and clears the spinner")
    func initialLoad() async {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResult: .success([order(status: "delivered")])),
            // Parked clock (#180 track A): start() loads, then the keep-fresh
            // loop parks on this clock instead of the real 5 s cadence.
            clock: AnyClock(TestClock())
        )
        let task = Task { await vm.start() }
        await pumpUntil({ !vm.isLoading }, "the initial load never cleared the spinner")
        task.cancel()

        #expect(!vm.isLoading)
        #expect(vm.orders.count == 1)
        #expect(!vm.loadFailed)
    }

    @Test("a failed initial load (401 / offline) shows the graceful empty state, not a crash")
    func initialLoadFailure() async {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResults: [.failure(.init("401"))]),
            clock: AnyClock(TestClock())
        )
        let task = Task { await vm.start() }
        await pumpUntil({ !vm.isLoading }, "a failed initial load never cleared the spinner")
        task.cancel()

        #expect(vm.orders.isEmpty)
        #expect(vm.loadFailed)
    }

    @Test("an in_progress order updates to delivered without navigation — the refresh loop re-fetches")
    func refreshLoopPicksUpDelivery() async {
        let clock = TestClock()
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResults: [
                .success([order(status: "in_progress")]),
                .success([order(status: "delivered")]),
            ]),
            clock: AnyClock(clock)
        )

        let task = Task { await vm.start() }
        await pumpUntil({ vm.orders.first?.status == "in_progress" }, "the initial load never showed the in-progress order")

        // The SHIPPED 5 s cadence is driven, not shrunk: just short of it the
        // row must still be the stale one (no busy re-polling), and only once
        // the interval elapses does the loop re-fetch and flip the row —
        // without any navigation.
        await clock.advance(by: .milliseconds(4900))
        #expect(vm.orders.first?.isDelivered == false, "the loop re-fetched before its 5 s interval elapsed")
        await clock.advance(by: .milliseconds(101))
        await pumpUntil({ vm.orders.first?.isDelivered == true }, "the keep-fresh loop never picked the delivery up")
        task.cancel()
    }

    @Test("a transient refresh error keeps the last good list instead of blanking the screen")
    func transientRefreshErrorKeepsList() async {
        let clock = TestClock()
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResults: [
                .success([order(status: "in_progress")]),
                .failure(.init("blip")),
            ]),
            clock: AnyClock(clock)
        )

        let task = Task { await vm.start() }
        await pumpUntil({ !vm.isLoading }, "the initial load never cleared the spinner")
        // Let several refresh ticks hit the failing call — each one is a full
        // shipped 5 s interval, driven rather than waited out.
        for _ in 0 ..< 3 {
            await clock.advance(by: .milliseconds(5001))
            await Task.yield()
        }
        task.cancel()

        #expect(vm.orders.first?.status == "in_progress")
        #expect(!vm.loadFailed)
    }

    @Test("pull-to-refresh replaces the list even when every order is already terminal")
    func manualRefreshOnSettledList() async {
        let vm = MyPacksViewModel(service: MockPackOrderService(
            listResults: [
                .success([order(status: "delivered")]),
                .success([order(status: "delivered"), order(status: "in_progress")]),
            ]
        ))
        await vm.refresh()
        #expect(vm.orders.count == 1)

        await vm.refresh() // the user's pull — must re-fetch regardless of terminal states
        #expect(vm.orders.count == 2)
    }

    // MARK: Try again (#146)

    // WHY: this is the recovery path for an order the user already PAID for.
    // It must re-enqueue THAT order (never a second create) and it must send no
    // StoreKit proof — My packs has none, which is exactly the situation the
    // old proof-bound retry made unrecoverable.
    @Test("Try again re-enqueues the paid order with no payment proof, and the row returns to in progress")
    func retryReenqueuesWithoutProof() async {
        let service = MockPackOrderService(listResults: [
            .success([order(status: "failed")]),
            .success([order(status: "in_progress")]),
        ])
        let vm = MyPacksViewModel(service: service)
        await vm.refresh()
        #expect(vm.orders.first?.status == "failed")

        await vm.retry(orderId: "order-failed")

        #expect(service.retryOrderCallCount == 1)
        #expect(service.createOrderCallCount == 0, "a retry must never mint a second paid order")
        #expect(service.capturedRetryProofs == [nil], "no proof is held — the account bearer authorises it")
        #expect(vm.orders.first?.status == "in_progress", "the row must leave the failed state after a 202")
        #expect(vm.retryErrorMessage == nil)
        #expect(vm.retryingOrderIds.isEmpty, "the in-flight marker must not leak past the call")
    }

    // WHY: a refused retry that looks like a no-op leaves the user tapping a
    // dead button on a pack they paid for — the reason has to be visible.
    @Test("a refused retry surfaces the backend's reason instead of failing silently")
    func refusedRetrySurfacesReason() async {
        let service = MockPackOrderService(
            listResult: .success([order(status: "failed")]),
            retryFailure: .retryRefused("manual retry budget exhausted")
        )
        let vm = MyPacksViewModel(service: service)
        await vm.refresh()

        await vm.retry(orderId: "order-failed")

        #expect(vm.retryErrorMessage == "manual retry budget exhausted")
        #expect(vm.orders.first?.status == "failed", "a refused retry must not fake progress")
    }
}

// MARK: - #182 playable rows

@MainActor
@Suite("MyPacksView playable rule (#182)")
struct MyPacksPlayableRuleTests {

    /// The row exactly as the user sees it once the list has loaded (the view
    /// renders a spinner until `start()` clears `isLoading`, so a bare
    /// `refresh()` would inspect an empty screen).
    private func loadedView(_ orders: [OrderSnapshot]) async -> MyPacksView {
        // Parked clock (#180 track A): start() loads, then the keep-fresh loop
        // parks on this clock instead of the real 5 s cadence.
        let viewModel = MyPacksViewModel(
            service: MockPackOrderService(listResult: .success(orders)),
            clock: AnyClock(TestClock())
        )
        let task = Task { await viewModel.start() }
        await pumpUntil({ !viewModel.isLoading }, "the initial load never cleared the spinner")
        task.cancel()
        return MyPacksView(viewModel: viewModel, onPlayPack: { _ in })
    }

    // WHY: the pack is paid for and the first batch is playable. Gating
    // "Start quiz" on `delivered` would make the user wait for questions they
    // already own — the whole point of #182.
    @Test("an in_progress order with a pack offers Start quiz and the ready count")
    func generatingRowIsPlayable() async throws {
        let view = await loadedView([
            order(status: "in_progress", packId: "pack-partial", actualCount: 5, packGenerationStatus: "generating"),
        ])
        let tree = try view.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "myPacks.startQuiz")
        _ = try tree.find(viewWithAccessibilityIdentifier: "myPacks.readyCount")
    }

    // WHY: a failed order's partial pack must keep "Try again" — offering it as
    // a playable pack would sell a broken set as a finished one.
    @Test("a failed order with a partial pack offers Try again, never Start quiz")
    func failedRowWithPackIsNotPlayable() async throws {
        let view = await loadedView([
            order(status: "failed", packId: "pack-partial", actualCount: 7, packGenerationStatus: "failed"),
        ])
        let tree = try view.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "myPacks.retry")
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "myPacks.startQuiz")
        }
    }

    @Test("an in_progress order with no pack yet offers nothing to play")
    func pendingRowHasNoPlay() async throws {
        let view = await loadedView([order(status: "in_progress")])
        let tree = try view.inspect()
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "myPacks.startQuiz")
        }
    }
}

// MARK: - Loading layout

@MainActor
@Suite("MyPacksView loading layout")
struct MyPacksViewLoadingLayoutTests {

    @Test("the loading spinner spans the full content width, not a narrow strip")
    func spinnerFullWidth() throws {
        // Fresh view: isLoading starts true and .task hasn't run under inspection.
        let view = MyPacksView(service: MockPackOrderService(), onPlayPack: { _ in })
        let progress = try view.inspect().find(ViewType.ProgressView.self)
        #expect(try progress.flexFrame().maxWidth == .infinity)
    }
}

// MARK: - #200 failed loads and pack progress

@MainActor
@Suite("MyPacksViewModel failed loads and progress (#200)")
struct MyPacksViewModelRecoveryTests {
    /// WHY: the pack API scales to zero, so the first list request after idle
    /// can fail. That load was never tried again and Home lost the section.
    /// It must come back on its own, on a growing schedule rather than a
    /// hammering one.
    @Test("a failed first load retries on its own after 5 s, then 10 s, and shows the list")
    func failedLoadRetriesWithBackoff() async {
        let clock = TestClock()
        let service = MockPackOrderService(listResults: [
            .failure(.init("cold start")),
            .failure(.init("still cold")),
            .success([order(status: "delivered")]),
        ])
        let vm = MyPacksViewModel(service: service, clock: AnyClock(clock))
        let task = Task { await vm.start() }
        await pumpUntil({ vm.loadFailed }, "the first load never failed")
        #expect(!vm.isLoading)
        for _ in 0 ..< 10 {
            await Task.yield() // let the loop park on the clock before time moves
        }

        await clock.advance(by: .milliseconds(4900))
        #expect(service.listOrdersCallCount == 1, "retried before the first pause was over")
        await clock.advance(by: .milliseconds(101))
        await pumpUntil({ service.listOrdersCallCount == 2 }, "the first retry never ran")

        await clock.advance(by: .milliseconds(9900))
        #expect(service.listOrdersCallCount == 2, "the second pause must be longer than the first")
        await clock.advance(by: .milliseconds(101))
        await pumpUntil({ vm.orders.count == 1 }, "the second retry never brought the list")
        #expect(!vm.loadFailed)
        task.cancel()
    }

    /// WHY: coming back to Home re-runs the load; a failure there used to wipe
    /// the packs already shown.
    @Test("a failed reload keeps the list that was already on screen")
    func failedReloadKeepsList() async {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResults: [
                .success([order(status: "delivered")]),
                .failure(.init("offline")),
            ]),
            clock: AnyClock(TestClock())
        )
        let first = Task { await vm.start() }
        await pumpUntil({ vm.orders.count == 1 }, "the first load never landed")
        first.cancel()

        let again = Task { await vm.start() }
        await pumpUntil({ vm.loadFailed }, "the reload never failed")
        again.cancel()

        #expect(vm.orders.count == 1)
        #expect(!vm.isLoading, "a reload must not put the spinner over the packs")
    }

    /// WHY: leaving Home while a cold load waits cancels it. That is no
    /// answer; reading it as a failure showed "Couldn't load your packs" over
    /// the load that runs when Home comes back.
    @Test("a load cancelled by leaving the screen is not a failure")
    func cancelledLoadIsNotAFailure() async {
        let vm = MyPacksViewModel(service: HangingListService(), clock: AnyClock(TestClock()))
        let task = Task { await vm.start() }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        task.cancel()
        await task.value

        #expect(!vm.loadFailed, "leaving the screen must not read as a failed load")
        #expect(vm.isLoading, "the next appearance still starts from loading")
    }

    @Test("the automatic retry pause grows to a minute and stays there")
    func reloadDelaySchedule() {
        let pauses = [1, 2, 3, 4, 5, 6, 500].map { MyPacksViewModel.reloadDelay(afterFailures: $0) }
        #expect(pauses == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60)])
    }

    /// WHY (#200): "10 / 30" is counted against what the pack really holds
    /// once it is generated, so a played-through pack reads 30 / 30 and the
    /// start can ask before replaying it.
    @Test("progress counts played questions against the pack's real size")
    func progressAgainstPackSize() {
        let vm = MyPacksViewModel(
            service: MockPackOrderService(),
            playedCount: { ["pack-1": 10, "pack-2": 40, "pack-3": 4][$0] ?? 0 }
        )

        #expect(vm.progress(of: order(status: "delivered", packId: "pack-1", actualCount: 30)) == PackProgress(played: 10, total: 30))
        #expect(vm.progress(of: order(status: "delivered", packId: "pack-2", actualCount: 28)) == PackProgress(played: 28, total: 28))
        #expect(vm.progress(of: order(status: "in_progress", packId: "pack-3", actualCount: 5, packGenerationStatus: "generating"))
            == PackProgress(played: 4, total: 30), "a growing pack counts against what was ordered")
        #expect(vm.progress(of: order(status: "delivered", packId: "pack-9", actualCount: 30)) == nil, "nothing played, nothing shown")
        #expect(vm.progress(of: order(status: "in_progress")) == nil, "no pack yet")
    }
}

/// A pack API that never answers: `listOrders` waits until it is cancelled.
private final class HangingListService: PackOrderServiceProtocol, Sendable {
    private let clock = TestClock()

    func listOrders() async throws -> [OrderSnapshot] {
        try await clock.sleep(for: .seconds(3600))
        return []
    }

    func createOrder(intent _: PackOrderIntent) async throws -> OrderCreatedResponse { throw CancellationError() }
    func getOrder(id _: String) async throws -> OrderSnapshot { throw CancellationError() }
    func retryOrder(id _: String, paymentProof _: PackPaymentProof?) async throws -> OrderCreatedResponse { throw CancellationError() }
}
