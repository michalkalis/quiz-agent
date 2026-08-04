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

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Fixtures

private func order(status: String) -> OrderSnapshot {
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
        packId: status == "delivered" ? "pack-1" : nil,
        llmCostUsd: nil,
        searchCostCents: 0,
        job: nil
    )
}

// MARK: - Status labels

@Suite("PackOrder status labels")
struct PackOrderStatusLabelTests {

    @Test("every known wire status maps to its localized label — never the raw wire value")
    func knownStatusesLocalized() {
        let expected: [String: String] = [
            "pending": String(localized: "Pending"),
            "in_progress": String(localized: "In progress"),
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
        let vm = MyPacksViewModel(service: MockPackOrderService(
            listResult: .success([order(status: "delivered")])
        ))
        let task = Task { await vm.start() }
        // start() loads then parks in the keep-fresh loop; wait for the load.
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        #expect(!vm.isLoading)
        #expect(vm.orders.count == 1)
        #expect(!vm.loadFailed)
    }

    @Test("a failed initial load (401 / offline) shows the graceful empty state, not a crash")
    func initialLoadFailure() async {
        let vm = MyPacksViewModel(service: MockPackOrderService(
            listResults: [.failure(.init("401"))]
        ))
        let task = Task { await vm.start() }
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        #expect(vm.orders.isEmpty)
        #expect(vm.loadFailed)
    }

    @Test("an in_progress order updates to delivered without navigation — the refresh loop re-fetches")
    func refreshLoopPicksUpDelivery() async {
        let vm = MyPacksViewModel(service: MockPackOrderService(
            listResults: [
                .success([order(status: "in_progress")]),
                .success([order(status: "delivered")]),
            ]
        ))
        vm.refreshIntervalSeconds = 0.01 // don't wait the real cadence

        let task = Task { await vm.start() }
        var sawInProgress = false
        var sawDelivered = false
        for _ in 0..<400 {
            if vm.orders.first?.status == "in_progress" { sawInProgress = true }
            if vm.orders.first?.isDelivered == true { sawDelivered = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        #expect(sawInProgress)
        #expect(sawDelivered)
    }

    @Test("a transient refresh error keeps the last good list instead of blanking the screen")
    func transientRefreshErrorKeepsList() async {
        let vm = MyPacksViewModel(service: MockPackOrderService(
            listResults: [
                .success([order(status: "in_progress")]),
                .failure(.init("blip")),
            ]
        ))
        vm.refreshIntervalSeconds = 0.01

        let task = Task { await vm.start() }
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Let several refresh ticks hit the failing call.
        try? await Task.sleep(for: .milliseconds(100))
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
