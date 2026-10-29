//
//  ProfileViewModel.swift
//  Hangs
//
//  #213.4: the Profile tab — who is playing and the stat cards. Owned by
//  AppState like the packs list, so the cards stay on screen while a quiz runs
//  and while they refresh. A failed fetch keeps the last cards; with none, the
//  Profile offers Retry. #213.5: the newest recap sits on top as a banner and
//  plays as a story.
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
    /// Newest first, only kinds this build knows.
    @Published private(set) var recaps: [PlayerRecap] = []
    /// The recap playing as a story.
    @Published var playingRecap: PlayerRecap?

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

    /// The banner on top of the Profile.
    var latestRecap: PlayerRecap? {
        recaps.first
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
            async let freshRecaps = try? service.fetchRecaps()
            do {
                let fresh = try await service.fetchPlayerStats()
                guard !Task.isCancelled else { return }
                stats = fresh
                loadState = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadState = stats == nil ? .failed : .loaded
            }
            // A failed recap fetch keeps the banner the player already saw.
            if let fetched = await freshRecaps, !Task.isCancelled {
                recaps = fetched.filter { $0.kind != nil }
            }
        }
        loadTask = task
        return task
    }

    /// Play the recap; the server and the banner learn it was seen.
    func play(_ recap: PlayerRecap) {
        playingRecap = recap
        guard !recap.seen else { return }
        if let index = recaps.firstIndex(where: { $0.id == recap.id }) {
            recaps[index].seen = true
        }
        let service = service
        Task { try? await service.markRecapSeen(id: recap.id) }
    }

    /// The story closed after `slidesSeen` of `slidesTotal` slides.
    func storyClosed(_ recap: PlayerRecap, slidesSeen: Int, slidesTotal: Int) {
        playingRecap = nil
        analytics.track(.recapViewed(kind: recap.kind?.rawValue ?? "", slidesSeen: slidesSeen, slidesTotal: slidesTotal))
    }

    /// The share sheet opened on the last slide.
    func shareOpened(_ recap: PlayerRecap) {
        analytics.track(.recapShared(kind: recap.kind?.rawValue ?? ""))
    }

    /// The account changed (sign-in, sign-out, deletion): the old cards
    /// belong to someone else.
    func reset() {
        loadTask?.cancel()
        stats = nil
        recaps = []
        playingRecap = nil
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
