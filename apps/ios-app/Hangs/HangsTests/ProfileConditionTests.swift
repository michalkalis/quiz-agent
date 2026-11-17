//
//  ProfileConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, Profile row). The Profile's cards come from the
//  server: while they load the tab says so, and cards that arrive after the
//  account changed (sign-out, deletion) belong to someone else and must never
//  appear. Failed loads and the My packs list already have tests
//  (ProfileViewModelTests, RecapStoryTests, MyPacksViewModelTests).
//

import Foundation
@testable import Hangs
import Testing

/// Stats that wait for the test's `open()` and then answer even if the
/// caller was cancelled meanwhile: a reply already on its way still lands.
private final class LateStatsService: PlayerStatsServiceProtocol, @unchecked Sendable {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    @MainActor
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    @MainActor
    private func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fetchPlayerStats() async throws -> PlayerStats {
        await wait()
        return .mockSeasoned
    }

    func fetchRecaps() async throws -> [PlayerRecap] {
        await wait()
        return [.mockOctober]
    }

    func markRecapSeen(id _: String) async throws {}
}

private final nonisolated class StubTokenStore: TokenStore, @unchecked Sendable {
    func load() -> AuthTokens? { nil }
    func save(_: AuthTokens) {}
    func clear() {}
}

@Suite("Profile on a bad network (#235.2)")
@MainActor
struct ProfileConditionTests {
    // WHY: on a slow network the first visit to Profile must say it is
    // loading (not an empty tab that looks broken), then show the cards.
    @Test("a slow first load shows loading, then the cards")
    func slowFirstLoadShowsLoading() async {
        let service = LateStatsService()
        let model = ProfileViewModel(service: service, tokenStore: StubTokenStore())
        let load = model.refresh()
        await pumpUntil { service.arrivals == 2 }

        #expect(model.loadState == .loading)
        #expect(model.cards.isEmpty)

        service.open()
        await load.value
        #expect(model.loadState == .loaded)
        #expect(!model.cards.isEmpty)
        #expect(model.latestRecap != nil)
    }

    // WHY: the player signed out while the cards were loading. The previous
    // account's stats and recap must not appear on the signed-out Profile.
    @Test("cards that arrive after the account changed are never shown")
    func lateCardsAfterAccountChangeAreDropped() async {
        let service = LateStatsService()
        let model = ProfileViewModel(service: service, tokenStore: StubTokenStore())
        let load = model.refresh()
        await pumpUntil { service.arrivals == 2 }

        model.reset()
        service.open()
        await load.value

        #expect(model.stats == nil, "the previous account's cards came back")
        #expect(model.recaps.isEmpty)
        #expect(model.loadState == .loading)
    }
}
