//
//  ResultAnswerPanel.swift
//  Hangs
//
//  The result screen's second-rank zone (issue #127, re-cut for #131 Track D
//  Variant A): the answer card. Byte-identical structure for every verdict —
//  only the label changes. The explanation scrolls INSIDE this card (founder
//  modification); the screen chrome never scrolls.
//
//  #131 Track D: the card no longer carries the "you said" / "the question" /
//  "source" tail rows. Those are secondary meta and now live in the single
//  `ResultMetaRow` below the card, so the card holds exactly two things: the
//  answer and why.
//

import SwiftUI

struct ResultAnswerPanel: View {
    /// "your answer" (correct) / "the answer" (otherwise) / "the question" (recap).
    let answerLabel: LocalizedStringKey
    /// The 38pt answer — or, in recap mode, the question stem at a smaller size.
    let answerText: String
    /// Recap fallback (nil evaluation or empty answer): the stem is the dominant
    /// text and reads neutral, since it is not an answer.
    let isRecap: Bool
    /// Explanation text; nil omits the whole "why" block.
    let explanation: String?

    let onHearIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HangsSectionLabel(
                text: answerLabel,
                color: isRecap ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.successText
            )

            Text(answerText)
                .font(.hangsDisplay(isRecap ? 26 : 38))
                .tracking(-1.4)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(isRecap ? 3 : 2)
                .minimumScaleFactor(0.4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            if let explanation {
                hairline.padding(.top, 12)
                HStack {
                    HangsSectionLabel(text: "why", color: Theme.Hangs.Colors.blue)
                    Spacer()
                    hearItControl
                }
                .padding(.top, 12)
                explanationScroll(explanation)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .hangsShadow(Theme.Hangs.Shadow.card)
    }

    // MARK: Explanation (internal scroll, never clips the screen)

    /// The explanation scrolls WITHIN the card when it overflows — the visible
    /// affordance is the scroll indicator plus a bottom fade into the card.
    private func explanationScroll(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.hangsBody(15))
                .lineSpacing(3)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Theme.Hangs.Colors.bgCard.opacity(0), Theme.Hangs.Colors.bgCard],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 18)
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("result.explanation")
    }

    private var hearItControl: some View {
        Button(action: onHearIt) {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                Text("hear it")
                    .font(.hangsBody(12, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.blue)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.hearIt")
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Hangs.Colors.hairline).frame(height: 1)
    }
}
