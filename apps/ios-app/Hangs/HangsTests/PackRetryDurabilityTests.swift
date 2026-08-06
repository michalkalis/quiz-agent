//
//  PackRetryDurabilityTests.swift
//  HangsTests
//
//  #146 — a paid pack order must stay recoverable after the screen that
//  created it is gone. Why these tests matter:
//  - The order view model used to live in `SettingsView`'s `@State`, and
//    Settings is a pushed route that quiz-start teardown empties
//    (`NavigationModel.clearAll`). Following the app's own advice ("check My
//    packs later") therefore destroyed the only object that could recover a
//    PAID order. Ownership now sits on AppState, so the lifetime is asserted
//    on the owning object — not on view internals.
//  - `MyPacksView` was read-only for failures: a `failed` row showed a red
//    label and no way forward, so the money was spent with no in-app path
//    back. It must now offer "Try again" on exactly that row — and on no
//    other, because the backend 409s a retry of a pending/in_progress order
//    and a refunded one has nothing left to run.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Fixtures

private func order(_ status: String) -> OrderSnapshot {
    OrderSnapshot(
        orderId: "order-\(status)",
        status: status,
        productId: "pack_30",
        targetCount: 30,
        language: "en",
        category: nil,
        theme: nil,
        createdAt: "2026-08-06T10:00:00Z",
        deliveredAt: status == "delivered" ? "2026-08-06T10:05:00Z" : nil,
        packId: status == "delivered" ? "pack-1" : nil,
        llmCostUsd: nil,
        searchCostCents: 0,
        job: nil
    )
}

/// A My packs screen already showing exactly `orders` — the list is loaded up
/// front so the structure assertions don't race the view's own `.task`.
@MainActor
private func loadedMyPacksView(_ orders: [OrderSnapshot]) async -> MyPacksView {
    let viewModel = MyPacksViewModel(service: MockPackOrderService(listResult: .success(orders)))
    // start() loads, then parks in the keep-fresh loop — wait out the load and
    // cancel, leaving the model in the state the user actually sees.
    let task = Task { await viewModel.start() }
    for _ in 0..<400 {
        if !viewModel.isLoading { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    return MyPacksView(viewModel: viewModel, onPlayPack: { _ in })
}

// MARK: - Ownership / lifetime

@MainActor
@Suite("Pack order ownership (#146)")
struct PackOrderOwnershipTests {

    // WHY: this is the whole bug. Starting a quiz empties the pushed path the
    // Settings screen lives on; when the order view model was that screen's
    // `@State`, a live PAID order died with it and no screen could retry.
    @Test("a live order survives the quiz-start teardown that empties the pushed navigation path")
    func orderViewModelOutlivesQuizStart() {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let navModel = NavigationModel()
        navModel.path = [.settings]
        navModel.orderFlowPresented = true

        let owned = appState.orderPackViewModel
        owned.prompt = "History of Rome"

        // Exactly what ContentView runs on every quizState change.
        navModel.handleQuizStateChange(.startingQuiz)

        #expect(navModel.path.isEmpty, "the teardown under test must actually have happened")
        #expect(!navModel.orderFlowPresented)
        #expect(appState.orderPackViewModel === owned,
                "the order model must be the SAME object after teardown — a new one has no order to retry")
        #expect(appState.orderPackViewModel.prompt == "History of Rome")
    }

    // WHY: reopening the sheet must land on the order that is still running,
    // which only works if every presentation reads the one app-owned model.
    @Test("every read of the order model returns the one AppState owns")
    func orderViewModelIsASingleInstance() {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        #expect(appState.orderPackViewModel === appState.orderPackViewModel)
    }
}

// MARK: - My packs row action matrix

@MainActor
@Suite("MyPacksView retry action (#146)")
struct MyPacksRetryActionTests {

    // WHY: the retry endpoint only accepts a `failed` order (409 otherwise) and
    // a refunded one has already been paid back — offering the button anywhere
    // else promises a recovery that cannot happen.
    @Test("only a failed row offers Try again")
    func retryOfferedOnlyOnFailedRows() async throws {
        let expectations: [(status: String, offersRetry: Bool)] = [
            ("failed", true),
            ("pending", false),
            ("in_progress", false),
            ("delivered", false),
            ("refunded", false),
        ]

        for expectation in expectations {
            let view = await loadedMyPacksView([order(expectation.status)])
            let tree = try view.inspect()

            let retry = try? tree.find(viewWithAccessibilityIdentifier: "myPacks.retry")
            #expect((retry != nil) == expectation.offersRetry,
                    "\(expectation.status): retry offered = \(retry != nil), expected \(expectation.offersRetry)")
        }
    }

    // WHY: the delivered row's existing "Start quiz" affordance must not be
    // displaced by the new failure path.
    @Test("a delivered row still offers Start quiz, not Try again")
    func deliveredRowKeepsStartQuiz() async throws {
        let view = await loadedMyPacksView([order("delivered")])
        let tree = try view.inspect()
        _ = try tree.find(viewWithAccessibilityIdentifier: "myPacks.startQuiz")
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "myPacks.retry")
        }
    }
}
