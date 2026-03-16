//
//  SettingsView.swift
//  CarQuiz
//
//  Full settings screen matching Pencil design
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // MARK: - Quiz Settings Section
                SettingsSection(title: "Quiz Settings") {
                    // Language
                    SettingsInputField(
                        label: "Language",
                        icon: "globe",
                        value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown"
                    ) {
                        Menu {
                            ForEach(Language.supportedLanguages) { language in
                                Button(language.nativeName) {
                                    viewModel.settings.language = language.id
                                }
                            }
                        } label: {
                            menuLabel(value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Select")
                        }
                    }

                    // Question Count
                    SettingsInputField(
                        label: "Questions per Quiz",
                        icon: "number",
                        value: "\(viewModel.settings.numberOfQuestions)"
                    ) {
                        Menu {
                            ForEach(Config.questionCountOptions, id: \.self) { count in
                                Button("\(count) Questions") {
                                    viewModel.settings.numberOfQuestions = count
                                }
                            }
                        } label: {
                            menuLabel(value: "\(viewModel.settings.numberOfQuestions)")
                        }
                    }

                    // Difficulty
                    SettingsInputField(
                        label: "Difficulty",
                        icon: "chart.bar",
                        value: viewModel.settings.difficultyDisplayName()
                    ) {
                        Menu {
                            ForEach(Config.difficultyOptions, id: \.0) { id, display in
                                Button(display) {
                                    viewModel.settings.difficulty = id
                                }
                            }
                        } label: {
                            menuLabel(value: viewModel.settings.difficultyDisplayName())
                        }
                    }
                }

                // MARK: - Audio Settings Section
                SettingsSection(title: "Audio Settings") {
                    // Voice Commands (iOS 26+)
                    if viewModel.voiceCommandsAvailable {
                        SettingsInputField(
                            label: "Voice Commands",
                            icon: "mic.badge.xmark",
                            value: viewModel.settings.voiceCommandsEnabled ? "On" : "Off"
                        ) {
                            Toggle(
                                "",
                                isOn: $viewModel.settings.voiceCommandsEnabled
                            )
                            .labelsHidden()
                            .tint(Theme.Colors.accentPrimary)
                        }

                        // Auto-Record (iOS 26+, requires voice commands)
                        SettingsInputField(
                            label: "Auto-Record",
                            icon: "waveform.badge.mic",
                            value: viewModel.settings.autoRecordEnabled ? "On" : "Off"
                        ) {
                            Toggle(
                                "",
                                isOn: $viewModel.settings.autoRecordEnabled
                            )
                            .labelsHidden()
                            .tint(Theme.Colors.accentPrimary)
                        }

                        // Barge-In (iOS 26+, requires voice commands)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            SettingsInputField(
                                label: "Barge-In",
                                icon: "hand.raised.fill",
                                value: viewModel.settings.bargeInEnabled ? "On" : "Off"
                            ) {
                                Toggle(
                                    "",
                                    isOn: $viewModel.settings.bargeInEnabled
                                )
                                .labelsHidden()
                                .tint(Theme.Colors.accentPrimary)
                            }

                            Text("Interrupt question audio by speaking. Works best with Bluetooth or CarPlay.")
                                .font(.textXS)
                                .foregroundColor(Theme.Colors.textTertiary)
                                .padding(.horizontal, 4)
                        }
                    }

                    // Audio Mode
                    SettingsInputField(
                        label: "Audio Mode",
                        icon: viewModel.selectedAudioMode.icon,
                        value: viewModel.selectedAudioMode.name
                    ) {
                        Button {
                            viewModel.toggleAudioMode()
                        } label: {
                            menuLabel(value: viewModel.selectedAudioMode.name)
                        }
                    }

                    // Microphone
                    SettingsInputField(
                        label: "Microphone",
                        icon: "mic.fill",
                        value: viewModel.currentInputDeviceName
                    ) {
                        Button {
                            viewModel.showingMicrophonePicker = true
                        } label: {
                            Text(viewModel.currentInputDeviceName)
                                .font(.textSM)
                                .foregroundColor(Theme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    // Auto-advance
                    SettingsInputField(
                        label: "Auto-advance Timer",
                        icon: "timer",
                        value: "\(viewModel.settings.autoAdvanceDelay)s"
                    ) {
                        Menu {
                            ForEach(Config.autoAdvanceDelayOptions, id: \.self) { seconds in
                                Button("\(seconds) seconds") {
                                    viewModel.settings.autoAdvanceDelay = seconds
                                }
                            }
                        } label: {
                            menuLabel(value: "\(viewModel.settings.autoAdvanceDelay)s")
                        }
                    }

                    // Answer Time Limit
                    SettingsInputField(
                        label: "Answer Time Limit",
                        icon: "hourglass",
                        value: viewModel.settings.answerTimeLimit == 0
                            ? "Off"
                            : "\(viewModel.settings.answerTimeLimit)s"
                    ) {
                        Menu {
                            ForEach(Config.answerTimeLimitOptions, id: \.self) { seconds in
                                Button(seconds == 0 ? "Off" : "\(seconds) seconds") {
                                    viewModel.settings.answerTimeLimit = seconds
                                }
                            }
                        } label: {
                            menuLabel(
                                value: viewModel.settings.answerTimeLimit == 0
                                    ? "Off"
                                    : "\(viewModel.settings.answerTimeLimit)s"
                            )
                        }
                    }
                }

                // MARK: - Question History Section
                SettingsSection(title: "Question History") {
                    VStack(spacing: Theme.Spacing.md) {
                        ProgressBarView(
                            progress: Double(viewModel.questionHistoryCount) / 500.0,
                            title: "Questions Seen",
                            showPercentage: false
                        )

                        HStack {
                            Text("\(viewModel.questionHistoryCount) / 500 questions")
                                .font(.textXS)
                                .foregroundColor(questionCountColor)
                                .accessibilityLabel("\(viewModel.questionHistoryCount) of 500 questions seen")

                            Spacer()
                        }

                        Button(role: .destructive) {
                            showResetConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                    .accessibilityHidden(true)
                                Text("Reset History")
                            }
                            .font(.textMDMedium)
                            .foregroundColor(Theme.Colors.error)
                            .padding(.vertical, Theme.Spacing.sm)
                            .frame(maxWidth: .infinity)
                            .background(Theme.Colors.errorBg)
                            .cornerRadius(Theme.Radius.md)
                        }
                        .accessibilityLabel("Reset History")
                        .accessibilityHint("Clears all question history so you can see previously answered questions again")
                        .disabled(viewModel.questionHistoryCount == 0)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.bgCard)
                    .cornerRadius(Theme.Radius.xl)
                }

                // Helper text
                Text("Resetting history allows you to see previously answered questions again.")
                    .font(.textXS)
                    .foregroundColor(Theme.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
        .background(Theme.Colors.bgPrimary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset Question History?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetQuestionHistory()
            }
        } message: {
            Text("This will allow you to see all questions again. This action cannot be undone.")
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Helper Views

    private func menuLabel(value: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(value)
                .font(.textSM)
                .foregroundColor(Theme.Colors.textPrimary)
            Image(systemName: "chevron.down")
                .font(.textXS)
                .foregroundColor(Theme.Colors.textSecondary)
                .accessibilityHidden(true)
        }
    }

    private var questionCountColor: Color {
        let count = viewModel.questionHistoryCount
        if count >= 450 {
            return Theme.Colors.error
        } else if count > 400 {
            return Theme.Colors.warning
        } else {
            return Theme.Colors.textSecondary
        }
    }
}

// MARK: - Settings Section

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.displayMD)
                .foregroundColor(Theme.Colors.textPrimary)
                .padding(.horizontal, 4)

            content()
        }
    }
}

// MARK: - Settings Input Field

private struct SettingsInputField<Content: View>: View {
    let label: String
    let icon: String
    let value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(.labelSM)
                .foregroundColor(Theme.Colors.textSecondary)

            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: Theme.Components.iconSM))
                    .foregroundColor(Theme.Colors.textSecondary)

                content()

                Spacer()
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.bgCard)
            .cornerRadius(Theme.Radius.xl)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .stroke(Theme.Colors.border, lineWidth: 1.5)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label): \(value)")
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct SettingsView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                SettingsView(viewModel: .preview)
            }
        }
    }
#endif
