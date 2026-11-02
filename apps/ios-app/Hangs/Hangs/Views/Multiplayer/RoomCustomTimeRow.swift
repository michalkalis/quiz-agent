//
//  RoomCustomTimeRow.swift
//  Hangs
//
//  #224: the answer time beyond the presets. A stepper in 1 s steps over the
//  server's range (3–60 s). The host taps it several times in a row, so the
//  value is sent once, a moment after the last tap, not on every step (the
//  room takes one change at a time).
//

import SwiftUI

struct RoomCustomTimeRow: View {
    @ObservedObject var viewModel: RoomViewModel
    /// Identifier of the stepper, set by the screen that places the row.
    let identifier: String

    @State private var draft: Int

    init(viewModel: RoomViewModel, identifier: String) {
        self.viewModel = viewModel
        self.identifier = identifier
        _draft = State(initialValue: viewModel.settings.thinkingSeconds)
    }

    var body: some View {
        Stepper(value: $draft, in: MultiplayerSettings.thinkingRange) {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                Text("Custom time")
                    .font(HangsRowStyle.labelFont)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Spacer(minLength: 0)
                Text(verbatim: MultiplayerSettings.secondsDisplay(draft))
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.rowValue)
                    .monospacedDigit()
            }
        }
        .padding(HangsRowStyle.padding)
        .frame(minHeight: HangsRowStyle.minHeight)
        .accessibilityIdentifier(identifier)
        .task(id: draft) { await commit(draft) }
        // The room refused the change, or the other screen set it: follow the stored value.
        .onChange(of: viewModel.settings.thinkingSeconds) { _, seconds in draft = seconds }
    }

    private func commit(_ seconds: Int) async {
        guard seconds != viewModel.settings.thinkingSeconds else { return }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        await viewModel.setThinkingSeconds(seconds)
    }
}
