//
//  OrderPackViewModelTests.swift
//  HangsTests
//
//  #95 custom-pack order VM. These tests encode WHY the behaviour matters:
//  - The 10–1000 prompt bounds mirror the server's 422 rule; a client that lets
//    an out-of-bounds prompt through would round-trip only to be rejected.
//  - submit() must drive all the way to a terminal state — a stuck `.submitting`
//    strands the user on a spinner with a paid order in flight.
//  - A failed order and a network error must both surface as `.failed` (visible),
//    never crash the poll loop.
//  - A *transient* poll error must be retried, not treated as fatal: a paid order
//    is still generating server-side and a false `.failed` invites a double charge.
//  - The poll must not spin forever on a stuck in_progress order — an overall
//    deadline surfaces a soft `.failed` that points the user at My packs.
//

import Foundation
@testable import Hangs
import Testing

/// Defaults to the Debug admin path (`adminKeyAvailable: true`) so the
/// pre-#140 order/poll tests keep exercising exactly the flow they always did —
/// no payment step. Purchase-flow tests below pass `adminKeyAvailable: false`
/// to route through the (mock) StoreKit purchase instead.
@MainActor
private func makeOrderPackViewModel(
    service: MockPackOrderService = MockPackOrderService(),
    purchaseService: MockPackPurchaseService = MockPackPurchaseService(),
    adminKeyAvailable: Bool = true
) -> OrderPackViewModel {
    OrderPackViewModel(
        service: service,
        purchaseService: purchaseService,
        adminKeyAvailable: { adminKeyAvailable }
    )
}

@MainActor
@Suite("OrderPackViewModel")
struct OrderPackViewModelTests {

    // MARK: - Validation bounds (must match the server's 10–1000 rule)

    @Test("prompt below 10 chars is invalid — server would 422 it")
    func promptTooShort() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 9)
        #expect(!vm.isValid)
    }

    @Test("prompt at the 10-char floor is valid")
    func promptAtFloor() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 10)
        #expect(vm.isValid)
    }

    @Test("prompt at the 1000-char ceiling is valid")
    func promptAtCeiling() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 1000)
        #expect(vm.isValid)
    }

    @Test("prompt above 1000 chars is invalid — server would 422 it")
    func promptTooLong() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 1001)
        #expect(!vm.isValid)
    }

    @Test("validation counts the TRIMMED prompt, not raw whitespace padding")
    func validationTrims() {
        let vm = makeOrderPackViewModel()
        vm.prompt = "   " + String(repeating: "a", count: 5) + "   " // 5 real chars
        #expect(!vm.isValid)
    }

    // MARK: - submit lifecycle

    @Test("submit happy path reaches .delivered with a non-nil pack id")
    func submitDelivers() async {
        let vm = makeOrderPackViewModel()
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .delivered(let snapshot) = vm.state else {
            Issue.record("expected .delivered, got \(vm.state)")
            return
        }
        #expect(snapshot.packId != nil)
    }

    @Test("submit ignores an invalid prompt — no order is created")
    func submitGuardsInvalid() async {
        let vm = makeOrderPackViewModel()
        vm.prompt = "short" // < 10 chars

        await vm.submit()

        #expect(vm.state == .editing)
    }

    @Test("a failed order surfaces as .failed, not a stuck poll")
    func submitFailedOrder() async {
        let service = MockPackOrderService(getResult: .success(.mockFailed))
        let vm = makeOrderPackViewModel(service: service)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
    }

    @Test("a network error surfaces as .failed rather than crashing")
    func submitNetworkError() async {
        let service = MockPackOrderService(createResult: .failure(.init("boom")))
        let vm = makeOrderPackViewModel(service: service)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
    }

    // The order rarely delivers on the first poll; if the loop didn't actually
    // iterate, a still-building order would strand the user. This proves the VM
    // publishes the intermediate `.polling` snapshot and then advances to a
    // later `getOrder` result — i.e. the poll loop runs more than once.
    @Test("submit passes through .polling before .delivered — the poll loop iterates, not a call-#1 short-circuit")
    func submitPollsThenDelivers() async {
        let service = MockPackOrderService(getSequence: [.mockPending, .mockDelivered])
        let vm = makeOrderPackViewModel(service: service)
        vm.prompt = "History of the Roman Empire in ten questions"

        let task = Task { await vm.submit() }
        // The VM publishes `.polling` then sleeps 1s before the next getOrder,
        // so observe within that window (cap generously; ~2s max).
        var sawPolling = false
        for _ in 0..<200 {
            if case .polling = vm.state { sawPolling = true; break }
            if case .delivered = vm.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await task.value

        #expect(sawPolling)
        guard case .delivered = vm.state else {
            Issue.record("expected .delivered, got \(vm.state)")
            return
        }
    }

    // A single transient blip (dropped packet on cellular, worker still waking)
    // must NOT dead-end a paid order that is still generating server-side — the
    // old code failed on the first throw, which invited a re-order / double
    // charge. Here getOrder throws once, then delivers: the poll must retry
    // through the blip and still reach `.delivered`.
    @Test("a single transient getOrder error is retried, not fatal — the poll still reaches .delivered")
    func transientPollErrorRetriesToDelivered() async {
        let service = MockPackOrderService(getResults: [.failure(.init("blip")), .success(.mockDelivered)])
        let vm = makeOrderPackViewModel(service: service)
        vm.pollIntervalSeconds = 0 // don't wait the real 1 Hz cadence for the retry
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .delivered(let snapshot) = vm.state else {
            Issue.record("expected .delivered after retrying a transient error, got \(vm.state)")
            return
        }
        #expect(snapshot.packId != nil)
    }

    // Distinct from submitNetworkError (which fails createOrder) and from a single
    // blip (retried above): here the order is created but EVERY `getOrder` throws.
    // A sustained run of errors past the tolerance must still surface `.failed`
    // rather than retry forever — bounded retry, not an infinite loop.
    @Test("a sustained run of getOrder errors past the tolerance surfaces .failed")
    func sustainedPollErrorsFail() async {
        let service = MockPackOrderService(getResult: .failure(.init("boom")))
        let vm = makeOrderPackViewModel(service: service)
        vm.pollIntervalSeconds = 0 // fast-forward the retries
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed after sustained errors, got \(vm.state)")
            return
        }
    }

    // An order stuck in in_progress (suspended worker, dropped job) would poll at
    // 1 Hz forever and never resolve the "Building your pack…" spinner. The overall
    // deadline must surface a soft `.failed` — the copy points the user at My packs
    // because generation may still be running server-side (not a hard failure).
    @Test("the poll deadline surfaces a soft .failed instead of spinning forever on a stuck order")
    func pollDeadlineSurfacesFailure() async {
        let service = MockPackOrderService(getResult: .success(.mockPending)) // never terminal
        let vm = makeOrderPackViewModel(service: service)
        vm.pollTimeoutSeconds = 0.05 // exhaust the budget almost immediately
        vm.pollIntervalSeconds = 0.01 // …after a few real poll iterations
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed(let message) = vm.state else {
            Issue.record("expected .failed from the deadline, got \(vm.state)")
            return
        }
        // Assert it's the deadline's soft copy, not a generic error — the message
        // is what tells the user the pack is still coming.
        #expect(message == String(localized: "Still working — check My packs later."))
    }

    // MARK: - Payment flow (#140)

    //
    // WHY: a user order must be authorised by a real StoreKit purchase, exactly
    // once — a double charge or an order created without payment are both
    // money bugs, the worst class this app has.

    @Test("user mode purchases once and the order intent carries the proof's transaction id")
    func userModePurchasesAndPassesProof() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService()
        let vm = makeOrderPackViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        #expect(purchase.purchaseCallCount == 1)
        guard let intent = service.capturedIntents.first else {
            Issue.record("createOrder was never called"); return
        }
        #expect(intent.paymentProof == MockPackPurchaseService.mockProof)
        // The server cross-checks body.transaction_id against the JWS — the
        // intent's idempotency key must BE the StoreKit transaction id.
        #expect(intent.idempotencyKey == MockPackPurchaseService.mockProof.transactionId)
    }

    @Test("a cancelled payment sheet surfaces .failed and never reaches the backend")
    func cancelledPurchaseNeverCreatesOrder() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService(purchaseResult: .failure(.cancelled))
        let vm = makeOrderPackViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed after a cancelled sheet, got \(vm.state)"); return
        }
        #expect(service.capturedIntents.isEmpty, "no payment → no order may be created")
    }

    @Test("a retry after a failed create reuses the pending proof — the user is not charged twice")
    func retryReusesPendingProof() async {
        let service = MockPackOrderService(createResult: .failure(.init("backend down")))
        let purchase = MockPackPurchaseService()
        let vm = makeOrderPackViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit() // pays, then create fails → proof stays pending
        await vm.submit() // retry must spend the SAME proof, not purchase again

        #expect(purchase.purchaseCallCount == 1)
        #expect(service.capturedIntents.count == 2)
        #expect(service.capturedIntents[0].idempotencyKey == service.capturedIntents[1].idempotencyKey,
                "both attempts must carry the same transaction id so the server dedupes")
    }

    @Test("a durably-pending proof from an earlier run is spent before any new charge")
    func pendingProofFromEarlierRunIsSpentFirst() async {
        let service = MockPackOrderService()
        let earlier = PackPaymentProof(transactionId: "990000000000777", productId: "pack_30", jws: "earlier.jws")
        let purchase = MockPackPurchaseService(pending: earlier)
        let vm = makeOrderPackViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        #expect(purchase.purchaseCallCount == 0, "an unspent paid transaction must be reused, never re-charged")
        #expect(service.capturedIntents.first?.paymentProof == earlier)
    }

    @Test("a successful order clears the pending proof")
    func successfulOrderClearsPendingProof() async {
        let purchase = MockPackPurchaseService()
        let vm = makeOrderPackViewModel(purchaseService: purchase, adminKeyAvailable: false)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        #expect(purchase.pendingProof() == nil,
                "an accepted order spends the proof — leaving it pending would replay it into the next order")
    }

    @Test("the Debug admin path skips payment entirely and sends an admin transaction id")
    func adminPathSkipsPayment() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService()
        let vm = makeOrderPackViewModel(service: service, purchaseService: purchase, adminKeyAvailable: true)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        #expect(purchase.purchaseCallCount == 0)
        guard let intent = service.capturedIntents.first else {
            Issue.record("createOrder was never called"); return
        }
        #expect(intent.paymentProof == nil)
        #expect(intent.idempotencyKey.hasPrefix("admin-"),
                "the server only accepts keyless orders whose transaction id is admin-prefixed")
    }
}
