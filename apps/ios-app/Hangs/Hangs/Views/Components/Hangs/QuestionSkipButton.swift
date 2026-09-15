//
//  QuestionSkipButton.swift
//  Hangs
//
//  #179 D3 (founder 2026-09-15, variant A): ONE skip control on both question
//  screens. MCQ drew a capsule reading "Skip question", the voice footer a bare
//  word "Skip", and the voice command is a third thing again ("preskoč") —
//  three shapes and two words for the driver's only escape hatch from a
//  question they cannot answer. One capsule, one word, same place on both.
//
//  Why the capsule (variant A, not the flat link): it is a bigger target for a
//  thumb leaving the wheel, it says "button" rather than "caption" next to two
//  filled controls, and it already owns the place where an in-flight skip spins
//  (#174).
//
//  The word is IMPERATIVE in every language (founder: "Preskoč", never
//  "Preskočiť") — the button IS the voice command, so reading it teaches it.
//

import SwiftUI

struct QuestionSkipButton: View {
    /// A skip in flight spins IN this capsule (#174). The label stays put so the
    /// capsule cannot change width under the driver's thumb.
    let isSkipping: Bool
    /// The caller owns the rule: MCQ dies on an answer in flight, the voice
    /// footer also while the mic is live.
    let isDisabled: Bool
    /// The voice footer sits beside the 48pt Record button and matches it; the
    /// MCQ footer's capsule stands alone and stays compact.
    var height: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSkipping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Hangs.Colors.ink)
                        .accessibilityIdentifier("question.processingIndicator")
                } else {
                    // Founder pick (#171, 2026-09-06): two chevrons read as
                    // "skip"; the play+bar glyph read as media transport.
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .semibold))
                }

                Text("Skip")
                    .font(.hangsBody(15, weight: .semibold))
                    // The founder's one-line rule for the bottom row: the word
                    // shrinks before it ever wraps or pushes a neighbour out.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(height: height)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Capsule().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // Busy is not unavailable: a skipping capsule keeps full contrast so its
        // spinner reads, while one disabled by an answer in flight dims.
        .opacity(isDisabled && !isSkipping ? 0.45 : 1)
        .accessibilityIdentifier("question.skip")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 20) {
            QuestionSkipButton(isSkipping: false, isDisabled: false) {}
            QuestionSkipButton(isSkipping: true, isDisabled: true, height: 48) {}
            QuestionSkipButton(isSkipping: false, isDisabled: true, height: 48) {}
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
