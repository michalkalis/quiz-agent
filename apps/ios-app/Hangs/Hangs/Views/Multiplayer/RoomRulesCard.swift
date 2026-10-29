//
//  RoomRulesCard.swift
//  Hangs
//
//  #213.8: the host sets the rules of a game together in the lobby.
//

import SwiftUI

struct RoomRulesCard: View {
    @ObservedObject var viewModel: RoomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Game rules")
            HangsCard {
                VStack(spacing: 0) {
                    revealMenu
                    HangsDivider()
                    timeMenu
                    HangsDivider()
                    HangsToggleRow(label: "Read questions aloud", isOn: readsAloud)
                        .accessibilityIdentifier("room.rules.readsAloud")
                }
            }
            .disabled(viewModel.isSavingSettings)
            Text("Applies to all players. Your solo settings stay as they are.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var revealMenu: some View {
        Menu {
            ForEach(RoomState.RevealMode.allCases, id: \.self) { mode in
                Button(mode.displayName) { setReveal(mode) }
                    .accessibilityIdentifier("room.rules.reveal.\(mode.rawValue)")
            }
        } label: {
            HangsConfigRowLabel(label: "When to show answers", value: viewModel.settings.revealMode.displayName)
        }
        .accessibilityIdentifier("room.rules.reveal")
    }

    private var timeMenu: some View {
        Menu {
            ForEach(MultiplayerSettings.thinkingChoices, id: \.self) { seconds in
                Button(MultiplayerSettings.secondsDisplay(seconds)) { setTime(seconds) }
                    .accessibilityIdentifier("room.rules.time.\(seconds)")
            }
        } label: {
            HangsConfigRowLabel(label: "Answer time", value: MultiplayerSettings.secondsDisplay(viewModel.settings.thinkingSeconds))
        }
        .accessibilityIdentifier("room.rules.time")
    }

    private var readsAloud: Binding<Bool> {
        Binding(get: { viewModel.settings.readsAloud }, set: setReadsAloud)
    }

    private func setReveal(_ mode: RoomState.RevealMode) {
        Task { await viewModel.setRevealMode(mode) }
    }

    private func setTime(_ seconds: Int) {
        Task { await viewModel.setThinkingSeconds(seconds) }
    }

    private func setReadsAloud(_ on: Bool) {
        Task { await viewModel.setReadsAloud(on) }
    }
}
