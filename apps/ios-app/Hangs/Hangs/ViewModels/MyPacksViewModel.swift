//
//  MyPacksViewModel.swift
//  Hangs
//
//  Drives the My packs order list (issue #137). Loads once on appear, then
//  keeps the list fresh while it is on screen: pull-to-refresh plus a periodic
//  reload whenever any listed order is still non-terminal, so an order
//  transitioning in_progress → delivered/failed updates its row without the
//  user leaving the screen. The loop lives inside the view's `.task`, so
//  SwiftUI cancels it when the view disappears.
//

import Combine
import Foundation

@MainActor
final class MyPacksViewModel: ObservableObject {
    @Published private(set) var orders: [OrderSnapshot] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    /// Order ids with a retry request in flight — the row shows progress and
    /// stops offering the button, so one tap can't fan out into several
    /// re-enqueues of the same paid order.
    @Published private(set) var retryingOrderIds: Set<String> = []
    /// Why the last retry didn't take (session expired, retry budget spent, …).
    /// Surfaced, never swallowed: a refused retry that looks like a no-op leaves
    /// the user tapping a dead button on an order they paid for.
    @Published var retryErrorMessage: String?

    /// Delay between automatic reload checks, in seconds. Instance-settable so
    /// tests don't wait on real time.
    var refreshIntervalSeconds: TimeInterval = 5

    private let service: PackOrderServiceProtocol

    init(service: PackOrderServiceProtocol) {
        self.service = service
    }

    /// Initial load, then the keep-fresh loop. The loop stays alive for the
    /// whole on-screen lifetime (it may need to resume after a pull-to-refresh
    /// brings in a new non-terminal order) but only hits the network while some
    /// order can still change state.
    func start() async {
        await initialLoad()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(refreshIntervalSeconds))
            } catch {
                return // cancelled — view left the screen
            }
            if orders.contains(where: { !$0.isTerminal }) {
                await refresh()
            }
        }
    }

    /// "Try again" on a `failed` row (#146). The order was already PAID for, so
    /// this re-enqueues THAT order via `POST /v1/orders/{id}/retry` — never a
    /// second create. Since #146 the account bearer alone authorises it, which
    /// is what makes this reachable at all: My packs holds no StoreKit proof,
    /// and the one the order was created with died with the Settings screen.
    ///
    /// On acceptance the backend has already flipped the order back to
    /// pending/in_progress before answering, so a plain refresh returns the row
    /// to its in-progress state and re-arms the keep-fresh loop.
    func retry(orderId: String) async {
        guard !retryingOrderIds.contains(orderId) else { return }
        retryingOrderIds.insert(orderId)
        defer { retryingOrderIds.remove(orderId) }

        do {
            _ = try await service.retryOrder(id: orderId, paymentProof: nil)
        } catch {
            retryErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Couldn't restart this pack. Please try again.", comment: "Shown when retrying a failed custom-pack order from My packs did not reach the server")
            return
        }
        await refresh()
    }

    /// Pull-to-refresh and background reload. On error the last good list is
    /// kept — a transient blip mid-generation must not blank the screen.
    func refresh() async {
        if let fresh = try? await service.listOrders() {
            orders = fresh
            loadFailed = false
        }
    }

    private func initialLoad() async {
        isLoading = true
        loadFailed = false
        do {
            orders = try await service.listOrders()
        } catch {
            // 401 / no bearer / offline → graceful empty state, never a crash.
            orders = []
            loadFailed = true
        }
        isLoading = false
    }
}
