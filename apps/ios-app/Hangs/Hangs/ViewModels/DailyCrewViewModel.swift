//
//  DailyCrewViewModel.swift
//  Hangs
//
//  #239 — the daily crew table on the daily round end: everyone the player
//  swapped a daily link with, by rarity points this week. Fetched once per
//  opening of the round end, like the crowd numbers: the table stays put
//  while the screen is open and shows the new points next time (#240).
//
//  The table is extra to the result above it: a failed or slow fetch keeps
//  the last table (or none) and never blocks the screen. A failed removal
//  puts the person back and says so.
//

import Combine
import Foundation

@MainActor
final class DailyCrewViewModel: ObservableObject {
    /// nil = not loaded (yet); empty members = no crew yet.
    @Published private(set) var crew: DailyCrew?
    /// The last removal did not reach the server; the person is back.
    @Published private(set) var removeFailed = false

    private let network: NetworkServiceProtocol
    private var request: (day: DailyChallengeDay, language: String)?

    init(network: NetworkServiceProtocol, crew: DailyCrew? = nil) {
        self.network = network
        self.crew = crew
    }

    /// The round end: the table once, unless it already shows one.
    func loadIfMissing(day: DailyChallengeDay, language: String) async {
        guard crew == nil else { return }
        await refresh(day: day, language: language)
    }

    func refresh(day: DailyChallengeDay, language: String) async {
        request = (day, language)
        do {
            let fresh = try await network.fetchDailyCrew(date: day.isoDate, language: language)
            guard request?.day == day, request?.language == language else { return }
            crew = fresh
        } catch {
            // Silent on purpose: the table is extra to the result the player
            // came for; the last one stays and the next appearance retries.
        }
    }

    /// Takes the person out at once; the server's answer decides.
    func remove(_ member: DailyCrewMember) async {
        guard let memberId = member.memberId, let before = crew else { return }
        removeFailed = false
        let left = before.members.filter { $0.id != member.id }
        crew = DailyCrew(weekStart: before.weekStart, members: left.count > 1 ? left : [])
        do {
            try await network.removeDailyCrewMember(memberId: memberId)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            crew = before
            removeFailed = true
            return
        }
        if let request { await refresh(day: request.day, language: request.language) }
    }
}
