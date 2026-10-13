//
//  AppScreen+Packs.swift
//  HangsTests
//
//  #194 C8: the My packs list — delivered, generating, pending and failed
//  orders in one screen. #200: a signed-in user whose list failed to load
//  sees Retry, not the sign-in prompt.
//

import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makePacks() async -> AnyView {
        let orders: [OrderSnapshot] = [.mockDelivered, .mockGenerating, .mockPending, .mockFailed]
        // #200: the pack is part played, so its rows show "4 / 30".
        let vm = MyPacksViewModel(
            service: MockPackOrderService(listResult: .success(orders)),
            playedCount: { _ in 4 }
        )
        await vm.refresh()
        // No NavigationStack: its bar height differs per device and would tie
        // the baseline to the simulator model.
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let createPack = MyPacksCreatePack(
            orderViewModel: appState.orderPackViewModel,
            appConfig: appState.appConfig,
            defaultLanguage: "en"
        )
        return AnyView(MyPacksView(viewModel: vm, onPlayPack: { _ in }, createPack: createPack))
    }

    func makePacksLoadFailed() async -> AnyView {
        let vm = MyPacksViewModel(service: MockPackOrderService(listResults: [.failure(.init("offline"))]))
        await vm.retryLoad()
        return AnyView(MyPacksView(viewModel: vm, onPlayPack: { _ in }))
    }
}
