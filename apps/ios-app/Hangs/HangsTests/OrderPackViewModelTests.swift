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
//

@testable import Hangs
import Testing

@MainActor
private func makeOrderPackViewModel(
    service: MockPackOrderService = MockPackOrderService()
) -> OrderPackViewModel {
    OrderPackViewModel(service: service)
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

    // Distinct from submitNetworkError (which fails createOrder): here the order
    // is created but a `getOrder` throws mid-poll. The poll leg's own catch must
    // surface `.failed`, not crash or spin the loop forever.
    @Test("a network error DURING polling surfaces as .failed — the poll-leg catch")
    func pollNetworkError() async {
        let service = MockPackOrderService(getResult: .failure(.init("boom")))
        let vm = makeOrderPackViewModel(service: service)
        vm.prompt = "History of the Roman Empire in ten questions"

        await vm.submit()

        guard case .failed = vm.state else {
            Issue.record("expected .failed, got \(vm.state)")
            return
        }
    }
}
