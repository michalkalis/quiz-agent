//
//  MyPacksViewModel.swift
//  Hangs
//
//  Drives the My packs order list (issue #137). Loads on every appearance, then
//  keeps the list fresh while it is on screen: pull-to-refresh plus a periodic
//  reload whenever any listed order is still non-terminal, so an order
//  transitioning in_progress → delivered/failed updates its row without the
//  user leaving the screen. The loop lives inside the view's `.task`, so
//  SwiftUI cancels it when the view disappears.
//
//  #200: the pack API scales to zero, so the first list request after idle
//  can fail. A failed load keeps the last good list and is retried on its own
//  with a growing pause; Home shows the failure (with Retry) only while there
//  is no list at all.
//
//  #208.5: one instance for the app's lifetime (AppState), shared by Home and
//  My packs, so a reload after a quiz never blanks the list.
//

import Combine
import Clocks
import Foundation

@MainActor
final class MyPacksViewModel: ObservableObject {
    @Published private(set) var orders: [OrderSnapshot] = []
    @Published private(set) var isLoading = true
    @Published private(set) var loadFailed = false
    /// The last load failed because nobody is signed in (a 401 that survived
    /// the token refresh). Only then does My packs ask the user to sign in;
    /// any other failure offers Retry (#200).
    @Published private(set) var needsSignIn = false
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

    /// The clock the keep-fresh loop sleeps on (#180 track A) — a test drives it.
    private let clock: AnyClock<Duration>

    /// #200: how many questions of a pack this phone has played.
    private let playedCount: (String) -> Int

    init(
        service: PackOrderServiceProtocol,
        clock: AnyClock<Duration> = .continuous,
        playedCount: @escaping (String) -> Int = { _ in 0 }
    ) {
        self.service = service
        self.clock = clock
        self.playedCount = playedCount
    }

    /// #200: the pause before the next automatic try of a failed load: 5 s,
    /// 10 s, 20 s, 40 s, then every minute while the list is on screen.
    nonisolated static func reloadDelay(afterFailures failures: Int) -> Duration {
        let doublings = min(max(failures - 1, 0), 4)
        return .seconds(min(5 << doublings, 60))
    }

    /// Initial load, then the keep-fresh loop. The loop stays alive for the
    /// whole on-screen lifetime (it may need to resume after a pull-to-refresh
    /// brings in a new non-terminal order) but only hits the network while some
    /// order can still change state, or while the last load failed.
    func start() async {
        await load()
        var failures = 0
        while !Task.isCancelled {
            failures = loadFailed ? failures + 1 : 0
            let pause = loadFailed ? Self.reloadDelay(afterFailures: failures) : .seconds(refreshIntervalSeconds)
            do {
                try await clock.sleep(for: pause)
            } catch {
                return // cancelled — view left the screen
            }
            if loadFailed {
                await load()
            } else if orders.contains(where: { !$0.isTerminal }) {
                await refresh()
            }
        }
    }

    /// #208.5: the account changed (sign-out, deletion) — the list belonged
    /// to the previous one. Back to the first-load state; the next appearance
    /// loads the new account's packs.
    func reset() {
        orders = []
        isLoading = true
        loadFailed = false
        needsSignIn = false
        retryErrorMessage = nil
    }

    /// Home's "Retry" after a failed load: back to the spinner, then one more try.
    func retryLoad() async {
        isLoading = true
        await load()
    }

    /// #200: "10 / 30" for a pack this phone has started; nil before its first
    /// question, and for an order without a pack.
    func progress(of order: OrderSnapshot) -> PackProgress? {
        guard let packId = order.packId else { return nil }
        let played = playedCount(packId)
        guard played > 0 else { return nil }
        let total = order.playableQuestionCount ?? order.targetCount
        return PackProgress(played: min(played, total), total: total)
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
            needsSignIn = false
            isLoading = false
        }
    }

    /// The first load, and each retry of a failed one. A cold pack API is
    /// retried briefly in place (`TransientRetry`, the list GET is
    /// idempotent). A failure keeps whatever list was already there (#200:
    /// coming back to Home used to wipe it) and only marks the load failed.
    /// A load cancelled because the screen went away is no answer at all and
    /// leaves the state as it was for the next appearance.
    private func load() async {
        do {
            orders = try await TransientRetry.run(label: "pack list", clock: clock) {
                try await service.listOrders()
            }
            loadFailed = false
            needsSignIn = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return }
            loadFailed = true
            if case PackOrderError.unauthorized = error { needsSignIn = true } else { needsSignIn = false }
        }
        isLoading = false
    }
}
