//
//  CommandHeardLine.swift
//  Hangs
//
//  "What the app hears" (founder 2026-11-22) where no listening bar is on
//  screen: the question screen keeps the bar's slot empty during the read and
//  without a countdown (TF build 90), so the preview shows there as this quiet
//  line instead. Inside a bar, `ListenBar(heard:)` shows the same thing.
//

import SwiftUI

/// A faint "I hear: “repeat”" with a soft fill that grows with the certainty
/// and is full when the command fired. Hidden from VoiceOver: a guess is not
/// announced, the command's own effect is.
struct CommandHeardLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let heard: CommandHeard
    var language: CommandLanguage = .english

    var body: some View {
        Text(verbatim: VoiceCommandLexicon.heardCaption(heard.command, language: language))
            .font(.hangsMonoMini)
            .tracking(0.6)
            .foregroundStyle(Theme.Hangs.Colors.live)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .padding(.vertical, Theme.Hangs.Spacing.xxs)
            .background {
                // Under Reduce Motion only the label shows.
                if !reduceMotion {
                    Rectangle()
                        .fill(Theme.Hangs.Colors.liveSoft)
                        .scaleEffect(x: heard.certainty, anchor: .leading)
                        .animation(.easeOut(duration: 0.2), value: heard.certainty)
                }
            }
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            CommandHeardLine(heard: CommandHeard(command: .repeatQuestion, certainty: 0.5))
            CommandHeardLine(heard: .fired(.again), language: .slovak)
        }
        .padding()
        .background(Theme.Hangs.Colors.bg)
    }
#endif
