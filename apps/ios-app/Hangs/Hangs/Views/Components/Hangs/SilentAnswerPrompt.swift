//
//  SilentAnswerPrompt.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): the mic was open for the whole window to start
//  speaking and the phone heard nothing. That is not a miss, so no "didn't
//  catch that": a calm line on the question offers the three ways on. The
//  open question's footer already has Answer, Type and Skip; the MCQ screen
//  has no mic button, so there the prompt brings its own.
//

import SwiftUI

struct SilentAnswerPrompt: View {
    private enum Metrics {
        static let textSize: CGFloat = 15
    }

    /// Multiple choice: options are tapped, not typed.
    let isMultipleChoice: Bool
    var buttonHeight: CGFloat = QuestionSkipButton.compactRowHeight
    /// The MCQ screen's own mic button; nil where the screen already has one.
    var onSpeak: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            line
                .font(.hangsBody(Metrics.textSize, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("question.silencePrompt")

            if let onSpeak {
                HangsSecondaryButton(title: "Answer by voice", icon: "mic.fill", height: buttonHeight, singleLineTitle: true, action: onSpeak)
                    .accessibilityIdentifier("question.speakAgain")
            }
        }
    }

    private var line: Text {
        isMultipleChoice
            ? Text("Take your time. Speak, tap an option or move on.", comment: "Calm line on a multiple-choice question after the mic heard nothing for the whole answer window; nothing was sent")
            : Text("Take your time. Speak, type or move on.", comment: "Calm line on an open question after the mic heard nothing for the whole answer window; nothing was sent")
    }
}
