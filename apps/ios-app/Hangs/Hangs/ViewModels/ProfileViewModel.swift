//
//  ProfileViewModel.swift
//  Hangs
//
//  #213.4: the Profile tab — who is playing and the stat cards. Owned by
//  AppState like the packs list, so the cards stay on screen while a quiz runs
//  and while they refresh. A failed fetch keeps the last cards; with none, the
//  Profile offers Retry. #216.3 (founder 2026-10-30, S1): the newest recap is
//  one card with three numbers and Share; every other card waits behind
//  "All stats". The story and the player type are gone.
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
    /// #232 (founder 2026-11-14): the name friends see in a game together and
    /// in a shared quiz, changed in the "Your name" row.
    @Published private(set) var playerName = ""
    /// Newest first, only kinds this build knows.
    @Published private(set) var recaps: [PlayerRecap] = []
    /// The recap the card shows, picked when the recaps arrive (#240): the
    /// oldest one not seen yet, else the newest. Kept until the next fetch,
    /// so marking it seen does not swap the card under the player's eyes.
    private var shownRecapID: String?

    private let service: PlayerStatsServiceProtocol
    private let tokenStore: any TokenStore
    private let nameStore: PlayerNameStore
    private let analytics: AnalyticsClient
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?

    /// #235 F4: recaps seen here whose "seen" the server has not taken yet.
    static let unsentSeenKey = "profile.unsentRecapSeen"

    init(
        service: PlayerStatsServiceProtocol,
        tokenStore: any TokenStore = KeychainTokenStore(),
        nameStore: PlayerNameStore = PlayerNameStore(),
        analytics: AnalyticsClient = NoopAnalyticsClient(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.tokenStore = tokenStore
        self.nameStore = nameStore
        self.analytics = analytics
        self.defaults = defaults
    }

    /// The three numbers the founder finds worth a look (2026-10-30), in the
    /// order the recap card shows them.
    static let highlightKinds = ["totals", "best_category", "when"]
    /// What "All stats" lists: the highlights and the cards still worth
    /// reading. Hard questions, options vs own words and the fastest category
    /// are no longer shown (the server still sends them for older builds).
    static let shownKinds: Set<String> = [
        "totals", "best_category", "when", "where", "typical_game", "improvement", "best_streak", "weakest_category",
    ]

    /// "All stats": unlocked cards first, then the locked ones, each in the
    /// server's order.
    var cards: [StatCard] {
        let shown = (stats?.cards ?? []).filter { Self.shownKinds.contains($0.kind) && Self.isReadable($0) }
        return shown.filter { !$0.isLocked } + shown.filter(\.isLocked)
    }

    /// The recap card's rows; a kind the recap lacks is left out.
    func highlights(of recap: PlayerRecap) -> [StatCard] {
        Self.highlightKinds.compactMap { kind in
            recap.cards.first { $0.kind == kind && $0.content != nil && Self.isReadable($0) }
        }
    }

    /// Kinds this build does not know and categories outside the taxonomy are
    /// left out: the Profile never shows a raw id.
    private static func isReadable(_ card: StatCard) -> Bool {
        guard let content = card.content else { return true }
        if content == .unknown { return false }
        return content.category.map { Config.categoryDisplayName(for: $0) != nil } ?? true
    }

    /// The first-recap card shows until the server says it is reached.
    var firstRecapProgress: FirstRecapProgress? {
        guard let progress = stats?.firstRecapProgress, !progress.isReached else { return nil }
        return progress
    }

    /// The recap card on the Profile. An older recap the player has not
    /// seen comes first, so a newer one never hides it for good (#240).
    var latestRecap: PlayerRecap? {
        recaps.first { $0.id == shownRecapID } ?? recaps.first
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
        resendUnsentSeen()
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
                // A "seen" still on its way: the server's copy is older than this phone's.
                let unsent = unsentSeenIDs
                recaps = fetched.filter { $0.kind != nil }.map { recap in
                    var recap = recap
                    if unsent.contains(recap.id) { recap.seen = true }
                    return recap
                }
                shownRecapID = (recaps.last { !$0.seen } ?? recaps.first)?.id
            }
        }
        loadTask = task
        return task
    }

    /// The recap card came on screen: the server learns it was seen, once.
    func recapShown(_ recap: PlayerRecap) {
        guard !recap.seen, let index = recaps.firstIndex(where: { $0.id == recap.id }) else { return }
        recaps[index].seen = true
        unsentSeenIDs.insert(recap.id)
        sendSeen(recap.id)
    }

    /// #235 F4: the next Profile visit sends again what failed, so the recap
    /// does not come back as new. Nothing is shown to the player.
    @discardableResult
    func resendUnsentSeen() -> Task<Void, Never>? {
        let ids = unsentSeenIDs
        guard !ids.isEmpty else { return nil }
        let sends = ids.sorted().map { sendSeen($0) }
        return Task { for send in sends {
            await send.value
        } }
    }

    /// Forgotten once the server took it or no longer knows the recap (404,
    /// e.g. another account), so it is never sent forever.
    @discardableResult
    private func sendSeen(_ id: String) -> Task<Void, Never> {
        let service = service
        return Task {
            do {
                try await service.markRecapSeen(id: id)
            } catch NetworkError.serverError(statusCode: 404, _) {
                // Gone for good: sending it again cannot help.
            } catch {
                return
            }
            unsentSeenIDs.remove(id)
        }
    }

    private var unsentSeenIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.unsentSeenKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.unsentSeenKey) }
    }

    /// The share sheet opened on the recap card.
    func shareOpened(_ recap: PlayerRecap) {
        analytics.track(.recapShared(kind: recap.kind?.rawValue ?? ""))
    }

    /// A name typed in the "Your name" row; it wins over the account's first name.
    func rename(to name: String) {
        guard let clean = PlayerNameStore.cleaned(name), clean != playerName else { return }
        nameStore.save(clean)
        reloadAccount()
        analytics.track(.playerNameChanged)
    }

    /// The account changed (sign-in, sign-out, deletion): the old cards
    /// belong to someone else.
    func reset() {
        loadTask?.cancel()
        stats = nil
        recaps = []
        shownRecapID = nil
        loadState = .loading
        reloadAccount()
    }

    private func reloadAccount() {
        let tokens = tokenStore.load()
        let isSignedIn = tokens?.isSignedIn == true
        let name = tokens?.accountName.flatMap(PlayerNameStore.cleaned) ?? nameStore.chosenName
        account = Account(name: name, isSignedIn: isSignedIn)
        playerName = nameStore.playerName(accountName: tokens?.accountName)
    }
}
