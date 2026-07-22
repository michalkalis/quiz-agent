//
//  PackOrderServiceTests.swift
//  HangsTests
//
//  URLProtocol-stubbed unit tests for PackOrderService's client idempotency
//  fix (issue #103 finding 6). Before this fix, `createOrder` minted a fresh
//  `admin-<uuid>` transaction id on every call, so a client-side retry after a
//  network timeout could never be deduped by the server's `transaction_id`
//  dedup (quiz-pack-api orders.py) — a retry mints a second, separately-billed
//  order and a second generation run. These tests prove:
//  1. the SAME intent sends the SAME `transaction_id` across repeated calls
//     (the retry-safety property),
//  2. a DIFFERENT intent sends a DIFFERENT `transaction_id` (no over-collapsing
//     of genuinely distinct orders),
//  3. a second `createOrder` for the SAME intent, issued while the first is
//     still in flight, does not fire a second network request (the in-flight
//     guard) and both callers observe the same result.
//

import Foundation
import os
@testable import Hangs
import Testing

private nonisolated enum Stubs {
    static let baseURL = "http://test.invalid"

    static let createdJSON = #"""
    {
      "order_id": "11111111-1111-1111-1111-111111111111",
      "status": "pending",
      "created_at": "2026-07-17T10:00:00Z"
    }
    """#
}

/// URLSession sometimes moves httpBody to httpBodyStream before handing the
/// request to URLProtocol. Reads whichever is present (mirrors the
/// NetworkServiceTests helper). Free function so it can be captured by
/// @Sendable URLProtocol handler closures without a self-capture concern.
private nonisolated func readRequestBody(_ request: URLRequest) -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: bufSize)
        guard n > 0 else { break }
        data.append(buffer, count: n)
    }
    return data.isEmpty ? nil : data
}

/// Extracts `transaction_id` from a captured request's JSON body, or nil if
/// the body is missing/undecodable.
private nonisolated func capturedTransactionId(_ request: URLRequest) -> String? {
    guard let data = readRequestBody(request),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json["transaction_id"] as? String
}

// MARK: - PackOrderStubURLProtocol

//
// A dedicated URLProtocol with its OWN process-wide handler, independent of
// NetworkServiceTests' shared `StubURLProtocol`. Swift Testing runs separate
// suites in parallel and `.serialized` only orders tests *within* a suite, so
// two suites sharing one static handler race each other (one suite's
// `handler = …` / `defer = nil` stomps the other's → wrong response or
// NSURLError -1011). Mirrors the AttestStubURLProtocol/AppleStubURLProtocol/
// AuthStubURLProtocol split the auth suites already use. Kept a byte-for-byte
// clone of the original `StubURLProtocol` (synchronous startLoading) so the
// in-flight semaphore test below observes identical blocking semantics.
final class PackOrderStubURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated override init(
        request: URLRequest,
        cachedResponse: CachedURLResponse?,
        client: (any URLProtocolClient)?
    ) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    private nonisolated static let handlerLock = OSAllocatedUnfairLock<
        ((@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    )>(initialState: nil)

    nonisolated static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { $0 } }
        set { handlerLock.withLock { $0 = newValue } }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        guard let handler = PackOrderStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    nonisolated override func stopLoading() {}

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PackOrderStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

@Suite("PackOrderService — idempotency key stability (#103 finding 6)", .serialized)
struct PackOrderServiceTests {

    private func makeService() -> PackOrderService {
        PackOrderService(
            baseURL: Stubs.baseURL,
            session: PackOrderStubURLProtocol.makeSession(),
            authService: nil,
            adminKeyStore: AdminKeyStore()
        )
    }

    // MARK: 1. Same intent → same key across repeated calls

    @Test("two createOrder calls for the SAME intent send the SAME transaction_id")
    func sameIntentSameKey() async throws {
        let service = makeService()
        let capturedIds = OSAllocatedUnfairLock<[String]>(initialState: [])

        PackOrderStubURLProtocol.handler = { req in
            if let id = capturedTransactionId(req) {
                capturedIds.withLock { $0.append(id) }
            }
            return (.make(status: 202), Data(Stubs.createdJSON.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        let intent = PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil)

        _ = try await service.createOrder(intent: intent)
        _ = try await service.createOrder(intent: intent)

        let ids = capturedIds.withLock { $0 }
        try #require(ids.count == 2, "expected 2 captured requests, got \(ids)")
        #expect(ids[0] == intent.idempotencyKey)
        // The retry-safety property: a resubmit of the SAME intent (e.g. after
        // a perceived client timeout) must dedupe server-side, which only
        // works if the second call carries the identical key as the first.
        #expect(ids[0] == ids[1])
    }

    // MARK: 2. A new intent gets a new key

    @Test("a new intent sends a DIFFERENT transaction_id")
    func newIntentNewKey() async throws {
        let service = makeService()
        let capturedIds = OSAllocatedUnfairLock<[String]>(initialState: [])

        PackOrderStubURLProtocol.handler = { req in
            if let id = capturedTransactionId(req) {
                capturedIds.withLock { $0.append(id) }
            }
            return (.make(status: 202), Data(Stubs.createdJSON.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        let firstIntent = PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil)
        let secondIntent = PackOrderIntent(prompt: "Solar system facts", language: "en", category: nil, theme: nil)

        _ = try await service.createOrder(intent: firstIntent)
        _ = try await service.createOrder(intent: secondIntent)

        let ids = capturedIds.withLock { $0 }
        try #require(ids.count == 2, "expected 2 captured requests, got \(ids)")
        // A genuinely distinct order intent must NOT collapse into the
        // previous order's key — only a retry of the SAME intent should.
        #expect(ids[0] != ids[1])
        #expect(ids[0] == firstIntent.idempotencyKey)
        #expect(ids[1] == secondIntent.idempotencyKey)
    }

    // MARK: 3. In-flight guard blocks re-entry

    @Test("a second createOrder for the SAME intent while one is pending is a no-op — only one network call fires")
    func inFlightGuardBlocksReentry() async throws {
        let service = makeService()
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        // Blocks the (single) in-flight request open until the test explicitly
        // releases it, so the second createOrder call is guaranteed to observe
        // the first one still pending rather than racing to completion.
        let gate = DispatchSemaphore(value: 0)

        PackOrderStubURLProtocol.handler = { _ in
            callCount.withLock { $0 += 1 }
            gate.wait()
            return (.make(status: 202), Data(Stubs.createdJSON.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        let intent = PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil)

        async let first = service.createOrder(intent: intent)
        // Give the first call time to reach the actor's in-flight bookkeeping
        // and block inside the stub handler before the second call starts.
        try? await Task.sleep(for: .milliseconds(100))
        async let second = service.createOrder(intent: intent)
        // A further delay to let the second call reach the guard and start
        // awaiting the first task, THEN release the single blocked request.
        try? await Task.sleep(for: .milliseconds(100))
        gate.signal()

        let (firstResult, secondResult) = try await (first, second)

        #expect(callCount.withLock { $0 } == 1)
        #expect(firstResult.orderId == secondResult.orderId)
    }
}
