//
//  ListeningPill.swift
//  Hangs
//
//  Slim "listening" capsule for the Pencil redesign — replaces the big mic as
//  the active-recording affordance. Issue #45 task 45.6. Waveform icon + copy,
//  pinkSoft fill, pink hairline stroke. Component only; pinning it above Skip in
//  the question bodies is human task 45.8.
//

import SwiftUI

struct ListeningPill: View {
    /// Which question flow the pill is shown in — drives the prompt copy.
    enum Mode {
        case openEnded // free-text spoken answer
        case mcq // multiple choice (A–D)
        case trueFalse // 2-option true/false variant

        /// Prompt copy telling the driver what to say.
        var copy: String {
            switch self {
            case .openEnded: return "Listening — say your answer"
            case .mcq: return "Listening — say A–D or the answer"
            case .trueFalse: return "Listening — say true or false"
            }
        }
    }

    let mode: Mode

    // MARK: - Style tokens (internal so unit tests assert the mapping)

    var fillColor: Color { Theme.Hangs.Colors.pinkSoft }
    var strokeColor: Color { Theme.Hangs.Colors.pink }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(strokeColor)
            Text(mode.copy)
                .font(.hangsMono(12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(strokeColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(fillColor))
        .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mode.copy)
        .accessibilityIdentifier("question.listeningPill")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 12) {
            ListeningPill(mode: .openEnded)
            ListeningPill(mode: .mcq)
            ListeningPill(mode: .trueFalse)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
