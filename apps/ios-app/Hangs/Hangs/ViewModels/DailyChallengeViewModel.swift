//
//  DailyChallengeViewModel.swift
//  Hangs
//
//  #205 — daily challenge: the state of one day's challenge as the server
//  computes it (played or not, the crowd numbers). The Home card asks for
//  today on every appearance; the daily round end asks for the day it played
//  whenever it is on screen, so the numbers fill in as others play.
//
//  A failed fetch keeps the last state of the same day and language; with
//  none, the card offers the challenge to play (the start then retries).
//

import Combine
import Foundation

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

    init(
        network: NetworkServiceProtocol,
        now: @escaping () -> Date = { .now },
        calendar: Calendar = .current,
        day: DailyChallengeDay? = nil,
        state: DailyChallengeState? = nil
    ) {
        self.network = network
        self.now = now
        self.calendar = calendar
        self.day = day ?? state.flatMap { DailyChallengeDay(isoDate: $0.date) } ?? DailyChallengeDay(now(), calendar: calendar)
        self.state = state
        language = state?.language
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

    /// Home: today's challenge in the quiz language.
    func refreshToday(language: String) async {
        await refresh(day: DailyChallengeDay(now(), calendar: calendar), language: language)
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
