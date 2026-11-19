//
//  AppScreen+Family.swift
//  HangsTests
//
//  #236 — Home in the family mode „S deťmi“ (canvas „B · rozpracované“ F2–F4)
//  for each age band, and the age sheet of the first flip (F1). Home with the
//  server switch off is every other Home snapshot, unchanged.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeFamily() async -> AnyView {
        switch self {
        case .homeFamily46: await Self.familyHome(.kids4to6)
        case .homeFamily79: await Self.familyHome(.kids7to9)
        case .homeFamily1012: await Self.familyHome(.kids10to12)
        case .familyBandSheet:
            AnyView(FamilyBandSheet(bands: FamilyBand.allCases, selected: nil, onSelect: { _ in }, onClose: {}))
        default: preconditionFailure("\(self) is not a family mode screen")
        }
    }

    private static func familyHome(_ band: FamilyBand) async -> AnyView {
        let network = MockNetworkService()
        network.stubbedFamilyTopics = FamilyModeFixtures.topics
        let store = MockPersistenceStore()
        store.familySettings = FamilySettings(isOn: true, band: band)
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: store,
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
        vm.settings.language = "sk"
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        let config = AppConfigStore(
            fetch: {
                RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, familyModeEnabled: true)
            },
            sendsTestFlightChannel: true,
            storefront: { nil }
        )
        await config.refresh()
        return AnyView(HomeView(viewModel: vm, appConfig: config))
    }
}
