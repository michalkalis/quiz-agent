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

@MainActor
private func makeOrderPackViewModel(
    service: MockPackOrderService = MockPackOrderService()
) -> OrderPackViewModel {
    OrderPackViewModel(service: service)
}

/// Drive the VM the way the sheet does: form → summary → pay.
@MainActor
private func payingViewModel(
    service: MockPackOrderService = MockPackOrderService(),
    prompt: String = "History of the Roman Empire in ten questions"
) -> OrderPackViewModel {
    let vm = OrderPackViewModel(service: service)
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

        guard case .failed(let message) = vm.state else {
            Issue.record("expected .failed from the deadline, got \(vm.state)")
            return
        }
        // Assert it's the deadline's soft copy, not a generic error — the message
        // is what tells the user the pack is still coming.
        #expect(message == String(localized: "Still working — check My packs later."))
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
}
