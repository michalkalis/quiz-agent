//
//  ResultAnswerPanel.swift
//  Hangs
//
//  The result card's body (issue #127, re-cut for #131 Track D and again for
//  #224, canvas B1b): the question in quiet text, the answer big, on a miss what
//  the driver said (struck through, one line), then "why" with its listen chip.
//  Byte-identical structure for every verdict, only the label changes. The
//  explanation scrolls INSIDE it; the screen chrome never scrolls.
//

import SwiftUI

struct ResultAnswerPanel: View {
    /// The question, quiet, above the answer. Ignored in recap mode (the stem IS the answer text).
    let questionStem: String?
    /// "your answer" (correct) / "the answer" (otherwise) / "the question" (recap).
    let answerLabel: LocalizedStringKey
    /// The answer, or in recap mode the question stem.
    let answerText: String
    /// Recap fallback (nil evaluation or empty answer): the stem is the dominant
    /// text and reads neutral, since it is not an answer.
    let isRecap: Bool
    /// A right answer is the one thing on the screen that turns green.
    let isCorrect: Bool
    /// Explanation text; nil omits the whole "why" block.
    let explanation: String?
    /// What the driver said, when it is not the answer above (a miss).
    var userAnswer: String? = nil

    let onHearIt: () -> Void

    private enum Metrics {
        static let blockGap = Theme.Hangs.Spacing.sm
        static let labelGap = Theme.Hangs.Spacing.xxs
        static let fadeHeight: CGFloat = 18
        static let hearItHeight: CGFloat = 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let questionStem, !isRecap {
                Text(questionStem)
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Metrics.blockGap)
                    .accessibilityIdentifier("result.question")
            }

            ResultAnswerHeadline(
                label: answerLabel,
                text: answerText,
                isRecap: isRecap,
                isCorrect: isCorrect,
                identifier: "result.answer"
            )

            if let userAnswer {
                saidLine(userAnswer)
                    .padding(.top, Metrics.labelGap)
            }

            if let explanation {
                HangsDivider()
                    .padding(.vertical, Metrics.blockGap)
                HStack {
                    HangsSectionLabel(text: "why")
                    Spacer()
                    hearItControl
                }
                explanationScroll(explanation)
                    .padding(.top, Metrics.labelGap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Your answer: ~~X~~", one quiet line (it was wrong, so it is struck through).
    private func saidLine(_ answer: String) -> some View {
        (Text("you said") + Text(verbatim: ": ") + Text(verbatim: answer).strikethrough(pattern: .solid))
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("result.said")
    }

    // MARK: Explanation (internal scroll, never clips the screen)

    /// The explanation scrolls WITHIN the card when it overflows: the visible
    /// affordance is the scroll indicator plus a bottom fade into the card.
    private func explanationScroll(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.hangsBodyLG)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Theme.Hangs.Colors.bgCard.opacity(0), Theme.Hangs.Colors.bgCard],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: Metrics.fadeHeight)
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("result.explanation")
    }

    /// "Hear it": a neutral chip on the card.
    private var hearItControl: some View {
        Button(action: onHearIt) {
            Label {
                Text("hear it")
            } icon: {
                Image(systemName: "speaker.wave.2")
            }
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: Metrics.hearItHeight)
            .background(Capsule().fill(Theme.Hangs.Colors.bgInset))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.hearIt")
    }
}

/// The calm result's answer: its label and the answer, the biggest text on the
/// card, green only when right. Shared by the solo result and the Together reveal.
struct ResultAnswerHeadline: View {
    let label: LocalizedStringKey
    let text: String
    var isRecap = false
    let isCorrect: Bool
    let identifier: String

    private enum Metrics {
        static let labelGap = Theme.Hangs.Spacing.xxs
        /// Canvas B1b: the answer is the biggest thing on the card.
        static let answerSize: CGFloat = 34
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.labelGap) {
            HangsSectionLabel(text: label)
            Text(text)
                .font(isRecap ? .hangsHeading : .hangsDisplay(Metrics.answerSize))
                .foregroundStyle(isCorrect ? Theme.Hangs.Colors.successText : Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
    }
}
