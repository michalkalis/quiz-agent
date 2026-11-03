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
//  #224 (founder, TF 2026-11-02): the word is "Ďalšia" / "Další" / "Next" —
//  easier to say than "Preskoč". The button IS the voice command, so reading
//  it teaches it; the old words stay as hidden synonyms (VoiceCommandLexicon).
//
//  #224 (founder, TF 2026-11-02, canvas E1): icon only, round, the word is the
//  accessibility label. The listen bar's chips still name the command.
//

import SwiftUI

struct QuestionSkipButton: View {
    /// A skip in flight spins IN this control (#174), in the glyph's place.
    let isSkipping: Bool
    /// The caller owns the rule: MCQ dies on an answer in flight, the voice
    /// footer also while the mic is live.
    let isDisabled: Bool
    /// The voice footer sits beside the main action and matches its height; the
    /// MCQ footer's capsule stands alone.
    var height: CGFloat = Self.chipHeight

    /// #194 R-Question: the voice footer row (answer · type · skip).
    static let rowHeight: CGFloat = 56
    /// The same row in a short container, and the lone MCQ capsule (R-MCQ).
    static let compactRowHeight: CGFloat = 48
    /// The lone MCQ capsule in a short container.
    static let chipHeight: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isSkipping {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.Hangs.Colors.ink)
                        .accessibilityIdentifier("question.processingIndicator")
                } else {
                    // Founder pick (#171, 2026-09-06): two chevrons read as
                    // "skip"; the play+bar glyph read as media transport.
                    Image(systemName: "chevron.right.2")
                        .font(.hangsButton)
                }
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            // Icon only (#224, E1): a round control as tall as the row, so the
            // width is the same in every language and the two labelled buttons
            // beside it get the room.
            .frame(width: height, height: height)
            // Canvas E1: the same visible pill as the Type button beside it.
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .overlay(Capsule().strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // Busy is not unavailable: a skipping control keeps full contrast so its
        // spinner reads, while one disabled by an answer in flight dims.
        .opacity(isDisabled && !isSkipping ? 0.45 : 1)
        // The word lives here now; it is still the voice command (#174).
        .accessibilityLabel(Text("Next (skip question)"))
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
