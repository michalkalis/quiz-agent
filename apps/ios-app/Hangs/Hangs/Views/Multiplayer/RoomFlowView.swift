//
//  RoomFlowView.swift
//  Hangs
//
//  #212: the whole game together, full screen over Home. The screen follows
//  the room's state; ✕ leaves (a host ends the game for everyone).
//

import SwiftUI

struct RoomFlowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: RoomViewModel
    @State private var confirmingLeave = false
    let onShowPlans: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .dynamicTypeSize(...QuizTypeSize.screenCap)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: viewModel.appMovedToBackground()
            case .active: viewModel.appBecameActive()
            default: break
            }
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
        .alert(
            "No free questions left",
            isPresented: Binding(
                get: { viewModel.quotaReached && viewModel.screen == .lobby },
                set: { if !$0 { viewModel.quotaReached = false } }
            )
        ) {
            Button("Get Trubbo Plus", action: showPlans)
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your free questions for this month are used up. A game together uses your questions.")
        }
        .confirmationDialog(
            viewModel.isHost ? "End the game for everyone?" : "Leave the game?",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button(viewModel.isHost ? "End game" : "Leave", role: .destructive, action: close)
        }
        .sheet(isPresented: $viewModel.isAskingHostName) {
            RoomNameSheet(title: "Your name for the other players", initialName: "") { name in
                Task { await viewModel.confirmHostName(name) }
            }
            .presentationDetents([.height(Metrics.nameSheetHeight)])
        }
    }

    private var topBar: some View {
        HStack {
            HangsNavChip(icon: "xmark", label: "Close", action: closeTapped)
                .accessibilityIdentifier("room.close")
            Spacer()
            Text("Play together")
                .font(.hangsOverline)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Hangs.Colors.sectionLabel)
            Spacer()
            Color.clear.frame(width: Metrics.chipSide, height: Metrics.chipSide)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .overlay(alignment: .bottom) {
            if viewModel.connectionTrouble {
                Text("Connection is slow…")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.warning)
                    .offset(y: Theme.Hangs.Spacing.sm)
                    .accessibilityIdentifier("room.connection")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.screen {
        case .start:
            RoomStartView(viewModel: viewModel)
        case .lobby:
            if viewModel.isHost {
                RoomLobbyHostView(viewModel: viewModel)
            } else {
                RoomLobbyGuestView(viewModel: viewModel)
            }
        case .question:
            RoomQuestionView(viewModel: viewModel)
        case .reveal:
            RoomRevealView(viewModel: viewModel, holdsResults: false)
        case .roundWait:
            RoomRevealView(viewModel: viewModel, holdsResults: true)
        case .finished:
            RoomFinalView(viewModel: viewModel, onShowPlans: showPlans, onClose: close)
        case .ended:
            endedView
        }
    }

    private var endedView: some View {
        VStack(spacing: Theme.Hangs.Spacing.md) {
            Spacer()
            HangsHeroBlock(title: "This game has ended", subtitle: "The game is over, or you're no longer in the room.", titleFont: .hangsTitle)
            Spacer()
            HangsPrimaryButton(title: "Done", action: onClose)
                .accessibilityIdentifier("room.ended.done")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
        .accessibilityIdentifier("room.ended")
    }

    /// Nothing to lose before anyone joined or once it is over: close at once.
    private func closeTapped() {
        switch viewModel.screen {
        case .start, .finished, .ended: close()
        case .lobby where viewModel.isHost && viewModel.players.count <= 1: close()
        default: confirmingLeave = true
        }
    }

    private func close() {
        Task {
            await viewModel.leave()
            onClose()
        }
    }

    private func showPlans() {
        Task {
            await viewModel.leave()
            onShowPlans()
        }
    }

    private enum Metrics {
        static let chipSide: CGFloat = 44
        static let nameSheetHeight: CGFloat = 300
    }
}
