//
//  DailyChallengeViewModel.swift
//  Hangs
//
//  #205 — daily challenge: the state of one day's challenge as the server
//  computes it (played or not, the crowd numbers). The Home card asks for
//  today on every appearance; the daily round end asks for the day it played
//  only while it has nothing to show, so its numbers stay put while open (#240).
//
//  A failed fetch keeps the last state of the same day and language; with
//  none, the card offers the challenge to play (the start then retries).
//
//  #240 (audit finding 17): Home stays on screen while the app sleeps, so the
//  card moves to the new day when iOS reports a day change (midnight, a time
//  zone change; queued while suspended, delivered on return). Otherwise the
//  morning card shows yesterday and "Play today" starts yesterday's set.
//

import Combine
import Foundation
import UIKit

@MainActor
final class DailyChallengeViewModel: ObservableObject {
    /// What the Home card shows.
    enum Card: Equatable {
        case notPlayed
        case played(DailySummary)
    }

    @Published private(set) var state: DailyChallengeState?
    @Published private(set) var day: DailyChallengeDay
    @Published private(set) var loadFailed = false

    private let network: NetworkServiceProtocol
    /// Today's local date comes from here (a test pins it).
    private let now: () -> Date
    private let calendar: Calendar
    private var language: String?
    /// Set by `refreshToday`: this model follows today (Home), not a fixed day.
    private var followsToday = false
    private var dayChange: AnyCancellable?

    init(
        network: NetworkServiceProtocol,
        now: @escaping () -> Date = { .now },
        calendar: Calendar = .current,
        day: DailyChallengeDay? = nil,
        state: DailyChallengeState? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.network = network
        self.now = now
        self.calendar = calendar
        self.day = day ?? state.flatMap { DailyChallengeDay(isoDate: $0.date) } ?? DailyChallengeDay(now(), calendar: calendar)
        self.state = state
        language = state?.language
        dayChange = notificationCenter.publisher(for: UIApplication.significantTimeChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.dayMayHaveChanged() }
            }
    }

    /// Questions in the challenge; before the first answer, the server's set size.
    var questionCount: Int {
        state?.total ?? Self.setSize
    }

    /// `SET_SIZE` in `apps/quiz-agent/app/daily_challenge/service.py`.
    static let setSize = 5

    var card: Card {
        if let summary = state?.summary, state?.status == .played { return .played(summary) }
        return .notPlayed
    }

    /// #205.8: extra questions promised before playing; nil = say nothing
    /// (played already, a subscriber, reward off or an older server).
    var bonusPromise: Int? {
        guard case .notPlayed = card, let offer = state?.bonusOffer, offer > 0 else { return nil }
        return offer
    }

    /// Extra questions still left after finishing; nil when none (0 = used up).
    var bonusLeft: Int? {
        state?.earnedBonusLeft
    }

    /// Finished challenges, shown quietly once there is one.
    var daysPlayed: Int? {
        guard case .played = card, let days = state?.daysPlayed, days >= 1 else { return nil }
        return days
    }

    /// Home: today's challenge in the quiz language.
    func refreshToday(language: String) async {
        followsToday = true
        await refresh(day: DailyChallengeDay(now(), calendar: calendar), language: language)
    }

    /// iOS reported a significant time change: a new day gets its own card.
    private func dayMayHaveChanged() async {
        guard followsToday, let language, DailyChallengeDay(now(), calendar: calendar) != day else { return }
        await refreshToday(language: language)
    }

    /// The daily round end: the challenge of `day` once, unless it already
    /// shows one (the start brought it, or an earlier fetch).
    func loadIfMissing(day: DailyChallengeDay, language: String) async {
        // The start's state is still "in progress" (no summary, no extra
        // questions left): until the finished state is here, fetch it.
        guard state?.status != .played || day != self.day || language != self.language else { return }
        await refresh(day: day, language: language)
    }

    /// The challenge of `day` in `language`. A different day or language
    /// drops the old state first: it described another challenge.
    func refresh(day: DailyChallengeDay, language: String) async {
        if day != self.day || language != self.language {
            state = nil
            loadFailed = false
        }
        self.day = day
        self.language = language
        do {
            let fresh = try await network.fetchDailyChallenge(date: day.isoDate, language: language)
            // A newer request for another day or language owns the state now.
            guard day == self.day, language == self.language else { return }
            state = fresh
            loadFailed = false
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return }
            loadFailed = true
        }
    }
}
