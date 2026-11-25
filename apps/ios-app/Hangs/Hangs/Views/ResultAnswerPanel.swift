//
//  ResultAnswerPanel.swift
//  Hangs
//
//  The result card's body (issue #127, re-cut for #131 Track D and again for
//  #224, canvas B1b): the answer big, on a miss what the driver said (struck
//  through, one line), then "why" with its listen chip. The explanation scrolls
//  INSIDE it; the screen chrome never scrolls.
//
//  TF build 90 (founder pick C1): the question left the card (it is one tap
//  away, `ResultQuestionSheet`); the answer is always the question's own; an
//  accepted answer that was heard differently says what was heard, unstruck.
//

import SwiftUI

struct ResultAnswerPanel: View {
    /// What the driver said, when it is worth a line under the answer.
    enum SaidLine: Equatable {
        /// A miss: struck through.
        case missed(String)
        /// TF build 90: accepted, but heard as something else ("solo" for
        /// "soľ"). Quiet and unstruck: the answer counted.
        case heard(String)
    }

    /// "the answer", or "the question" (recap).
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
    var saidLine: SaidLine? = nil
    /// #235 F3: the last "hear it" could not be fetched; a note says so.
    var hearItFailed = false

    /// nil = no "hear it": a silent quiz (founder 2026-11-22) reads nothing.
    let onHearIt: (() -> Void)?

    private enum Metrics {
        static let blockGap = Theme.Hangs.Spacing.sm
        static let labelGap = Theme.Hangs.Spacing.xxs
        static let fadeHeight: CGFloat = 18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ResultAnswerHeadline(
                label: answerLabel,
                text: answerText,
                isRecap: isRecap,
                isCorrect: isCorrect,
                identifier: "result.answer"
            )

            if let saidLine {
                said(saidLine)
                    .padding(.top, Metrics.labelGap)
            }

            if let explanation {
                HangsDivider()
                    .padding(.vertical, Metrics.blockGap)
                HStack {
                    HangsSectionLabel(text: "why")
                    Spacer()
                    if let onHearIt {
                        hearItControl(onHearIt)
                    }
                }
                if hearItFailed {
                    ReadAloudFailureNote(identifier: "result.hearItFailed")
                        .padding(.top, Metrics.labelGap)
                }
                explanationScroll(explanation, onRead: onHearIt)
                    .padding(.top, Metrics.labelGap)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One quiet line: "you said: ~~X~~" on a miss, "heard: X" on an accepted
    /// answer that was transcribed differently.
    private func said(_ line: SaidLine) -> some View {
        Group {
            switch line {
            case let .missed(answer):
                Text("you said") + Text(verbatim: ": ") + Text(verbatim: answer).strikethrough(pattern: .solid)
            case let .heard(answer):
                Text("heard", comment: "Result card: label before the transcript of an accepted answer that differs from the correct answer, e.g. 'heard: solo'")
                    + Text(verbatim: ": ") + Text(verbatim: answer)
            }
        }
        .font(.hangsBody)
        .foregroundStyle(Theme.Hangs.Colors.muted)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(line.identifier)
    }

    // MARK: Explanation (internal scroll, never clips the screen)

    /// The explanation scrolls WITHIN the card when it overflows: the visible
    /// affordance is the scroll indicator plus a bottom fade into the card.
    /// #243.9 (founder 2026-11-24, decision 4): a tap on the text reads it,
    /// like "hear it" (none in a silent quiz, where `onRead` is nil).
    private func explanationScroll(_ text: String, onRead: (() -> Void)?) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            if let onRead {
                Button(action: onRead) { explanationText(text) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("result.explanationRead")
            } else {
                explanationText(text)
            }
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

    private func explanationText(_ text: String) -> some View {
        Text(text)
            .font(.hangsBodyLG)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    /// "Hear it": a neutral chip on the card.
    private func hearItControl(_ action: @escaping () -> Void) -> some View {
        ResultCardChip(title: "hear it", systemImage: "speaker.wave.2", action: action)
            .accessibilityIdentifier("result.hearIt")
    }
}

extension ResultAnswerPanel.SaidLine {
    var identifier: String {
        switch self {
        case .missed: "result.said"
        case .heard: "result.heard"
        }
    }
}

/// #235 F3: the line under a "hear it" whose read could not be fetched, in
/// the rating panel's inline failure look. It goes with the next read that
/// plays or with the screen.
struct ReadAloudFailureNote: View {
    let identifier: String

    var body: some View {
        Text("Can't read it aloud right now.")
            .font(.hangsCaption)
            .foregroundStyle(Theme.Hangs.Colors.error)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
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
