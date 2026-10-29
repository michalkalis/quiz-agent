//
//  ProfileViewModel.swift
//  Hangs
//
//  #213.4: the Profile tab — who is playing and the stat cards. Owned by
//  AppState like the packs list, so the cards stay on screen while a quiz runs
//  and while they refresh. A failed fetch keeps the last cards; with none, the
//  Profile offers Retry.
//

import Combine
import Foundation

@MainActor
final class ProfileViewModel: ObservableObject {
    enum LoadState: Equatable {
        case loading, loaded, failed
    }

    /// What the account row shows.
    struct Account: Equatable {
        /// Apple account name, else the name chosen for a game together.
        let name: String?
        let isSignedIn: Bool
    }

    @Published private(set) var stats: PlayerStats?
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var account = Account(name: nil, isSignedIn: false)

    private let service: PlayerStatsServiceProtocol
    private let tokenStore: any TokenStore
    private let nameStore: PlayerNameStore
    private let analytics: AnalyticsClient
    private var loadTask: Task<Void, Never>?

    init(
        service: PlayerStatsServiceProtocol,
        tokenStore: any TokenStore = KeychainTokenStore(),
        nameStore: PlayerNameStore = PlayerNameStore(),
        analytics: AnalyticsClient = NoopAnalyticsClient()
    ) {
        self.service = service
        self.tokenStore = tokenStore
        self.nameStore = nameStore
        self.analytics = analytics
    }

    /// Unlocked cards first, then the locked ones, each in the server's order.
    /// Kinds this build does not know and categories outside the taxonomy are
    /// left out: the Profile never shows a raw id.
    var cards: [StatCard] {
        let shown = (stats?.cards ?? []).filter { card in
            guard let content = card.content else { return true }
            if content == .unknown { return false }
            return content.category.map { Config.categoryDisplayName(for: $0) != nil } ?? true
        }
        return shown.filter { !$0.isLocked } + shown.filter(\.isLocked)
    }

    /// The first-recap card shows until the server says it is reached.
    var firstRecapProgress: FirstRecapProgress? {
        guard let progress = stats?.firstRecapProgress, !progress.isReached else { return nil }
        return progress
    }

    /// The player switched to the Profile tab.
    func tabOpened() {
        reloadAccount()
        analytics.track(.profileOpened(hasAccount: account.isSignedIn))
    }

    /// The Profile is on screen: the tab was opened or a pushed screen closed.
    func appeared() {
        reloadAccount()
        refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        loadTask?.cancel()
        if stats == nil { loadState = .loading }
        let task = Task {
            do {
                let fresh = try await service.fetchPlayerStats()
                guard !Task.isCancelled else { return }
                stats = fresh
                loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadState = stats == nil ? .failed : .loaded
            }
        }
        loadTask = task
        return task
    }

    /// The account changed (sign-in, sign-out, deletion): the old cards
    /// belong to someone else.
    func reset() {
        loadTask?.cancel()
        stats = nil
        loadState = .loading
        reloadAccount()
    }

    private func reloadAccount() {
        let tokens = tokenStore.load()
        let isSignedIn = tokens?.isSignedIn == true
        let name = tokens?.accountName.flatMap(PlayerNameStore.cleaned) ?? nameStore.chosenName
        account = Account(name: name, isSignedIn: isSignedIn)
    }
}
