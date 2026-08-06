//
//  OrderPackViewModelTests.swift
//  HangsTests
//
//  #95 custom-pack order VM, redesigned in #138. These tests encode WHY the
//  behaviour matters:
//  - The prompt only has to be non-empty (#138 B): the server enforces no
//    minimum, and the old 10-char floor rejected valid one-word topics. The
//    1000 ceiling stays.
//  - The purchase is irreversible, so once `submit()` runs NO public call may
//    walk the machine back to the form or the summary for that order — the
//    founder field test landed back on the form after ordering, one tap from
//    paying twice.
//  - Closing the sheet is not cancelling: an in-flight order must still be
//    in-flight when the sheet reopens, and a terminal one must reset to a fresh
//    form rather than re-showing a stale result.
//  - submit() must drive all the way to a terminal state — a stuck `.submitting`
//    strands the user on a spinner with a paid order in flight.
//  - A failed order and a network error must both surface as `.failed` (visible),
//    never crash the poll loop.
//  - A *transient* poll error must be retried, not treated as fatal: a paid order
//    is still generating server-side and a false `.failed` invites a double charge.
//  - The poll must not spin forever on a stuck in_progress order — an overall
//    deadline surfaces a soft `.failed` that points the user at My packs.
//  - "Try again" on an order that EXISTS server-side must retry that order, not
//    create (and charge for) a second one.
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

/// Drive the VM the way the sheet does: form → summary, parked on the payment
/// step so a test can call `submit()`. Defaults to the Debug admin path (no
/// StoreKit step) like `makeOrderPackViewModel`; payment tests pass
/// `adminKeyAvailable: false`.
@MainActor
private func payingViewModel(
    service: MockPackOrderService = MockPackOrderService(),
    purchaseService: MockPackPurchaseService = MockPackPurchaseService(),
    adminKeyAvailable: Bool = true,
    prompt: String = "History of the Roman Empire in ten questions"
) -> OrderPackViewModel {
    let vm = makeOrderPackViewModel(
        service: service,
        purchaseService: purchaseService,
        adminKeyAvailable: adminKeyAvailable
    )
    vm.prompt = prompt
    vm.advanceToSummary()
    return vm
}

/// Spin (briefly) until the VM reaches a state matching `predicate`.
@MainActor
@discardableResult
private func waitForState(
    _ vm: OrderPackViewModel,
    _ predicate: (OrderPackViewModel.OrderState) -> Bool
) async -> Bool {
    for _ in 0..<400 {
        if predicate(vm.state) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Fire every backwards affordance the sheet exposes and assert none of them
/// re-opens the pre-purchase steps.
@MainActor
private func expectNoRouteBackToForm(_ vm: OrderPackViewModel, _ what: String) {
    vm.backToEdit()
    vm.advanceToSummary()
    #expect(vm.state != .editing, "\(what): must never show the form again")
    #expect(vm.state != .confirming, "\(what): must never show the payment summary again")
}

@MainActor
@Suite("OrderPackViewModel")
struct OrderPackViewModelTests {

    // MARK: - Validation bounds

    @Test("a one-character prompt is valid — the 10-char floor is gone (#138)")
    func shortPromptIsValid() {
        let vm = makeOrderPackViewModel()
        vm.prompt = "a"
        #expect(vm.isValid)
    }

    @Test("an empty prompt is invalid — there is nothing to generate from")
    func emptyPromptIsInvalid() {
        let vm = makeOrderPackViewModel()
        vm.prompt = ""
        #expect(!vm.isValid)
    }

    @Test("a whitespace-only prompt is invalid — validation counts the TRIMMED text")
    func whitespacePromptIsInvalid() {
        let vm = makeOrderPackViewModel()
        vm.prompt = "   \n  "
        #expect(!vm.isValid)
    }

    @Test("prompt at the 1000-char ceiling is valid")
    func promptAtCeiling() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 1000)
        #expect(vm.isValid)
    }

    @Test("prompt above 1000 chars is invalid — the server ceiling still holds")
    func promptTooLong() {
        let vm = makeOrderPackViewModel()
        vm.prompt = String(repeating: "a", count: 1001)
        #expect(!vm.isValid)
    }

    // MARK: - Pre-purchase state machine

    @Test("an invalid prompt cannot reach the payment summary — nothing to pay for")
    func summaryRequiresValidPrompt() {
        let vm = makeOrderPackViewModel()
        vm.prompt = "  "

        vm.advanceToSummary()

        #expect(vm.state == .editing)
    }

    @Test("summary → back → summary works while the order is still unpaid")
    func summaryAndBackBeforePurchase() {
        let vm = makeOrderPackViewModel()
        vm.prompt = "Space for kids"

        vm.advanceToSummary()
        #expect(vm.state == .confirming)

        vm.backToEdit()
        #expect(vm.state == .editing, "the summary is the last screen with a way back")

        vm.advanceToSummary()
        #expect(vm.state == .confirming)
    }

    @Test("submit is refused from the form — payment only happens from the summary")
    func submitRequiresSummary() async {
        let service = MockPackOrderService()
        let vm = makeOrderPackViewModel(service: service)
        vm.prompt = "Space for kids"

        await vm.submit() // still .editing

        #expect(vm.state == .editing)
        #expect(service.createOrderCallCount == 0, "no order may be created from the form step")
    }

    // MARK: - Post-purchase irreversibility (the #138 core invariant)

    // WHY: this is the founder's field-test bug. Once the order is in flight it
    // is paid for; a route back to the form (or the summary) is a route to a
    // second charge. No public call may produce one.
    @Test("once an order is in flight, no public call reaches the form or the summary again")
    func inFlightOrderCannotReturnToForm() async {
        // Never-terminal poll + a slow create, so both in-flight states are
        // observable deterministically rather than raced against an instant mock.
        let service = MockPackOrderService(getResult: .success(.mockPending), createDelaySeconds: 0.1)
        let vm = payingViewModel(service: service)
        vm.pollIntervalSeconds = 0.01

        let task = Task { await vm.submit() }

        #expect(await waitForState(vm) { $0 == .submitting })
        expectNoRouteBackToForm(vm, "a purchase in flight")
        // Reopening the sheet mid-purchase shows the purchase, not the form.
        vm.prepareForPresentation(defaultLanguage: "sk")
        #expect(vm.state == .submitting)

        #expect(await waitForState(vm) { if case .polling = $0 { return true } else { return false } })
        expectNoRouteBackToForm(vm, "a generating order")
        vm.prepareForPresentation(defaultLanguage: "sk")
        guard case .polling = vm.state else {
            Issue.record("reopening the sheet dropped a generating order: \(vm.state)")
            return
        }

        // Only stop() cancels the poll — cancelling the caller's task doesn't,
        // which is exactly why dismissing the sheet keeps the order alive.
        vm.stop()
        await task.value
    }

    // WHY: reopening the sheet on a still-running order must land on live
    // progress, not a blank form — dismissing the sheet is not cancelling.
    // WHY: a delivered/failed order is finished business. Reopening "Create a
    // pack" must start a NEW order rather than re-show the old result — and it
    // must mint a new server-side order id so the next submit is a new purchase.
    @Test("reopening after a terminal order resets to a fresh form, keeping the typed topic")
    func prepareForPresentationResetsTerminalStates() async {
        let vm = payingViewModel()
        await vm.submit()
        guard case .delivered = vm.state else {
            Issue.record("expected .delivered, got \(vm.state)")
            return
        }

        // A delivered order is still not walk-back-able on its own…
        expectNoRouteBackToForm(vm, "a delivered order")

        // …only reopening the sheet starts a new one.
        vm.prepareForPresentation(defaultLanguage: "sk")

        #expect(vm.state == .editing)
        #expect(vm.orderId == nil, "a fresh form must not still point at the finished order")
        #expect(!vm.prompt.isEmpty, "the typed topic is kept — retyping it is pure friction")
        #expect(vm.language == "sk", "a fresh order follows the current quiz language again")
    }

    // MARK: - Language preselection

    @Test("the form preselects the global quiz language, and an explicit pick survives reopen")
    func languagePreselection() {
        let vm = makeOrderPackViewModel()

        vm.prepareForPresentation(defaultLanguage: "sk")
        #expect(vm.language == "sk")

        vm.selectLanguage("de")
        vm.prepareForPresentation(defaultLanguage: "sk")
        #expect(vm.language == "de", "an explicit choice must not be stomped on reopen")
    }

    @Test("an unsupported quiz language falls back to English rather than reaching the server")
    func unsupportedLanguageFallsBack() {
        let vm = makeOrderPackViewModel()
        vm.prepareForPresentation(defaultLanguage: "xx")
        #expect(vm.language == "en")
    }

    // MARK: - Dismissal rules

    @Test("only the in-flight payment blocks swipe-to-dismiss")
    func interactiveDismissRules() async {
        let vm = payingViewModel()
        #expect(vm.allowsInteractiveDismiss, "the summary is dismissible — nothing has been paid yet")

        await vm.submit()
        #expect(vm.allowsInteractiveDismiss, "a delivered pack is dismissible")

        // `.submitting` is the one blocked state: dismissing while the purchase
        // call is in flight leaves the user unsure whether they were charged.
        let submitting = payingViewModel(
            service: MockPackOrderService(createDelaySeconds: 0.1),
            prompt: "Space"
        )
        let task = Task { await submitting.submit() }
        #expect(await waitForState(submitting) { $0 == .submitting })
        #expect(
            !submitting.allowsInteractiveDismiss,
            "swipe-to-dismiss must be blocked while the purchase is in flight"
        )
        await task.value
    }

    // MARK: - submit lifecycle

    @Test("submit happy path reaches .delivered with a non-nil pack id")
    func submitDelivers() async {
        let vm = payingViewModel()

        await vm.submit()

        guard case .delivered(let snapshot) = vm.state else {
            Issue.record("expected .delivered, got \(vm.state)")
            return
        }
        #expect(snapshot.packId != nil)
    }

    @Test("a failed order surfaces as .failed, not a stuck poll")
    func submitFailedOrder() async {
        let service = MockPackOrderService(getResult: .success(.mockFailed))
        let vm = payingViewModel(service: service)

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
    }

    @Test("a network error surfaces as .failed rather than crashing")
    func submitNetworkError() async {
        let service = MockPackOrderService(createResult: .failure(.init("boom")))
        let vm = payingViewModel(service: service)

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
        let vm = payingViewModel(service: service)

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
        let vm = payingViewModel(service: service)
        vm.pollIntervalSeconds = 0 // don't wait the real 1 Hz cadence for the retry

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
        let vm = payingViewModel(service: service)
        vm.pollIntervalSeconds = 0 // fast-forward the retries

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
        let vm = payingViewModel(service: service)
        vm.pollTimeoutSeconds = 0.05 // exhaust the budget almost immediately
        vm.pollIntervalSeconds = 0.01 // …after a few real poll iterations

        await vm.submit()

        guard case .failed(let message, let retryable) = vm.state else {
            Issue.record("expected .failed from the deadline, got \(vm.state)")
            return
        }
        // Assert it's the deadline's soft copy, not a generic error — the message
        // is what tells the user the pack is still coming.
        #expect(message == String(localized: "Still working — check My packs later."))
        // WHY (review finding 2): the order is still pending/in_progress
        // server-side, and the backend's retry endpoint 409s anything that isn't
        // `failed`. Offering "Try again" here would hand the user a raw 409.
        #expect(retryable == false, "a timed-out (still generating) order must not offer a retry")
    }

    // WHY (review finding 2): the flag is not decoration — `retry()` itself must
    // refuse, so a stale tap or a future call site can't fire the doomed request.
    @Test("retry is refused on a non-retryable timeout — the backend would 409 it")
    func retryRefusedAfterTimeout() async {
        let service = MockPackOrderService(getResult: .success(.mockPending))
        let vm = payingViewModel(service: service)
        vm.pollTimeoutSeconds = 0.05
        vm.pollIntervalSeconds = 0.01

        await vm.submit()
        await vm.retry()

        #expect(service.retryOrderCallCount == 0)
        #expect(service.createOrderCallCount == 1, "and certainly no second paid order")
        guard case .failed(_, retryable: false) = vm.state else {
            Issue.record("expected the non-retryable failure to survive retry(), got \(vm.state)")
            return
        }
    }

    // WHY (review finding 1): THE double-charge door. Payment succeeded and the
    // order exists server-side; the poll then timed out. If reopening the sheet
    // reset to a fresh form, the next submit would purchase the SAME pack again.
    // The paid order — with its id and its status screen — must survive.
    @Test("paidFailedOrderSurvivesReopen_noSecondCharge")
    func paidFailedOrderSurvivesReopenNoSecondCharge() async {
        let service = MockPackOrderService(getResult: .success(.mockPending)) // never terminal
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollTimeoutSeconds = 0.05
        vm.pollIntervalSeconds = 0.01

        await vm.submit()
        guard case .failed = vm.state else {
            Issue.record("expected .failed from the deadline, got \(vm.state)")
            return
        }
        let paidOrderId = vm.orderId
        #expect(paidOrderId != nil, "the order was created — this is a PAID order")

        // User closes the sheet and reopens "Create a pack".
        vm.prepareForPresentation(defaultLanguage: "sk")

        // The invariant this test protects is the MONEY one: the paid order is
        // still the one on screen, and nothing has queued a second charge.
        // (Reopening now resumes the poll rather than freezing on the failure —
        // see reopenAfterTimeoutResumesPolling — so the state may be .polling.)
        expectNoRouteBackToForm(vm, "a paid, timed-out order")
        #expect(vm.orderId == paidOrderId, "the paid order must stay addressable")
        #expect(purchase.purchaseCallCount == 1, "reopening must not have set up a second purchase")
        #expect(service.createOrderCallCount == 1, "and must not create a second order")
        vm.stop()
    }

    // WHY: the soft timeout means "still generating", so the sheet must be able
    // to catch up with the order instead of parking the user on "Still working"
    // with no way forward. Reopening resumes the poll on a fresh budget — the
    // same dismiss ≠ cancel promise the Preparing screen already makes.
    @Test("reopening after a timeout resumes polling and reaches the delivered pack")
    func reopenAfterTimeoutResumesPolling() async {
        let service = MockPackOrderService(getResult: .success(.mockDelivered))
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollTimeoutSeconds = 0 // budget already spent when the poll starts

        await vm.submit()
        guard case .failed(_, retryable: false) = vm.state else {
            Issue.record("expected the soft timeout, got \(vm.state)")
            return
        }

        vm.pollTimeoutSeconds = 5 // reopening grants a fresh budget
        vm.pollIntervalSeconds = 0
        vm.prepareForPresentation(defaultLanguage: "sk")

        #expect(await waitForState(vm) { if case .delivered = $0 { return true } else { return false } },
                "the resumed poll must pick the finished pack up, got \(vm.state)")
        #expect(purchase.purchaseCallCount == 1, "resuming a poll is not a purchase")
        #expect(service.createOrderCallCount == 1, "resuming a poll is not a new order")
    }

    // WHY: a resumed poll that times out again must land back on the same honest
    // non-retryable failure — not a retryable one whose "Try again" the backend
    // would 409, and not a reset form that would charge again.
    @Test("a resumed poll that times out again returns to the non-retryable failure")
    func reopenAfterTimeoutCanTimeOutAgain() async {
        let service = MockPackOrderService(getResult: .success(.mockPending)) // never terminal
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollTimeoutSeconds = 0
        vm.pollIntervalSeconds = 0.01

        await vm.submit()
        let paidOrderId = vm.orderId

        vm.prepareForPresentation(defaultLanguage: "sk")

        #expect(await waitForState(vm) {
            if case .failed(_, retryable: false) = $0 { return true } else { return false }
        }, "expected the soft timeout again, got \(vm.state)")
        #expect(vm.orderId == paidOrderId)
        #expect(purchase.purchaseCallCount == 1)
        #expect(service.createOrderCallCount == 1)
    }

    // WHY: the guard must be narrow. A failure with nothing paid for (create
    // never landed AND no pending proof) is genuinely finished business, so
    // reopening still gives a fresh form instead of stranding the user on an
    // error screen forever.
    @Test("an unpaid failure still resets to a fresh form on reopen")
    func unpaidFailureStillResetsOnReopen() async {
        let service = MockPackOrderService(createResult: .failure(.init("boom")))
        let vm = payingViewModel(service: service) // admin path: no proof, no charge

        await vm.submit()
        #expect(vm.orderId == nil)

        vm.prepareForPresentation(defaultLanguage: "sk")

        #expect(vm.state == .editing)
    }

    // WHY: a create that failed AFTER a successful purchase leaves an unspent
    // proof. Resetting there would drop the user back on the form, where the
    // pending-proof reuse is fine — but the failed screen's "Try again" is the
    // path that actually spends it, so the state must be kept.
    @Test("a failure holding an unspent payment proof is kept, not reset")
    func failureWithPendingProofIsKept() async {
        let service = MockPackOrderService(createResult: .failure(.init("backend down")))
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit()
        #expect(vm.orderId == nil)
        #expect(purchase.pendingProof() != nil, "paid, but the order never landed")

        vm.prepareForPresentation(defaultLanguage: "sk")

        guard case .failed = vm.state else {
            Issue.record("a paid-but-unordered attempt was reset to \(vm.state)")
            return
        }
    }

    // MARK: - Try again

    // WHY: the order already exists (and was paid for) server-side, so "Try
    // again" must re-enqueue THAT order. Falling through to createOrder would
    // mint a second paid order for one purchase.
    @Test("retry on an existing order re-enqueues it instead of creating a second paid order")
    func retryUsesBackendRetryWhenOrderExists() async {
        let service = MockPackOrderService(getResults: [
            .success(.mockFailed),   // first poll: the order failed
            .success(.mockDelivered) // after the retry: it delivers
        ])
        let vm = payingViewModel(service: service)
        vm.pollIntervalSeconds = 0

        await vm.submit()
        guard case .failed = vm.state else {
            Issue.record("expected .failed before retrying, got \(vm.state)")
            return
        }

        await vm.retry()

        #expect(service.retryOrderCallCount == 1)
        #expect(service.createOrderCallCount == 1, "retry must not create a second order")
        guard case .delivered = vm.state else {
            Issue.record("expected .delivered after retry, got \(vm.state)")
            return
        }
    }

    // WHY (#140 + #138): the retry endpoint authorises on the SAME StoreKit JWS
    // the order was created with. Retrying with no proof would 401 in a user
    // build, dead-ending a pack the user already paid for.
    @Test("retrying a paid order sends the proof that created it, not a new purchase")
    func retryCarriesTheOriginalPaymentProof() async {
        let service = MockPackOrderService(getResults: [
            .success(.mockFailed),
            .success(.mockDelivered)
        ])
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0

        await vm.submit()
        await vm.retry()

        #expect(purchase.purchaseCallCount == 1, "a retry of a paid order must never charge again")
        #expect(service.capturedRetryProofs == [MockPackPurchaseService.mockProof])
    }

    // MARK: - Retained credentials lifecycle (#146)

    //
    // WHY: the view model now lives for the whole app session (it moved off
    // SettingsView's `@State` so a live order survives a quiz start). Anything
    // it keeps for a settled order therefore lingers indefinitely instead of
    // dying with the screen — so a StoreKit proof must be dropped the moment
    // the order can never run again.

    @Test("a delivered order drops the proof and the order id it was holding")
    func deliveredOrderClearsRetainedCredentials() async {
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0

        await vm.submit()

        guard case .delivered = vm.state else {
            Issue.record("expected .delivered, got \(vm.state)"); return
        }
        #expect(vm.orderPaymentProof == nil, "a delivered order can never be retried — its proof is dead weight")
        #expect(vm.orderId == nil)
    }

    // WHY: a `failed` order is the ONE case that must keep what it holds — the
    // order id is the retry target and the proof still authorises it.
    @Test("a failed order keeps its order id and proof — that is what Try again re-enqueues")
    func failedOrderKeepsRetainedCredentials() async {
        let service = MockPackOrderService(getResult: .success(.mockFailed))
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0

        await vm.submit()

        guard case .failed(_, retryable: true) = vm.state else {
            Issue.record("expected a retryable .failed, got \(vm.state)"); return
        }
        #expect(vm.orderId != nil)
        #expect(vm.orderPaymentProof != nil)
    }

    // WHY: the retry endpoint 409s a refunded order, so "Try again" there is a
    // lie — and with nothing retained, a retry would fall through to a second
    // paid create (the #138 double-charge door).
    @Test("a refunded order offers no retry and keeps nothing")
    func refundedOrderIsTerminalAndCleared() async {
        let service = MockPackOrderService(getResult: .success(.mockRefunded))
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0

        await vm.submit()

        guard case .failed(_, retryable: false) = vm.state else {
            Issue.record("expected a non-retryable .failed, got \(vm.state)"); return
        }
        #expect(vm.orderId == nil)
        #expect(vm.orderPaymentProof == nil)

        await vm.retry()
        #expect(service.createOrderCallCount == 1, "a refunded order must never fall through to a second paid create")
        #expect(service.retryOrderCallCount == 0)
    }

    // WHY: once the backend refuses to spend more on the order (422 — manual
    // retry cap or spend ceiling) the failure is FINAL. Keeping "Try again"
    // alive would just re-refuse, and the proof would linger for the session.
    @Test("a 422 retry refusal ends the order — no further retry offered, nothing retained")
    func retryBudgetRefusalIsTerminal() async {
        let service = MockPackOrderService(
            getResults: [.success(.mockFailed)],
            retryFailure: .retryRefused("manual retry budget exhausted")
        )
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0

        await vm.submit()
        await vm.retry()

        guard case let .failed(message, retryable: false) = vm.state else {
            Issue.record("expected a non-retryable .failed, got \(vm.state)"); return
        }
        #expect(message == "manual retry budget exhausted", "the backend's reason must reach the user")
        #expect(vm.orderId == nil)
        #expect(vm.orderPaymentProof == nil)
    }

    // WHY: if the create call itself never landed there is no order to retry —
    // resubmitting the same intent replays the SAME idempotency key, so a
    // create that did land server-side is replayed rather than duplicated.
    @Test("retry after a failed create resubmits the order instead of calling the retry endpoint")
    func retryResubmitsWhenNoOrderExists() async {
        let service = MockPackOrderService(createResult: .failure(.init("boom")))
        let vm = payingViewModel(service: service)

        await vm.submit()
        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
        #expect(vm.orderId == nil)

        await vm.retry()

        #expect(service.retryOrderCallCount == 0, "there is no server-side order to retry")
        #expect(service.createOrderCallCount == 2)
    }

    @Test("retry is a no-op outside the failed state — it must never re-trigger a live order")
    func retryOnlyFromFailed() async {
        let service = MockPackOrderService()
        let vm = payingViewModel(service: service)

        await vm.retry() // still .confirming

        #expect(vm.state == .confirming)
        #expect(service.createOrderCallCount == 0)
        #expect(service.retryOrderCallCount == 0)
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
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

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

    // ADAPTED from #140's cancel→.failed (#138 merge decision): dismissing the
    // App Store sheet charges nothing, so it is not a failure — the user lands
    // back on the payment summary they came from and can pay or leave. The
    // no-way-back rule starts at a SUCCESSFUL payment. What must NOT change:
    // no order may reach the backend without payment.
    @Test("a cancelled payment sheet returns to the summary and never reaches the backend")
    func cancelledPurchaseReturnsToSummary() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService(purchaseResult: .failure(.cancelled))
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit()

        #expect(vm.state == .confirming, "cancelling charges nothing — it is a step back, not a failure")
        #expect(service.capturedIntents.isEmpty, "no payment → no order may be created")
        // …and the user can still pay from there.
        #expect(vm.allowsInteractiveDismiss)
    }

    // WHY: only a *cancellation* is benign. A real purchase failure (store
    // outage, unverified receipt, Ask-to-Buy pending) must surface as .failed
    // so the user sees the reason instead of a silently unchanged Pay button.
    @Test("a non-cancel purchase error surfaces .failed, not the summary")
    func purchaseErrorSurfacesFailed() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService(purchaseResult: .failure(.productUnavailable))
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed after a purchase error, got \(vm.state)"); return
        }
        #expect(service.capturedIntents.isEmpty)
    }

    // ADAPTED from #140 (which called submit() twice): after a failed create the
    // machine is in .failed, and "Try again" is retry() — submit() is guarded to
    // the summary step now. The invariant is unchanged: the second attempt spends
    // the SAME proof, so the user is charged once.
    @Test("a retry after a failed create reuses the pending proof — the user is not charged twice")
    func retryReusesPendingProof() async {
        let service = MockPackOrderService(createResult: .failure(.init("backend down")))
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit() // pays, then create fails → proof stays pending
        await vm.retry()  // must spend the SAME proof, not purchase again

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
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit()

        #expect(purchase.purchaseCallCount == 0, "an unspent paid transaction must be reused, never re-charged")
        #expect(service.capturedIntents.first?.paymentProof == earlier)
    }

    @Test("a successful order clears the pending proof")
    func successfulOrderClearsPendingProof() async {
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(purchaseService: purchase, adminKeyAvailable: false)

        await vm.submit()

        #expect(purchase.pendingProof() == nil,
                "an accepted order spends the proof — leaving it pending would replay it into the next order")
    }

    @Test("the Debug admin path skips payment entirely and sends an admin transaction id")
    func adminPathSkipsPayment() async {
        let service = MockPackOrderService()
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: true)

        await vm.submit()

        #expect(purchase.purchaseCallCount == 0)
        guard let intent = service.capturedIntents.first else {
            Issue.record("createOrder was never called"); return
        }
        #expect(intent.paymentProof == nil)
        #expect(intent.idempotencyKey.hasPrefix("admin-"),
                "the server only accepts keyless orders whose transaction id is admin-prefixed")
    }

    // WHY (#138 rule 3 under #140 payment): a SUCCESSFUL payment is the point of
    // no return even when a pending proof would make a re-order free — the user
    // must not be able to walk back into the form mid-order and re-drive it.
    @Test("after a successful payment there is still no route back to the form")
    func paidOrderCannotReturnToForm() async {
        let service = MockPackOrderService(getResult: .success(.mockPending), createDelaySeconds: 0.1)
        let purchase = MockPackPurchaseService()
        let vm = payingViewModel(service: service, purchaseService: purchase, adminKeyAvailable: false)
        vm.pollIntervalSeconds = 0.01

        let task = Task { await vm.submit() }
        #expect(await waitForState(vm) { if case .polling = $0 { return true } else { return false } })
        expectNoRouteBackToForm(vm, "a paid order")

        vm.stop()
        await task.value
    }
}
