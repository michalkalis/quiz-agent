//
//  AppScreen+SharedQuiz.swift
//  HangsTests
//
//  #232 share a quiz by link: the comparison (4A) with ✓/✗ per question and
//  the viewer's own row, the first-launch paste row on Home (3) and the
//  host's "What we play" sheet (5A) with a finished and a growing pack. The
//  round end's send card (1A) is `completionShare` in AppScreen+Quiz.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeSharedQuiz() async -> AnyView {
        switch self {
        case .sharedQuizRanking: Self.ranking()
        case .homeSharedPaste: await Self.pasteRow()
        case .roomContentPicker: await Self.contentPicker()
        default: preconditionFailure("\(self) is not a shared quiz screen")
        }
    }

    /// The sender with two friends; one played before marks were kept.
    private static func ranking() -> AnyView {
        let rows = SharedQuizShareModel.rows(from: [
            SharedQuizPlayer(name: "Rýchly gepard", score: 8, total: 10, marks: [true, true, false, true, true, true, nil, true, true, true]),
            SharedQuizPlayer(name: "Michal", score: 7.5, total: 10, isSender: true, isYou: true, marks: [true, false, true, true, false, true, true, true, false, true]),
            SharedQuizPlayer(name: "Zuzka", score: 5, total: 10),
        ])
        return screen(SharedQuizRankingCard(rows: rows))
    }

    private static func pasteRow() async -> AnyView {
        let inbox = SharedQuizInbox(isFirstLaunch: true, analytics: NoopAnalyticsClient(), clipboardProbablyHasURL: { true })
        await inbox.checkClipboard()
        return await screen(HomeSharedQuizPasteRow(inbox: inbox, appConfig: sharedQuizConfig()))
    }

    private static func contentPicker() async -> AnyView {
        let packs = MyPacksViewModel(
            service: MockPackOrderService(listResult: .success([.mockDelivered, .mockGenerating])),
            playedCount: { _ in 0 }
        )
        await packs.refresh()
        let room = RoomViewModel(
            rooms: MockRoomService(),
            network: MockNetworkService(),
            audio: MockAudioService(),
            solo: .default,
            deviceId: "device",
            clock: AnyClock(TestClock()),
            packsEnabled: { true }
        )
        return AnyView(
            RoomContentSheet(viewModel: room, packs: packs)
                .background(Theme.Hangs.Colors.bgSheet)
        )
    }

    private static func sharedQuizConfig() async -> AppConfigStore {
        let config = RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, sharedQuizEnabled: true)
        let store = AppConfigStore(fetch: { config }, defaults: UserDefaults(suiteName: "shared-quiz-snapshot")!)
        await store.refresh()
        return store
    }

    /// The part on its own, top-aligned like it sits on its screen.
    private static func screen(_ content: some View) -> AnyView {
        AnyView(
            VStack {
                content
                Spacer()
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.top, Theme.Hangs.Spacing.xl)
            .background(Theme.Hangs.Colors.bg)
        )
    }
}
