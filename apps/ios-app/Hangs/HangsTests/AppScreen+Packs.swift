//
//  AppScreen+Packs.swift
//  HangsTests
//
//  #194 C8: the My packs list — delivered, generating, pending and failed
//  orders in one screen.
//

import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makePacks() async -> AnyView {
        let orders: [OrderSnapshot] = [.mockDelivered, .mockGenerating, .mockPending, .mockFailed]
        let vm = MyPacksViewModel(service: MockPackOrderService(listResult: .success(orders)))
        await vm.refresh()
        // No NavigationStack: its bar height differs per device and would tie
        // the baseline to the simulator model.
        return AnyView(MyPacksView(viewModel: vm, onPlayPack: { _ in }))
    }
}
