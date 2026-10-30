//
//  AppScreen+Profile.swift
//  HangsTests
//
//  #213.4 / #216.3: the Profile tab — a signed-in subscriber with the October
//  recap card, a new anonymous player on the way to the first recap; All stats
//  with most cards open and after a failed load; the picture Share sends.
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
        switch self {
        case .allStats, .profileLoadFailed:
            return AnyView(ProfileStatsView(viewModel: model))
        default:
            return AnyView(ProfileView(viewModel: model, isPlus: self == .profile))
        }
    }
}

extension AppScreen {
    /// The October card at story size, as Share sends it.
    func makeRecapShareImage() -> AnyView {
        let recap = PlayerRecap.mockOctober
        let rows = ProfileViewModel(service: MockPlayerStatsService()).highlights(of: recap)
        return AnyView(RecapShareImage(recap: recap, rows: rows, style: Theme.Hangs.Recap.cards[0]))
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
