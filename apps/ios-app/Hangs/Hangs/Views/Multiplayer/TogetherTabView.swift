//
//  TogetherTabView.swift
//  Hangs
//
//  #216.2 (founder 2026-10-30, variant B): the Together tab — games on this
//  Wi-Fi and Host a game. Once the player hosts or joins, the game opens full
//  screen (`RoomFlowView`) and the tab gets a fresh room when it closes.
//

import SwiftUI

struct TogetherTabView: View {
    @ObservedObject var viewModel: RoomViewModel
    /// Up while the host-name sheet is on screen: the game opens only after it
    /// has gone, never over a sheet that is still closing.
    @State private var isNameSheetUp = false
    let onGameOpened: (RoomViewModel) -> Void

    var body: some View {
        RoomStartView(viewModel: viewModel)
            .padding(.top, Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
            .onChange(of: viewModel.screen) { _, screen in
                if screen != .start, !isNameSheetUp { onGameOpened(viewModel) }
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } }),
                presenting: viewModel.errorMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(verbatim: message)
            }
            .sheet(isPresented: $viewModel.isAskingHostName, onDismiss: nameSheetClosed) {
                RoomNameSheet(title: "Your name for the other players", initialName: "") { name in
                    Task { await viewModel.confirmHostName(name) }
                }
                .presentationDetents([.height(Metrics.nameSheetHeight)])
                .onAppear { isNameSheetUp = true }
            }
    }

    private func nameSheetClosed() {
        isNameSheetUp = false
        if viewModel.screen != .start { onGameOpened(viewModel) }
    }

    private enum Metrics {
        /// Same sheet as in `RoomFlowView`.
        static let nameSheetHeight: CGFloat = 300
    }
}
