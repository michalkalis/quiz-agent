//
//  AppScreen+Profile.swift
//  HangsTests
//
//  #213.4: the Profile tab — a signed-in subscriber with most cards open, a
//  new anonymous player on the way to the first recap, and a failed load.
//  #213.5: the subscriber has a new October recap; its story slides.
//

import Foundation
@testable import Hangs
import os
import SwiftUI

extension AppScreen {
    func makeProfile() async -> AnyView {
        let results: [Result<PlayerStats, NetworkError>] = switch self {
        case .profileNewPlayer: [.success(.mockNewPlayer)]
        case .profileLoadFailed: [.failure(.invalidResponse)]
        default: [.success(.mockSeasoned)]
        }
        let tokens: AuthTokens = self == .profile
            ? AuthTokens(accessToken: "a", refreshToken: "r", anonId: "user", accountName: "Michal", accountEmail: nil, appleUserId: "apple")
            : AuthTokens(accessToken: "a", refreshToken: "r", anonId: "anon")
        let names = UserDefaults(suiteName: "AppScreen.profile") ?? .standard
        names.removePersistentDomain(forName: "AppScreen.profile")
        let model = ProfileViewModel(
            service: MockPlayerStatsService(results: results, recaps: [.success(self == .profile ? [.mockOctober] : [])]),
            tokenStore: SnapshotTokenStore(tokens),
            nameStore: PlayerNameStore(defaults: names)
        )
        model.appeared()
        await model.refresh().value
        // No NavigationStack: its bar height differs per device and would tie
        // the baseline to the simulator model.
        return AnyView(ProfileView(viewModel: model, isPlus: self == .profile))
    }
}

extension AppScreen {
    /// The first slide, a card slide (cobalt) and the last one with Share.
    func makeRecapStory() -> AnyView {
        let last = RecapSlide.story(for: .mockOctober).count - 1
        let start = switch self {
        case .recapCard: 1
        case .recapPlayerType: last
        default: 0
        }
        return AnyView(RecapStoryView(recap: .mockOctober, startAt: start) { _, _ in })
    }
}

private final nonisolated class SnapshotTokenStore: TokenStore, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<AuthTokens?>

    init(_ seed: AuthTokens?) {
        lock = OSAllocatedUnfairLock(initialState: seed)
    }

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}
