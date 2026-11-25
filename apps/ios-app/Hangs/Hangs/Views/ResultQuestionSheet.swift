//
//  ResultQuestionSheet.swift
//  Hangs
//
//  TF build 90 (founder pick C1, docs/artifacts/tf90-layouts.html): the result
//  card no longer prints the question. "Show question" opens it here, in a
//  native sheet, on its category card as the question screen drew it; a
//  multiple-choice question also shows its options with the correct one and
//  the player's pick marked. The result holds its auto-advance while this is
//  open (`QuizViewModel.openResultQuestion()`).
//

import SwiftUI

struct ResultQuestionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let question: Question
    let identity: DeckIdentity
    /// The canonical correct answer, as the result card shows it.
    let correctAnswer: String
    /// MCQ only: the options to mark (nil = an open question).
    var reveal: MCQOptionPicker.Reveal? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                    questionCard
                        .padding(.horizontal, Theme.Hangs.Spacing.md)
                    if let reveal {
                        MCQOptionPicker(
                            options: question.sortedAnswerOptions,
                            labels: question.optionLabels,
                            onSelect: { _, _ in },
                            reveal: reveal
                        )
                    } else {
                        correctAnswerBlock
                            .padding(.horizontal, Theme.Hangs.Spacing.md)
                    }
                }
                .padding(.vertical, Theme.Hangs.Spacing.xs)
            }
            .navigationTitle(Text("Question", comment: "Title of the sheet that shows the full question from the result screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("resultQuestion.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("resultQuestion.sheet")
    }

    /// The question on its card, read-only: no replay glyph, nothing to tap.
    private var questionCard: some View {
        HangsDeckCard(style: identity.style, categoryName: identity.chipName) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                if question.hasImage {
                    ImageQuestionView(question: question)
                }
                Text(question.question)
                    .font(.hangsTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("resultQuestion.text")
            }
        }
    }

    private var correctAnswerBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            HangsSectionLabel(text: "the answer")
            Text(correctAnswer)
                .font(.hangsHeading)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("resultQuestion.answer")
        }
    }
}
