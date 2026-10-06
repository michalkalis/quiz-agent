//
//  ComponentSamples+Controls.swift
//  HangsTests
//
//  #188 track C: buttons, rows, cards and answer options — see ComponentSnapshotTests.
//

@testable import Hangs
import SwiftUI

nonisolated extension ComponentSample {
    static var controls: [ComponentSample] { buttons + rows + answers }

    private static var buttons: [ComponentSample] {
        [
            ComponentSample("primaryButton.default") { HangsPrimaryButton(title: "Start quiz", icon: "play.fill") {} },
            ComponentSample("primaryButton.disabled") { HangsPrimaryButton(title: "Start quiz", icon: "play.fill") {}.disabled(true) },
            ComponentSample("primaryButton.disabledTrailingIcon") {
                HangsPrimaryButton(title: "Continue", trailingIcon: "arrow.right") {}.disabled(true)
            },
            ComponentSample("primaryButton.loading") { HangsPrimaryButton(title: "Start quiz", isLoading: true, showsSpinner: true) {} },
            ComponentSample("primaryButton.countdown") {
                HangsPrimaryButton(title: "Next question", countdownSecondsRemaining: 3, countdownTotal: 5) {}
            },
            ComponentSample("primaryButton.longText") { HangsPrimaryButton(title: LocalizedStringKey(longSlovak)) {} },
            ComponentSample("secondaryButton.default") { HangsSecondaryButton(title: "Settings", icon: "gearshape") {} },
            ComponentSample("secondaryButton.disabled") { HangsSecondaryButton(title: "Settings", icon: "gearshape") {}.disabled(true) },
            ComponentSample("secondaryButton.longText") { HangsSecondaryButton(title: LocalizedStringKey(longSlovak)) {} },
            ComponentSample("ghostButton.default") { HangsGhostButton(title: "Restore purchases") {} },
            ComponentSample("skipButton.default") { QuestionSkipButton(isSkipping: false, isDisabled: false) {} },
            ComponentSample("skipButton.skipping") { QuestionSkipButton(isSkipping: true, isDisabled: false) {} },
            ComponentSample("skipButton.disabled") { QuestionSkipButton(isSkipping: false, isDisabled: true) {} },
            ComponentSample("navChip.default") { HangsNavChip(icon: "xmark") {} },
            ComponentSample("sourceLink.default") { HangsSourceLink(domain: "en.wikipedia.org") {} },
        ]
    }

    private static var rows: [ComponentSample] {
        [
            ComponentSample("heroBlock.default") { HangsHeroBlock(title: "Ready to play?", subtitle: "10 questions · General knowledge") },
            ComponentSample("sectionLabel.default") { HangsSectionLabel(text: "Your plan") },
            ComponentSample("card.default") {
                HangsCard(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
                    Text("Card content").font(.hangsBody).foregroundStyle(Theme.Hangs.Colors.ink)
                }
            },
            ComponentSample("configRow.default") { HangsConfigRow(label: "Language", value: "Slovenčina") {} },
            ComponentSample("configRow.subtitleNoChevron") {
                HangsConfigRow(label: "Questions", value: "10", subtitle: "Per quiz", showsChevron: false)
            },
            ComponentSample("configRow.longText") { HangsConfigRow(label: LocalizedStringKey(longSlovak), value: "Zapnuté") {} },
            ComponentSample("toggleRow.on") { HangsToggleRow(label: "Read questions aloud", isOn: .constant(true)) },
            ComponentSample("toggleRow.off") {
                HangsToggleRow(label: "Read questions aloud", subtitle: "Uses the car speakers", isOn: .constant(false))
            },
            ComponentSample("toggleRow.disabled") { HangsToggleRow(label: "Read questions aloud", isOn: .constant(true)).disabled(true) },
            ComponentSample("valueRow.default") { HangsValueRow(label: "Build", value: "1.4 (62)") },
            ComponentSample("divider.default") { HangsDivider() },
        ]
    }

    private static var answers: [ComponentSample] {
        [
            ComponentSample("answerOption.default") { AnswerOption(key: "a", value: "Paris", label: "1") },
            ComponentSample("answerOption.selected") { AnswerOption(key: "a", value: "Paris", label: "1", state: .selected) },
            ComponentSample("answerOption.correct") { AnswerOption(key: "a", value: "Paris", label: "1", state: .correct) },
            ComponentSample("answerOption.incorrect") { AnswerOption(key: "b", value: "Lyon", label: "2", state: .incorrect) },
            ComponentSample("answerOption.loading") { AnswerOption(key: "a", value: "Paris", label: "1", state: .selected, isLoading: true) },
            ComponentSample("answerOption.longText") { AnswerOption(key: "a", value: longSlovak, label: "1") },
            ComponentSample("answerTile.default") { AnswerTile(key: "a", value: "1969", label: "A") },
            ComponentSample("answerTile.correct") { AnswerTile(key: "a", value: "1969", label: "A", state: .correct) },
            ComponentSample("answerTile.compact") { AnswerTile(key: "a", value: "1969", label: "A", compact: true) },
            ComponentSample("mcqPicker.fourOptions") {
                MCQOptionPicker(
                    options: [(key: "a", value: "Paris"), (key: "b", value: "Lyon"), (key: "c", value: "Marseille"), (key: "d", value: "Nice")],
                    onSelect: { _, _ in }
                )
            },
            ComponentSample("mcqPicker.trueFalse") {
                MCQOptionPicker(options: [(key: "a", value: "True"), (key: "b", value: "False")], onSelect: { _, _ in })
            },
            ComponentSample("mcqPicker.submitting") {
                MCQOptionPicker(
                    options: [(key: "a", value: "Paris"), (key: "b", value: "Lyon"), (key: "c", value: "Marseille"), (key: "d", value: "Nice")],
                    onSelect: { _, _ in },
                    externalSelectedKey: .constant("a"),
                    isSubmitting: true
                )
            },
        ]
    }
}
