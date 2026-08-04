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
@testable import Hangs
import os
import Testing

private nonisolated enum Stubs {
    static let baseURL = "http://test.invalid"

    static let orderId = "11111111-1111-1111-1111-111111111111"

    static let createdJSON = #"""
    {
      "order_id": "11111111-1111-1111-1111-111111111111",
      "status": "pending",
      "created_at": "2026-07-17T10:00:00Z"
    }
    """#

    /// A single `GET /v1/orders/{id}` payload — the poll target.
    static let snapshotJSON = #"""
    {
      "order_id": "11111111-1111-1111-1111-111111111111",
      "status": "in_progress",
      "product_id": "pack_30",
      "target_count": 30,
      "language": "en",
      "category": null,
      "theme": null,
      "created_at": "2026-07-17T10:00:00Z",
      "delivered_at": null,
      "pack_id": null,
      "llm_cost_usd": null,
      "search_cost_cents": 0,
      "job": null
    }
    """#

    static let listJSON = #"""
    { "orders": [] }
    """#
}

// MARK: - PackOrderStubAuthService

/// Deterministic auth service for the refresh-retry tests: hands out one fixed
/// access token and, on refresh, whatever the test seeded — a fresh token, or the
/// same stale one to model a refresh that cannot recover the session. Counts
/// refreshes so a test can pin "refreshed exactly once".
private actor PackOrderStubAuthService: AuthServiceProtocol {
    private let initialToken: String
    private let refreshedToken: String?
    private var refreshes = 0

    init(initialToken: String, refreshedToken: String?) {
        self.initialToken = initialToken
        self.refreshedToken = refreshedToken
    }

    func accessToken() async -> String? { initialToken }

    func refreshedAccessToken(replacing _: String) async -> String? {
        refreshes += 1
        return refreshedToken
    }

    func refreshCallCount() -> Int { refreshes }
}

/// The `Authorization` header of a captured request, or nil when none was sent.
private nonisolated func capturedBearer(_ request: URLRequest) -> String? {
    request.value(forHTTPHeaderField: "Authorization")
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
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
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
    override nonisolated init(
        request: URLRequest,
        cachedResponse: CachedURLResponse?,
        client: (any URLProtocolClient)?
    ) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    private nonisolated static let handlerLock = OSAllocatedUnfairLock<
        ((@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        )
    >(initialState: nil)

    nonisolated static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { $0 } }
        set { handlerLock.withLock { $0 = newValue } }
    }

    override nonisolated class func canInit(with _: URLRequest) -> Bool { true }

    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override nonisolated func startLoading() {
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

    override nonisolated func stopLoading() {}

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PackOrderStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// Both sections live in ONE suite on purpose: `.serialized` only orders tests
// *within* a suite, and they share `PackOrderStubURLProtocol`'s process-wide
// handler — a second suite would run in parallel and stomp it (see the protocol's
// header comment).
@Suite("PackOrderService — idempotency (#103 finding 6) + auth refresh (#133 V16)", .serialized)
struct PackOrderServiceTests {
    private func makeService(
        authService: AuthServiceProtocol? = nil,
        adminKey: String? = nil
    ) -> PackOrderService {
        PackOrderService(
            baseURL: Stubs.baseURL,
            session: PackOrderStubURLProtocol.makeSession(),
            authService: authService,
            adminKey: { adminKey }
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

    // MARK: 4. Expired bearer → refresh once and retry (#133 V16)

    //
    // WHY: `AuthService.accessToken()` never checks `exp` — refresh is purely
    // reactive — and `OrderPackViewModel` polls `getOrder` at 1 Hz for the whole
    // generation, so a mid-poll expiry is routine, not exotic. These three
    // requests used to bypass the 401-refresh-retry convention that
    // NetworkService and AuthService both implement, so every expiry became a
    // `PackOrderError.server` that ate the poller's tolerated-failure budget and
    // dead-ended a PAID pack order on an opaque message.

    /// Returns a handler that 401s any bearer other than `acceptedBearer`, and
    /// records every bearer it saw.
    private func bearerGatedHandler(
        acceptedBearer: String,
        body: String,
        okStatus: Int = 200,
        seen: OSAllocatedUnfairLock<[String?]>
    ) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { req in
            let bearer = capturedBearer(req)
            seen.withLock { $0.append(bearer) }
            guard bearer == acceptedBearer else {
                return (.make(status: 401), Data(#"{"detail": "Not authenticated"}"#.utf8))
            }
            return (.make(status: okStatus), Data(body.utf8))
        }
    }

    @Test("a mid-poll 401 refreshes the access token and retries once — getOrder succeeds transparently")
    func expiredBearerOnPollRefreshesAndRetries() async throws {
        let auth = PackOrderStubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let service = makeService(authService: auth)
        let seen = OSAllocatedUnfairLock<[String?]>(initialState: [])

        PackOrderStubURLProtocol.handler = bearerGatedHandler(
            acceptedBearer: "Bearer fresh", body: Stubs.snapshotJSON, seen: seen
        )
        defer { PackOrderStubURLProtocol.handler = nil }

        let snapshot = try await service.getOrder(id: Stubs.orderId)

        #expect(snapshot.orderId == Stubs.orderId, "the poll must succeed on the retry, not surface the 401")
        #expect(await auth.refreshCallCount() == 1, "exactly one refresh — not one per poll iteration")
        #expect(seen.withLock { $0 } == ["Bearer stale", "Bearer fresh"],
                "the retry must carry the REFRESHED bearer, not re-send the stale one")
    }

    @Test("createOrder and listOrders route through the same refresh-and-retry")
    func createAndListAlsoRefreshAndRetry() async throws {
        let createAuth = PackOrderStubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let createSeen = OSAllocatedUnfairLock<[String?]>(initialState: [])
        PackOrderStubURLProtocol.handler = bearerGatedHandler(
            acceptedBearer: "Bearer fresh", body: Stubs.createdJSON, okStatus: 202, seen: createSeen
        )
        let created = try await makeService(authService: createAuth)
            .createOrder(intent: PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil))
        PackOrderStubURLProtocol.handler = nil

        #expect(created.orderId == Stubs.orderId)
        #expect(await createAuth.refreshCallCount() == 1)
        #expect(createSeen.withLock { $0 }.count == 2)

        let listAuth = PackOrderStubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let listSeen = OSAllocatedUnfairLock<[String?]>(initialState: [])
        PackOrderStubURLProtocol.handler = bearerGatedHandler(
            acceptedBearer: "Bearer fresh", body: Stubs.listJSON, seen: listSeen
        )
        defer { PackOrderStubURLProtocol.handler = nil }
        let orders = try await makeService(authService: listAuth).listOrders()

        #expect(orders.isEmpty)
        #expect(await listAuth.refreshCallCount() == 1)
        #expect(listSeen.withLock { $0 }.count == 2)
    }

    @Test("a 401 that survives the refresh surfaces as an auth failure, not an opaque server error")
    func secondUnauthorizedSurfacesAuthFailure() async throws {
        // The refresh hands back the same dead token → the retry 401s too.
        let auth = PackOrderStubAuthService(initialToken: "stale", refreshedToken: "stale")
        let service = makeService(authService: auth)
        let seen = OSAllocatedUnfairLock<[String?]>(initialState: [])

        PackOrderStubURLProtocol.handler = bearerGatedHandler(
            acceptedBearer: "Bearer fresh", body: Stubs.snapshotJSON, seen: seen
        )
        defer { PackOrderStubURLProtocol.handler = nil }

        do {
            _ = try await service.getOrder(id: Stubs.orderId)
            Issue.record("expected PackOrderError.unauthorized")
        } catch let error as PackOrderError {
            guard case .unauthorized = error else {
                Issue.record("expected .unauthorized, got \(error)"); return
            }
        }
        // Exactly one retry, never a loop — and the user is told to sign in again
        // rather than shown the generic "the pack service returned an error".
        #expect(seen.withLock { $0 }.count == 2)
        #expect(await auth.refreshCallCount() == 1)
    }

    // MARK: 5. Order authorisation headers (#140)

    //
    // WHY: the user flow must be authorised by the StoreKit JWS and NEVER by
    // the admin key — an admin header in a user build is a free-packs door.
    // The user-mode test injects an available admin key on purpose, proving a
    // stored key's mere presence doesn't leak into a paid order's request.

    @Test("user mode (payment proof) sends X-StoreKit-JWS and the proof's ids — never X-Admin-Key")
    func userModeSendsJWSNeverAdminKey() async throws {
        let service = makeService(adminKey: "seeded-admin-key")
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)

        PackOrderStubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 202), Data(Stubs.createdJSON.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        let proof = PackPaymentProof(transactionId: "990000000000123", productId: "pack_30", jws: "header.payload.sig")
        let intent = PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil, paymentProof: proof)
        _ = try await service.createOrder(intent: intent)

        let request = try #require(captured.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-JWS") == proof.jws)
        #expect(request.value(forHTTPHeaderField: "X-Admin-Key") == nil,
                "a stored admin key must NOT ride along on a paid user order")
        // The server 400s unless body ids match the JWS payload exactly.
        let body = try #require(readRequestBody(request))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["transaction_id"] as? String == proof.transactionId)
        #expect(json["product_id"] as? String == proof.productId)
    }

    @Test("no proof (Debug admin path) sends X-Admin-Key and no JWS header")
    func adminModeSendsAdminKeyNoJWS() async throws {
        let service = makeService(adminKey: "seeded-admin-key")
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)

        PackOrderStubURLProtocol.handler = { req in
            captured.withLock { $0 = req }
            return (.make(status: 202), Data(Stubs.createdJSON.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        let intent = PackOrderIntent(prompt: "History of Rome", language: "en", category: nil, theme: nil)
        _ = try await service.createOrder(intent: intent)

        let request = try #require(captured.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "X-Admin-Key") == "seeded-admin-key")
        #expect(request.value(forHTTPHeaderField: "X-StoreKit-JWS") == nil)
        let transactionId = try #require(capturedTransactionId(request))
        #expect(transactionId.hasPrefix("admin-"),
                "keyless synthetic orders must stay in the server's admin- id namespace")
    }

    @Test("a non-401 failure is unchanged — still PackOrderError.server with the backend detail, no refresh")
    func nonAuthErrorUnchangedAndNeverRefreshes() async throws {
        let auth = PackOrderStubAuthService(initialToken: "stale", refreshedToken: "fresh")
        let service = makeService(authService: auth)

        PackOrderStubURLProtocol.handler = { _ in
            (.make(status: 500), Data(#"{"detail": "generation worker down"}"#.utf8))
        }
        defer { PackOrderStubURLProtocol.handler = nil }

        do {
            _ = try await service.getOrder(id: Stubs.orderId)
            Issue.record("expected PackOrderError.server")
        } catch let error as PackOrderError {
            guard case let .server(message) = error else {
                Issue.record("expected .server, got \(error)"); return
            }
            #expect(message == "generation worker down", "the backend detail must still reach the user")
        }
        #expect(await auth.refreshCallCount() == 0, "a 500 is not a credential problem — refreshing would hide it")
    }
}
