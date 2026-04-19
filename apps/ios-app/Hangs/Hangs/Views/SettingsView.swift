//
//  SettingsView.swift
//  Hangs
//
//  Hangs redesign settings — cream background, grouped white cards,
//  pink/blue mono section labels. Matches Pencil NEW_Screen/Settings.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HangsBrandRow {
                    HangsNavChip(icon: "arrow.left") { dismiss() }
                }

                HangsHeroBlock(
                    title: "SETTINGS",
                    subtitle: "tune your experience",
                    titleFont: .hangsDisplayMD
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)

                VStack(spacing: 20) {
                    voiceGroup
                    languageGroup
                    audioFeedbackGroup
                    moreGroup
                    aboutGroup
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .alert("Reset Question History?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { viewModel.resetQuestionHistory() }
        } message: {
            Text("This will allow you to see all questions again. This action cannot be undone.")
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Groups

    private var voiceGroup: some View {
        groupSection(label: "voice", color: Theme.Hangs.Colors.pink) {
            HangsToggleRow(
                label: "Voice commands",
                isOn: $viewModel.settings.autoRecordEnabled
            )
            .accessibilityIdentifier("settings.autoRecord")

            hairline

            HangsConfigRow(
                label: "Wake word",
                value: "hey hangs",
                valueColor: Theme.Hangs.Colors.blue,
                action: {}
            )

            hairline

            HangsToggleRow(
                label: "Auto-confirm answers",
                isOn: $viewModel.settings.autoConfirmEnabled
            )
            .accessibilityIdentifier("settings.autoConfirm")
        }
    }

    private var languageGroup: some View {
        groupSection(label: "language", color: Theme.Hangs.Colors.blue) {
            Menu {
                ForEach(Language.supportedLanguages) { language in
                    Button(language.nativeName) { viewModel.settings.language = language.id }
                }
            } label: {
                HangsConfigRow(
                    label: "Current language",
                    value: Language.forCode(viewModel.settings.language)?.nativeName ?? "English",
                    valueColor: Theme.Hangs.Colors.pink,
                    action: {}
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var audioFeedbackGroup: some View {
        groupSection(label: "audio feedback", color: Theme.Hangs.Colors.pink) {
            HangsToggleRow(
                label: "Speak scores aloud",
                isOn: Binding(
                    get: { !viewModel.settings.isMuted },
                    set: { viewModel.settings.isMuted = !$0 }
                )
            )
        }
    }

    private var moreGroup: some View {
        groupSection(label: "more", color: Theme.Hangs.Colors.blue) {
            questionCountRow
            hairline
            difficultyRow
            hairline
            microphoneRow
            hairline
            autoAdvanceRow
            hairline
            answerTimeLimitRow
            hairline
            thinkingTimeRow
            hairline
            clearHistoryRow
        }
    }

    private var aboutGroup: some View {
        groupSection(label: "about", color: Theme.Hangs.Colors.pink) {
            HangsValueRow(label: "Version", value: appVersion)
        }
    }

    // MARK: - Rows (extra settings kept from the previous screen)

    private var questionCountRow: some View {
        Menu {
            ForEach(Config.questionCountOptions, id: \.self) { count in
                Button("\(count) Questions") { viewModel.settings.numberOfQuestions = count }
            }
        } label: {
            HangsConfigRow(
                label: "Question count",
                value: "\(viewModel.settings.numberOfQuestions)",
                valueColor: Theme.Hangs.Colors.pink,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    private var difficultyRow: some View {
        Menu {
            ForEach(Config.difficultyOptions, id: \.0) { id, display in
                Button(display) { viewModel.settings.difficulty = id }
            }
        } label: {
            HangsConfigRow(
                label: "Difficulty",
                value: viewModel.settings.difficultyDisplayName(),
                valueColor: Theme.Hangs.Colors.pink,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    private var microphoneRow: some View {
        HangsConfigRow(
            label: "Microphone",
            value: viewModel.currentInputDeviceName,
            valueColor: Theme.Hangs.Colors.blue
        ) {
            viewModel.showingMicrophonePicker = true
        }
    }

    private var autoAdvanceRow: some View {
        Menu {
            ForEach(Config.autoAdvanceDelayOptions, id: \.self) { seconds in
                Button("\(seconds) seconds") { viewModel.settings.autoAdvanceDelay = seconds }
            }
        } label: {
            HangsConfigRow(
                label: "Auto-advance",
                value: "\(viewModel.settings.autoAdvanceDelay)s",
                valueColor: Theme.Hangs.Colors.pink,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    private var answerTimeLimitRow: some View {
        Menu {
            ForEach(Config.answerTimeLimitOptions, id: \.self) { seconds in
                Button(seconds == 0 ? "Off" : "\(seconds) seconds") {
                    viewModel.settings.answerTimeLimit = seconds
                }
            }
        } label: {
            HangsConfigRow(
                label: "Answer time limit",
                value: viewModel.settings.answerTimeLimit == 0 ? "Off" : "\(viewModel.settings.answerTimeLimit)s",
                valueColor: Theme.Hangs.Colors.pink,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    private var thinkingTimeRow: some View {
        Menu {
            ForEach(Config.thinkingTimeOptions, id: \.self) { seconds in
                Button(seconds == 0 ? "Off" : "\(seconds) seconds") {
                    viewModel.settings.thinkingTime = seconds
                }
            }
        } label: {
            HangsConfigRow(
                label: "Thinking time",
                value: viewModel.settings.thinkingTime == 0 ? "Off" : "\(viewModel.settings.thinkingTime)s",
                valueColor: Theme.Hangs.Colors.pink,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    private var clearHistoryRow: some View {
        HangsConfigRow(
            label: "Clear question history",
            value: "\(viewModel.questionHistoryCount) / 500",
            valueColor: Theme.Hangs.Colors.pink
        ) {
            if viewModel.questionHistoryCount > 0 {
                showResetConfirmation = true
            }
        }
        .accessibilityIdentifier("settings.resetHistory")
    }

    // MARK: - Building blocks

    private func groupSection<Content: View>(
        label: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let inner = content()
        return VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: label, color: color)
                .padding(.leading, 4)
            HangsCard {
                VStack(spacing: 0) {
                    inner
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.Hangs.Colors.hairline)
            .frame(height: 1)
            .padding(.leading, 18)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView(viewModel: .preview)
        }
    }
}
#endif
