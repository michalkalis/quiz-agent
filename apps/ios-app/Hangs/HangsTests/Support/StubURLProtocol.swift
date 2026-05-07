//
//  StubURLProtocol.swift
//  HangsTests
//
//  A URLProtocol subclass that intercepts all requests and delegates to a
//  per-test handler closure.  Designed to be injected into a URLSession via
//  URLSessionConfiguration.protocolClasses — never registered globally.
//
//  Thread-safety: the handler is stored inside an OSAllocatedUnfairLock so
//  concurrent accesses from URLSession's internal threads are safe without
//  reaching for nonisolated(unsafe).
//

import Foundation
import os

// MARK: - StubURLProtocol

// URLProtocol is called from URLSession's internal threads, so the class must
// be nonisolated throughout.  Marking it @unchecked Sendable opts it out of
// the default @MainActor isolation inferred by the project's
// -default-isolation=MainActor build flag.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated override init(
        request: URLRequest,
        cachedResponse: CachedURLResponse?,
        client: (any URLProtocolClient)?
    ) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    // OSAllocatedUnfairLock is itself Sendable, so the static property
    // is accessible from any isolation context without nonisolated(unsafe).
    private nonisolated static let handlerLock = OSAllocatedUnfairLock<
        ((@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    )>(initialState: nil)

    /// Set this before creating the `NetworkService` under test, clear it in
    /// a `defer` block after the call completes.
    /// nonisolated so it can be set from test bodies (any isolation) and read
    /// from nonisolated startLoading().
    nonisolated static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { $0 } }
        set { handlerLock.withLock { $0 = newValue } }
    }

    // MARK: URLProtocol overrides
    // `nonisolated` suppresses the "main actor-isolated override" warnings
    // that arise from the project-level -default-isolation=MainActor flag.

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
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
}

// MARK: - StubSession factory

extension StubURLProtocol {
    /// Returns a URLSession that routes all requests through StubURLProtocol.
    /// Use URLSessionConfiguration.ephemeral for a clean state per test.
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - HTTPURLResponse convenience

extension HTTPURLResponse {
    /// Convenience initialiser for stub responses.
    /// nonisolated so it can be called from @Sendable URLProtocol handler closures.
    nonisolated static func make(
        url: URL = URL(string: "http://test.invalid")!,
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
