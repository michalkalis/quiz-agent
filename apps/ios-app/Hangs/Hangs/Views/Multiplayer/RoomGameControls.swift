//
//  RoomGameControls.swift
//  Hangs
//
//  #249.4 (founder 2026-11-26: "ideally like the single game"): the right
//  side of a game together's top bar while it is played, laid out like the
//  solo quiz bar (`quizToolbar`): the speaker + pause pill, then ⋯.
//

import SwiftUI

/// Every player gets the speaker (reading questions aloud on this phone); the
/// host also gets pause, which stops the answer time for everyone, and the ⋯
/// with the game rules. A guest keeps the empty ⋯ slot, so the speaker
/// stays in the pill's place, not at the screen edge.
struct RoomGameControls: View {
    @ObservedObject var viewModel: RoomViewModel
    let openRules: () -> Void

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            QuizControlPill(
                isMuted: isMuted,
                isPaused: viewModel.isPaused,
                isPauseEnabled: viewModel.canTogglePause,
                onMute: toggleSound,
                onPause: pauseAction,
                buttonHeight: Metrics.side
            )
            .glassEffect(.regular.interactive(), in: Capsule())
            if viewModel.isHost {
                moreMenu
            } else {
                Color.clear.frame(width: Metrics.side, height: Metrics.side)
            }
        }
    }

    /// The host's speaker is the room's "read aloud" rule (guests see "the
    /// host is reading"); a guest's speaker is their own phone only.
    private var isMuted: Bool {
        viewModel.isHost ? !viewModel.settings.readsAloud : !viewModel.guestReadsAloud
    }

    private func toggleSound() {
        Task {
            if viewModel.isHost {
                await viewModel.setReadsAloud(!viewModel.settings.readsAloud)
            } else {
                await viewModel.setGuestReadsAloud(!viewModel.guestReadsAloud)
            }
        }
    }

    /// Guests have no pause: the host pauses the game for everyone.
    private var pauseAction: (() -> Void)? {
        guard viewModel.isHost else { return nil }
        return { [viewModel] in Task { await viewModel.togglePause() } }
    }

    /// Solo's ⋯ holds Settings; the host's holds the game rules.
    private var moreMenu: some View {
        Menu {
            Button(action: openRules) {
                Label("Game rules", systemImage: "gearshape")
            }
            .accessibilityIdentifier("room.rules.open")
        } label: {
            HangsNavChipLabel(icon: "ellipsis")
        }
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("room.moreMenu")
    }

    private enum Metrics {
        static let side: CGFloat = 44
    }
}
