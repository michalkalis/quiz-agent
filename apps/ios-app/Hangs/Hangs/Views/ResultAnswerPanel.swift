//
//  ResultAnswerPanel.swift
//  Hangs
//
//  The result screen's second-rank zone (issue #127, re-cut for #131 Track D
//  Variant A): the answer and why. Byte-identical structure for every verdict —
//  only the label changes. The explanation scrolls INSIDE it (founder
//  modification); the screen chrome never scrolls.
//
//  #194 R-Result / R-Wrong: it is printed on the category card under the
//  verdict word. The answer sits on its white sticker; on a miss the driver's
//  own answer follows it, struck through (founder 2026-10-08: show BOTH).
//

import SwiftUI

struct ResultAnswerPanel: View {
    /// "your answer" (correct) / "the answer" (otherwise) / "the question" (recap).
    let answerLabel: LocalizedStringKey
    /// The answer — or, in recap mode, the question stem.
    let answerText: String
    /// Recap fallback (nil evaluation or empty answer): the stem is the dominant
    /// text and reads neutral, since it is not an answer.
    let isRecap: Bool
    /// Explanation text; nil omits the whole "why" block.
    let explanation: String?
    /// What the driver said, when it is not the answer above (a miss).
    var userAnswer: String? = nil
    /// The card the panel is printed on: its text colour, and the fill the
    /// explanation fades into.
    var style = Theme.Hangs.Category.Style(fill: Theme.Hangs.Colors.bgCard, text: Theme.Hangs.Colors.ink)

    let onHearIt: () -> Void

    private enum Metrics {
        static let blockGap = Theme.Hangs.Spacing.sm
        static let labelGap = Theme.Hangs.Spacing.xxs
        static let ruleOpacity = 0.25
        static let fadeHeight: CGFloat = 18
        static let hearItHeight: CGFloat = 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.labelGap) {
                HangsSectionLabel(text: answerLabel, color: style.text)
                if isRecap {
                    Text(answerText)
                        .font(.hangsHeading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HangsAnswerSticker(text: answerText)
                }
            }

            if let userAnswer {
                saidBlock(userAnswer)
                    .padding(.top, Metrics.blockGap)
            }

            if let explanation {
                Rectangle()
                    .fill(style.text.opacity(Metrics.ruleOpacity))
                    .frame(height: 1)
                    .padding(.top, Metrics.blockGap)
                HStack {
                    HangsSectionLabel(text: "why", color: style.text)
                    Spacer()
                    hearItControl
                }
                .padding(.top, Theme.Hangs.Spacing.xs)
                explanationScroll(explanation)
                    .padding(.top, Metrics.labelGap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(style.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// R-Wrong "your answer": the label, then the driver's words struck through.
    private func saidBlock(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.labelGap) {
            HangsSectionLabel(text: "you said", color: style.text)
            // Answer text is content: a content preset (R-Wrong t-heading).
            Text(verbatim: answer)
                .font(.hangsHeading)
                .strikethrough(pattern: .solid)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Explanation (internal scroll, never clips the screen)

    /// The explanation scrolls WITHIN the card when it overflows — the visible
    /// affordance is the scroll indicator plus a bottom fade into the card.
    private func explanationScroll(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.hangsBodyLG)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [style.fill.opacity(0), style.fill],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Metrics.fadeHeight)
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("result.explanation")
    }

    /// R-Result: "hear it" is a white chip on the card, like the category chip.
    private var hearItControl: some View {
        Button(action: onHearIt) {
            Label {
                Text("hear it")
            } icon: {
                Image(systemName: "speaker.wave.2")
            }
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Category.chipText)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: Metrics.hearItHeight)
            .background(Capsule().fill(Theme.Hangs.Category.chipFill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.hearIt")
    }
}
