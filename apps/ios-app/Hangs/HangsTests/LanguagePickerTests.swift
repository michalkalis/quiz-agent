//
//  LanguagePickerTests.swift
//  HangsTests
//
//  #168 — batch translation pipeline SK/CS (DD14/DD15): the quiz-language
//  picker must offer only languages the backend can actually serve. Until an
//  approved translated corpus exists, de/fr/es/it/pl/hu/ro are hidden, and the
//  backend validators harden to 422 on them (T26) once this build is on the
//  device. So what matters here is not "the list is filtered" but the two ways
//  a user could still end up sending a hidden code:
//
//  1. a preference stored *before* the language was hidden, and
//  2. a pack order inheriting a quiz language packs cannot be generated in.
//
//  Both must degrade to `Language.default` — a 422 mid-session is a dead quiz.
//

import Foundation
@testable import Hangs
import os
import Testing

@Suite("Language picker gating (#168 DD14/DD15)", .serialized)
struct LanguagePickerTests {

    // MARK: - Filtering

    @Test("The display catalogue keeps all ten codes — only the offer list narrows")
    func testDisplayCatalogueIsUnfiltered() {
        // Hiding a language must not lose its name: a stored 'de' still has to
        // render somewhere, and re-enabling it is an env flip, not a build.
        #expect(Language.supportedLanguages.count == 10)
        #expect(Language.forCode("de")?.nativeName == "Deutsch")
    }

    @Test("Only the servable codes are offered, in catalogue order")
    func testSelectableListFiltersToServableCodes() {
        // Server order deliberately scrambled: the menu order is ours.
        let offered = Language.selectableLanguages(in: ["cs", "en", "sk"])
        #expect(offered.map(\.id) == ["en", "sk", "cs"])
    }

    @Test("An unusable server list falls back to the default rather than emptying the menu")
    func testUnknownCodesLeaveAUsablePicker() {
        #expect(Language.selectableLanguages(in: ["zz"]).map(\.id) == [Language.default.id])
    }

    // MARK: - Degradation

    @Test("A stored language that is no longer offered degrades to the default")
    func testHiddenStoredLanguageDegradesToDefault() {
        let servable = Language.selectableLanguages(in: ["en", "sk", "cs"])

        // 'de' was pickable in an older build and may sit in persisted settings.
        // Sending it would 422 once the validators harden (T26).
        #expect(Language.selectable("de", in: servable).id == Language.default.id)
        // A still-servable stored choice is preserved — degradation must not
        // reset everyone to English.
        #expect(Language.selectable("sk", in: servable).id == "sk")
    }

    @Test("Decoding settings persisted with a hidden language degrades that language")
    func testPersistedSettingsWithHiddenLanguageDecodeToDefault() throws {
        var stored = QuizSettings.default
        stored.language = "de"
        let blob = try JSONEncoder().encode(stored)

        let restored = try JSONDecoder().decode(QuizSettings.self, from: blob)

        // The rest of the blob must survive — this is a targeted degradation,
        // not a settings reset.
        #expect(restored.language == Language.default.id)
        #expect(restored.numberOfQuestions == stored.numberOfQuestions)
    }

    @Test("A quiz language packs cannot be generated in degrades on the order form")
    func testPackOrderLanguageNarrowerThanQuiz() {
        // DD15: packs are generated in English and only stamped with the code,
        // so a Slovak quiz language must not become a Slovak pack order.
        let packOrder = Language.selectableLanguages(in: LanguageAvailability.fallbackPackOrderCodes)
        #expect(packOrder.map(\.id) == ["en"])
        #expect(Language.selectable("sk", in: packOrder).id == "en")
    }

    // MARK: - Availability store

    @Test("Compiled fallback stands in until a fetch lands")
    func testFallbackWhenNothingCached() throws {
        let store = try makeIsolatedStore()
        #expect(store.quizCodes == ["en", "sk", "cs"])
        #expect(store.packOrderCodes == ["en"])
    }

    @Test("A fetched list is cached, so an offline launch keeps the server's menu")
    func testFetchedListIsCachedAndRead() throws {
        let defaults = try makeIsolatedDefaults()
        LanguageAvailability(defaults: defaults)
            .store(ServableLanguages(quiz: ["en", "sk", "cs", "pl"], packOrder: ["en"]))

        // A fresh handle on the same defaults reads the cache — the offline path.
        #expect(LanguageAvailability(defaults: defaults).quizCodes == ["en", "sk", "cs", "pl"])
    }

    @Test("An empty server list is ignored — a picker with no options is worse than a stale one")
    func testEmptyListDoesNotWipeTheCache() throws {
        let store = try makeIsolatedStore()
        store.store(ServableLanguages(quiz: ["en", "sk"], packOrder: ["en"]))
        store.store(ServableLanguages(quiz: [], packOrder: []))

        #expect(store.quizCodes == ["en", "sk"])
    }

    @Test("GET /api/v1/languages decodes the backend's snake_case response")
    func testRefreshDecodesBackendResponse() async throws {
        let store = try makeIsolatedStore()
        // OSAllocatedUnfairLock (never `nonisolated(unsafe)`) so the handler,
        // called on URLSession's own thread, can hand the path back.
        let capturedPath = OSAllocatedUnfairLock<String?>(initialState: nil)
        LanguagesStubProtocol.handler = { request in
            capturedPath.withLock { $0 = request.url?.path }
            let json = #"{"quiz":["en","sk","cs"],"pack_order":["en"]}"#
            return (HTTPURLResponse.make(status: 200), Data(json.utf8))
        }
        defer { LanguagesStubProtocol.handler = nil }

        await store.refresh(session: LanguagesStubProtocol.makeSession(), baseURL: "http://test.invalid")

        // The languages router is mounted ONLY under /api (main.py:137), unlike
        // /v1/orders which also has a bare mount — a wrong path 404s silently.
        #expect(capturedPath.withLock { $0 } == "/api/v1/languages")
        #expect(store.quizCodes == ["en", "sk", "cs"])
    }

    @Test("A failed fetch leaves the previous list intact")
    func testFailedRefreshKeepsCachedList() async throws {
        let store = try makeIsolatedStore()
        store.store(ServableLanguages(quiz: ["en", "sk"], packOrder: ["en"]))
        LanguagesStubProtocol.handler = { _ in (HTTPURLResponse.make(status: 503), Data()) }
        defer { LanguagesStubProtocol.handler = nil }

        await store.refresh(session: LanguagesStubProtocol.makeSession(), baseURL: "http://test.invalid")

        #expect(store.quizCodes == ["en", "sk"])
    }

    /// A store on its own UserDefaults suite so these tests never race the
    /// simulator's shared `.standard` defaults with the rest of the suite.
    private func makeIsolatedStore() throws -> LanguageAvailability {
        LanguageAvailability(defaults: try makeIsolatedDefaults())
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "LanguagePickerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

// MARK: - Stub

/// A private twin of `StubURLProtocol` for this suite alone. The shared one
/// keeps its handler in a process-wide static, and Swift Testing runs suites in
/// parallel — a neighbouring suite clearing that handler mid-test made this
/// suite fail with an unexercised stub. Own handler, own race-free suite.
private final class LanguagesStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated override init(
        request: URLRequest,
        cachedResponse: CachedURLResponse?,
        client: (any URLProtocolClient)?
    ) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    private nonisolated static let handlerLock = OSAllocatedUnfairLock<
        ((@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?)
    >(initialState: nil)

    nonisolated static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerLock.withLock { $0 } }
        set { handlerLock.withLock { $0 = newValue } }
    }

    nonisolated override class func canInit(with _: URLRequest) -> Bool { true }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        guard let handler = LanguagesStubProtocol.handler else {
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
        cfg.protocolClasses = [LanguagesStubProtocol.self]
        return URLSession(configuration: cfg)
    }
}
