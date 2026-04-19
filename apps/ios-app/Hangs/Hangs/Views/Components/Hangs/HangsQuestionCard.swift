//
//  HangsQuestionCard.swift
//  Hangs
//
//  Prompt block used on the question + result screens. A thin colored bar
//  on the left hugs the question text. The parent view is responsible for
//  wrapping this in a ScrollView when the text may overflow.
//

import SwiftUI

/// Question prompt with a left vertical rule. Sizes to content; use inside
/// a parent `ScrollView` when the text can overflow the available height.
struct HangsQuestionPrompt: View {
    let text: String
    var barColor: Color = Theme.Hangs.Colors.blue
    var textFont: Font = .hangsDisplaySM
    var textColor: Color = Theme.Hangs.Colors.ink
    var minimumScaleFactor: CGFloat = 0.55

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity, alignment: .top)
            Text(text)
                .font(textFont)
                .tracking(-1)
                .foregroundColor(textColor)
                .lineSpacing(-2)
                .minimumScaleFactor(minimumScaleFactor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }
}

/// Result "answer" card: title label + value + hairline + second label + body.
/// Used on Result-Correct (YOUR ANSWER / THE QUESTION) and Result-Incorrect
/// (YOU SAID / THE ANSWER).
struct HangsAnswerComparisonCard: View {
    let primaryLabel: String
    let primaryValue: String
    let primaryValueColor: Color
    let primaryBadge: HangsResultKind
    let secondaryLabel: String
    let secondaryValue: String
    let secondaryValueColor: Color
    let secondaryBadge: HangsResultKind?
    var primaryValueFont: Font = .hangsDisplay(32, weight: .black)
    var secondaryValueFont: Font = .hangsBody(15, weight: .medium)

    var body: some View {
        HangsCard(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HangsSectionLabel(text: primaryLabel, color: primaryBadge == .correct ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.pink)
                    Spacer()
                    HangsInlineBadge(kind: primaryBadge, size: 24)
                }
                Text(primaryValue)
                    .font(primaryValueFont)
                    .tracking(-0.5)
                    .foregroundColor(primaryValueColor)
                Rectangle().fill(Theme.Hangs.Colors.hairline).frame(height: 1)
                HStack {
                    HangsSectionLabel(text: secondaryLabel,
                                      color: secondaryBadge == .correct ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.pink)
                    if let secondaryBadge {
                        Spacer()
                        HangsInlineBadge(kind: secondaryBadge, size: 20)
                    }
                }
                Text(secondaryValue)
                    .font(secondaryValueFont)
                    .foregroundColor(secondaryBadge == nil ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        HangsQuestionPrompt(
            text: "What is the capital of France?",
            barColor: Theme.Hangs.Colors.blue
        )
        HangsAnswerComparisonCard(
            primaryLabel: "YOUR ANSWER",
            primaryValue: "Paris",
            primaryValueColor: Theme.Hangs.Colors.ink,
            primaryBadge: .correct,
            secondaryLabel: "THE QUESTION",
            secondaryValue: "What is the capital of France?",
            secondaryValueColor: Theme.Hangs.Colors.ink,
            secondaryBadge: nil
        )
    }
    .padding(20)
    .background(Theme.Hangs.Colors.bg)
}
#endif
