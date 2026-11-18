//
//  DailyCrewTests.swift
//  HangsTests
//
//  #239 — the daily crew table on the daily round end. Why: the table is
//  extra to the result the player came for, so a slow or failed server must
//  never block or blank the round end; a removal must take the person out at
//  once and put them back (with a line saying so) when the server refuses,
//  or the player would think someone is gone who still sees them; with no
//  crew yet the screen explains how one forms only when Share sends a link.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
enum CrewFixtures {
    static let day = DailyChallengeDay(year: 2026, month: 11, day: 18)

    static func member(_ id: String?, _ name: String?, points: Int, place: Int, you: Bool = false) -> DailyCrewMember {
        DailyCrewMember(memberId: id, name: name, points: points, today: 0, days: 1, place: place, isYou: you)
    }

    static let crew = DailyCrew(weekStart: "2026-11-16", members: [
        member("m-ben", "Ben", points: 120, place: 1),
        member(nil, nil, points: 65, place: 2, you: true),
        member("m-cid", "Cid", points: 10, place: 3),
    ])
}

@Suite("Daily crew model (#239)")
@MainActor
struct DailyCrewModelTests {
    // WHY: the wire shape is the server's (snake_case); a renamed key would
    // silently hide the whole table.
    @Test("decodes the server's crew table")
    func decodesServerShape() throws {
        let json = """
        {"week_start": "2026-11-16", "members": [
          {"member_id": "abc", "name": "Ben", "points": 120, "today": 55, "days": 2, "place": 1, "is_you": false},
          {"member_id": null, "name": null, "points": 65, "today": 65, "days": 1, "place": 2, "is_you": true}
        ]}
        """
        let crew = try JSONDecoder().decode(DailyCrew.self, from: Data(json.utf8))
        #expect(crew.weekStart == "2026-11-16")
        #expect(crew.members.map(\.name) == ["Ben", nil])
        #expect(crew.members[1].isYou && crew.members[1].id == "you")
        #expect(crew.members[0].today == 55)
    }

    @Test("a fetch shows the week's table")
    func fetchShowsTable() async {
        let network = MockNetworkService()
        network.stubbedDailyCrew = CrewFixtures.crew
        let model = DailyCrewViewModel(network: network)
        await model.refresh(day: CrewFixtures.day, language: "sk")
        #expect(model.crew == CrewFixtures.crew)
    }

    // WHY: a slow server must not hold the round end: until the table
    // arrives there is simply no table (the result above is complete).
    @Test("while the table is on its way nothing waits for it")
    func slowFetchShowsNothingYet() async {
        let network = MockNetworkService()
        network.stubbedDailyCrew = CrewFixtures.crew
        let hold = network.hold(.fetchDailyCrew)
        let model = DailyCrewViewModel(network: network)
        let refresh = Task { await model.refresh(day: CrewFixtures.day, language: "sk") }
        await pumpUntil { hold.heldCount == 1 }
        #expect(model.crew == nil)
        hold.release()
        await refresh.value
        #expect(model.crew == CrewFixtures.crew)
    }

    // WHY: a failed refresh (offline on the next appearance) keeps the table
    // the player already saw instead of making the crew vanish.
    @Test("a failed fetch keeps the last table", arguments: [
        NetworkCondition.offline, .serverError(statusCode: 500), .malformed,
    ])
    func failedFetchKeepsLastTable(condition: NetworkCondition) async {
        let network = MockNetworkService()
        let model = DailyCrewViewModel(network: network, crew: CrewFixtures.crew)
        network.networkConditions[.fetchDailyCrew] = condition
        await model.refresh(day: CrewFixtures.day, language: "sk")
        #expect(model.crew == CrewFixtures.crew)
    }

    @Test("removing takes the person out and asks the server")
    func removeTakesPersonOut() async {
        let network = MockNetworkService()
        network.stubbedDailyCrew = CrewFixtures.crew
        let model = DailyCrewViewModel(network: network)
        await model.refresh(day: CrewFixtures.day, language: "sk")
        await model.remove(CrewFixtures.crew.members[0])
        #expect(network.removedDailyCrewMemberIds == ["m-ben"])
        #expect(model.crew?.members.map(\.name) == [nil, "Cid"])
        #expect(!model.removeFailed)
    }

    // WHY: with the last friend gone the player is alone; a table of one is
    // noise, so it becomes "no crew yet" (the invite line).
    @Test("removing the last friend leaves no crew")
    func removingLastFriendLeavesNoCrew() async {
        let network = MockNetworkService()
        let alone = DailyCrew(weekStart: "2026-11-16", members: [
            CrewFixtures.member("m-ben", "Ben", points: 10, place: 1),
            CrewFixtures.member(nil, nil, points: 0, place: 2, you: true),
        ])
        network.stubbedDailyCrew = alone
        let model = DailyCrewViewModel(network: network)
        await model.refresh(day: CrewFixtures.day, language: "sk")
        await model.remove(alone.members[0])
        #expect(model.crew?.members == [])
    }

    // WHY: the person still sees the player when the server refused; showing
    // them gone would be a lie about privacy.
    @Test("a failed removal puts the person back and says so", arguments: [
        NetworkCondition.offline, .serverError(statusCode: 500), .dropped(after: .zero),
    ])
    func failedRemovalRestores(condition: NetworkCondition) async {
        let network = MockNetworkService()
        network.stubbedDailyCrew = CrewFixtures.crew
        let model = DailyCrewViewModel(network: network)
        await model.refresh(day: CrewFixtures.day, language: "sk")
        network.networkConditions[.removeDailyCrewMember] = condition
        await model.remove(CrewFixtures.crew.members[0])
        #expect(model.crew == CrewFixtures.crew)
        #expect(model.removeFailed)
    }
}

@Suite("Daily crew card (#239)")
@MainActor
struct DailyCrewCardInspectorTests {
    private func card(_ crew: DailyCrew?, canInvite: Bool = true) -> DailyCrewCard {
        DailyCrewCard(
            model: DailyCrewViewModel(network: MockNetworkService(), crew: crew),
            playerName: "Jana",
            canInvite: canInvite
        )
    }

    @Test("the table lists the crew best first, the player marked")
    func tableListsCrew() async throws {
        let view = card(CrewFixtures.crew)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.crew") }
            let members = tree.findAll { (try? $0.accessibilityIdentifier()) == "daily.crew.member" }
            #expect(members.count == 2)
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.crew.you") }
            #expect(throws: Never.self) { try tree.find(text: "Ben") }
            #expect(throws: Never.self) { try tree.find(text: "120") }
        }
    }

    // WHY: variant B has no setup step, so the empty state is the only place
    // the player learns how a crew forms; without a link to send it would be
    // an instruction they cannot follow.
    @Test("no crew yet: the invite line, only when Share sends a link")
    func emptyCrewInvite() async throws {
        let empty = DailyCrew(weekStart: "2026-11-16", members: [])
        let withLink = card(empty)
        try await ViewHosting.host(withLink) {
            #expect(throws: Never.self) { try withLink.inspect().find(viewWithAccessibilityIdentifier: "daily.crew.invite") }
        }
        let withoutLink = card(empty, canInvite: false)
        try await ViewHosting.host(withoutLink) {
            #expect(throws: (any Error).self) { try withoutLink.inspect().find(viewWithAccessibilityIdentifier: "daily.crew.invite") }
            #expect(throws: (any Error).self) { try withoutLink.inspect().find(viewWithAccessibilityIdentifier: "daily.crew") }
        }
    }

    @Test("not loaded: no card at all")
    func notLoadedShowsNothing() async throws {
        let view = card(nil)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.crew") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.crew.invite") }
        }
    }
}
