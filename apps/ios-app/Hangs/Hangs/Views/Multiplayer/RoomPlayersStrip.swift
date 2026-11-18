//
//  RoomPlayersStrip.swift
//  Hangs
//
//  #224.4: under the progress header of a question: everyone's face (a check
//  once they answered) and the answer time on the right.
//

import SwiftUI

struct RoomPlayersStrip: View {
    let players: [RoomState.Player]
    let answered: Set<String>
    /// Seconds of answer time left; nil while the host still reads.
    let secondsLeft: Int?
    /// The whole answer time, shown ahead of the clock ("30 s after reading").
    let fullSeconds: Int?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Hangs.Spacing.sm) {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                ForEach(players) { player in
                    face(player)
                }
            }
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            timeBlock
        }
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

    @ViewBuilder
    private var timeBlock: some View {
        if let secondsLeft {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(secondsLeft) s")
                    .font(.hangsMonoValue)
                    .monospacedDigit()
                    .foregroundStyle(secondsLeft <= Metrics.hurrySeconds ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("room.question.timer")
                Text("to answer")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
        } else if let fullSeconds {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(fullSeconds) s")
                    .font(.hangsMonoValue)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("room.question.timer")
                Text("after reading")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
        }
    }

    private enum Metrics {
        static let face: CGFloat = 36
        static let badge: CGFloat = 16
        static let badgeOffset: CGFloat = 3
        static let nameGap: CGFloat = 2
        static let nameWidth: CGFloat = 56
        static let hurrySeconds = 5
    }
}
