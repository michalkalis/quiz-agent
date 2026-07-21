//
//  AuthAttestTests.swift
//  HangsTests
//
//  URLProtocol-stubbed unit tests for the App Attest bootstrap flow
//  (issue #60 Part B, task 60.13). The real DCAppAttestService only runs on a
//  physical device, so AuthService is driven here with a MockAttestor that
//  stands in for the Secure-Enclave crypto. We verify the *flow* AuthService
//  orchestrates — challenge fetch, attestation vs assertion choice, keyId
//  persistence, and the assertion-rejected → re-attest recovery — not the
//  cryptography, which stays `[HUMAN]` device verification (60.14).
//

import Foundation
@testable import Hangs
import os
import Testing

// MARK: - AttestStubURLProtocol

//
// A dedicated URLProtocol with its OWN process-wide handler, independent of
// AuthServiceTests' AuthStubURLProtocol and NetworkServiceTests' StubURLProtocol.
// Swift Testing runs separate suites in parallel, so sharing one static handler
// across suites races them (NSURLError -1011 / wrong response). Independent
// statics + sessions let all three auth suites run concurrently and safely.

final class AttestStubURLProtocol: URLProtocol, @unchecked Sendable {
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
        let request = self.request
        DispatchQueue.global(qos: .userInitiated).async {
            guard let handler = Self.handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override nonisolated func stopLoading() {}

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AttestStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - MockAttestor

/// In-memory DeviceAttestor: records how many attestations/assertions it built
/// and owns a mutable keyId (the thing AuthService.confirmKey/forgetKey drive).
private final class MockAttestor: DeviceAttestor, @unchecked Sendable {
    private let supported: Bool
    private let state = OSAllocatedUnfairLock<(keyID: String?, attests: Int, asserts: Int)>(
        initialState: (nil, 0, 0)
    )

    init(supported: Bool = true, seededKeyID: String? = nil) {
        self.supported = supported
        state.withLock { $0.keyID = seededKeyID }
    }

    var isSupported: Bool { supported }
    func storedKeyID() -> String? { state.withLock { $0.keyID } }
    func confirmKey(_ keyID: String) { state.withLock { $0.keyID = keyID } }
    func forgetKey() { state.withLock { $0.keyID = nil } }

    var attestCount: Int { state.withLock { $0.attests } }
    var assertCount: Int { state.withLock { $0.asserts } }

    func credential(for mode: AttestCredential.Mode, challenge: String) async -> AttestCredential? {
        switch mode {
        case .attestation:
            state.withLock { $0.attests += 1 }
            return AttestCredential(
                mode: .attestation,
                keyID: "key-new",
                bootstrapBody: ["key_id": "key-new", "attestation": "att-blob", "challenge": challenge]
            )
        case .assertion:
            state.withLock { $0.asserts += 1 }
            guard let keyID = storedKeyID() else { return nil }
            return AttestCredential(
                mode: .assertion,
                keyID: keyID,
                bootstrapBody: ["key_id": keyID, "assertion": "asrt-blob", "challenge": challenge]
            )
        }
    }
}

// MARK: - In-memory token store

private final class MemTokenStore: TokenStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AuthTokens?>(initialState: nil)
    init(seed: AuthTokens? = nil) { lock.withLock { $0 = seed } }
    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}

// MARK: - Tests

@Suite("AuthService — App Attest bootstrap", .serialized)
struct AuthAttestTests {
    private nonisolated static let challengeJSON = #"{"challenge":"chal-1","expires_in":120}"#

    private nonisolated func tokenJSON(_ access: String, _ anon: String) -> String {
        #"""
        {"access_token":"\#(access)","refresh_token":"r-\#(access)","token_type":"bearer","expires_in":900,"anon_id":"\#(anon)"}
        """#
    }

    private func makeService(store: TokenStore, attestor: DeviceAttestor) -> AuthService {
        AuthService(
            baseURL: "http://test.invalid",
            session: AttestStubURLProtocol.makeSession(),
            store: store,
            attestor: attestor
        )
    }

    // MARK: 1. First launch → attestation, then keyId is persisted

    @Test("first launch attests, mints an identity, and persists the keyId")
    func firstLaunchAttests() async throws {
        let store = MemTokenStore()
        let attestor = MockAttestor(supported: true)
        let service = makeService(store: store, attestor: attestor)

        let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
        AttestStubURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            paths.withLock { $0.append(path) }
            if path == "/api/v1/auth/attest-challenge" {
                return (.make(status: 200), Data(Self.challengeJSON.utf8))
            }
            return (.make(status: 200), Data(self.tokenJSON("a1", "anon-1").utf8))
        }
        defer { AttestStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "a1")
        #expect(attestor.attestCount == 1)
        #expect(attestor.assertCount == 0)
        // keyId persisted only after the backend accepted the attestation.
        #expect(attestor.storedKeyID() == "key-new")
        // A challenge was fetched before bootstrapping.
        #expect(paths.withLock { $0 }.contains("/api/v1/auth/attest-challenge"))
    }

    // MARK: 2. Stored key → re-bootstrap uses an assertion, never re-mints

    @Test("a stored keyId re-bootstraps with an assertion, not a new attestation")
    func storedKeyAsserts() async throws {
        let store = MemTokenStore()
        let attestor = MockAttestor(supported: true, seededKeyID: "key-existing")
        let service = makeService(store: store, attestor: attestor)

        AttestStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/attest-challenge" {
                return (.make(status: 200), Data(Self.challengeJSON.utf8))
            }
            return (.make(status: 200), Data(self.tokenJSON("a2", "anon-2").utf8))
        }
        defer { AttestStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "a2")
        #expect(attestor.assertCount == 1)
        #expect(attestor.attestCount == 0)
        #expect(attestor.storedKeyID() == "key-existing")
    }

    // MARK: 3. Assertion rejected → forget the key and re-attest a fresh one

    @Test("a rejected assertion forgets the key and re-attests")
    func assertionRejectedReAttests() async throws {
        let store = MemTokenStore()
        let attestor = MockAttestor(supported: true, seededKeyID: "key-revoked")
        let service = makeService(store: store, attestor: attestor)

        let bootstrapCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        AttestStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/attest-challenge" {
                return (.make(status: 200), Data(Self.challengeJSON.utf8))
            }
            // First bootstrap (the assertion) is rejected; the re-attest succeeds.
            let n = bootstrapCalls.withLock { $0 += 1; return $0 }
            if n == 1 {
                return (.make(status: 401), Data())
            }
            return (.make(status: 200), Data(self.tokenJSON("a3", "anon-3").utf8))
        }
        defer { AttestStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "a3")
        #expect(attestor.assertCount == 1)
        #expect(attestor.attestCount == 1)
        // Recovered onto the fresh attested key.
        #expect(attestor.storedKeyID() == "key-new")
    }

    // MARK: 4. Unsupported (simulator) → plain bootstrap, no challenge fetched

    @Test("an unsupported attestor mints plainly without touching App Attest")
    func unsupportedMintsPlain() async throws {
        let store = MemTokenStore()
        let attestor = MockAttestor(supported: false)
        let service = makeService(store: store, attestor: attestor)

        let sawChallenge = OSAllocatedUnfairLock<Bool>(initialState: false)
        AttestStubURLProtocol.handler = { req in
            if req.url?.path == "/api/v1/auth/attest-challenge" {
                sawChallenge.withLock { $0 = true }
            }
            return (.make(status: 200), Data(self.tokenJSON("plain", "anon-plain").utf8))
        }
        defer { AttestStubURLProtocol.handler = nil }

        let token = await service.accessToken()
        #expect(token == "plain")
        #expect(attestor.attestCount == 0)
        #expect(attestor.assertCount == 0)
        #expect(sawChallenge.withLock { $0 } == false)
    }
}
