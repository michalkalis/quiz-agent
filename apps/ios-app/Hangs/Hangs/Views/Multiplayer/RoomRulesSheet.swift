//
//  RoomRulesSheet.swift
//  Hangs
//
//  #213.8: the host changes the rules mid-game, under the gear. The answer
//  time and reading aloud apply from the next question; the reveal is fixed
//  once the game has started.
//

import SwiftUI

struct RoomRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RoomViewModel
    /// #224: the host opened the custom time; also true for any non-preset value.
    @State private var showsCustomTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            HStack {
                Text("Game rules")
                    .font(.hangsHeading)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done", action: close)
                    .font(.hangsButton)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("room.rules.done")
            }
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                HangsSectionLabel(text: "Answer time")
                Picker("Answer time", selection: thinkingSeconds) {
                    ForEach(MultiplayerSettings.thinkingChoices, id: \.self) { seconds in
                        Text(verbatim: MultiplayerSettings.secondsDisplay(seconds)).tag(seconds)
                    }
                    Text("Custom").tag(Self.customTag)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("room.rules.sheet.time")
                if isCustomTime {
                    HangsCard {
                        RoomCustomTimeRow(viewModel: viewModel, identifier: "room.rules.sheet.time.stepper")
                    }
                    .disabled(viewModel.isSavingSettings)
                }
            }
            HangsCard {
                VStack(spacing: 0) {
                    HangsToggleRow(label: "Read questions aloud", isOn: readsAloud)
                        .accessibilityIdentifier("room.rules.sheet.readsAloud")
                    HangsDivider()
                    HangsConfigRowLabel(
                        label: "When to show answers",
                        value: viewModel.settings.revealMode.displayName,
                        valueColor: Theme.Hangs.Colors.muted,
                        showsChevron: false,
                        labelColor: Theme.Hangs.Colors.muted
                    )
                    .accessibilityIdentifier("room.rules.sheet.reveal")
                }
            }
            .disabled(viewModel.isSavingSettings)
            Text("Changes apply from the next question. When to show answers can only be changed before the game.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Hangs.Spacing.md)
        .presentationDetents([.medium])
    }

    /// Outside the server's range, so it never collides with a real value.
    private static let customTag = 0

    private var isCustomTime: Bool {
        showsCustomTime || !MultiplayerSettings.isPreset(viewModel.settings.thinkingSeconds)
    }

    private var thinkingSeconds: Binding<Int> {
        Binding(
            get: { isCustomTime ? Self.customTag : viewModel.settings.thinkingSeconds },
            set: { picked in
                showsCustomTime = picked == Self.customTag
                if picked != Self.customTag { setTime(picked) }
            }
        )
    }

    private var readsAloud: Binding<Bool> {
        Binding(get: { viewModel.settings.readsAloud }, set: setReadsAloud)
    }

    private func setTime(_ seconds: Int) {
        Task { await viewModel.setThinkingSeconds(seconds) }
    }

    private func setReadsAloud(_ on: Bool) {
        Task { await viewModel.setReadsAloud(on) }
    }

    private func close() {
        dismiss()
    }
}
