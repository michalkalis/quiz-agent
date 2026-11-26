//
//  RoomPlayersStrip.swift
//  Hangs
//
//  #224.4: under the progress header of a question: everyone's face (a check
//  once they answered). #249.5: the answer time moved to solo's bar under
//  the question.
//

import SwiftUI

struct RoomPlayersStrip: View {
    let players: [RoomState.Player]
    let answered: Set<String>

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Hangs.Spacing.xs) {
            ForEach(players) { player in
                face(player)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room.question.players")
    }

    private func face(_ player: RoomState.Player) -> some View {
        VStack(spacing: Metrics.nameGap) {
            RoomPlayerAvatar(name: player.displayName, color: player.color, size: Metrics.face)
                .overlay(alignment: .bottomTrailing) {
                    if answered.contains(player.participantId) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Metrics.badge))
                            .foregroundStyle(Theme.Hangs.Colors.textOnAction, Theme.Hangs.Colors.greenCheck)
                            .offset(x: Metrics.badgeOffset, y: Metrics.badgeOffset)
                    }
                }
            Text(verbatim: player.displayName)
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .lineLimit(1)
                .frame(maxWidth: Metrics.nameWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(answered.contains(player.participantId) ? Text("answered") : Text(verbatim: ""))
    }

    private enum Metrics {
        static let face: CGFloat = 36
        static let badge: CGFloat = 16
        static let badgeOffset: CGFloat = 3
        static let nameGap: CGFloat = 2
        static let nameWidth: CGFloat = 56
    }
}
