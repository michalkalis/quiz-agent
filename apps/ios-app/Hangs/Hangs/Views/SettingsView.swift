//
//  SettingsView.swift
//  Hangs
//
//  Hangs redesign settings — grouped rows with monospace keys + pink values.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 20) {
                    quizSettingsGroup
                    audioSettingsGroup
                    historyGroup

                    if viewModel.questionHistoryCount > 0 {
                        Text("\(viewModel.questionHistoryCount) / 500 questions seen")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(questionCountColor)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("BACK")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .tracking(1.5)
                }
                .foregroundColor(Theme.Hangs.Colors.accent)
                .frame(height: 40)
            }
            .accessibilityIdentifier("settings.back")

            Text("// CONFIGURATION")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.infoAccent)
                .tracking(1.5)

            Text("SETTINGS")
                .font(.system(size: 52, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.textPrimary)

            Rectangle()
                .fill(Theme.Hangs.Colors.accent.opacity(0.4))
                .frame(height: 1)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Quiz settings group

    private var quizSettingsGroup: some View {
        settingsGroup(title: "QUIZ_SETTINGS") {
            settingsRow(
                icon: "globe",
                label: "Language",
                value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown"
            ) {
                Menu {
                    ForEach(Language.supportedLanguages) { language in
                        Button(language.nativeName) { viewModel.settings.language = language.id }
                    }
                } label: { EmptyView() }
            }

            settingsRow(
                icon: "number",
                label: "Question Count",
                value: "\(viewModel.settings.numberOfQuestions) QUESTIONS"
            ) {
                Menu {
                    ForEach(Config.questionCountOptions, id: \.self) { count in
                        Button("\(count) Questions") { viewModel.settings.numberOfQuestions = count }
                    }
                } label: { EmptyView() }
            }

            settingsRow(
                icon: "bolt",
                label: "Difficulty",
                value: viewModel.settings.difficultyDisplayName().uppercased()
            ) {
                Menu {
                    ForEach(Config.difficultyOptions, id: \.0) { id, display in
                        Button(display) { viewModel.settings.difficulty = id }
                    }
                } label: { EmptyView() }
            }
        }
    }

    // MARK: - Audio settings group

    private var audioSettingsGroup: some View {
        settingsGroup(title: "AUDIO_SETTINGS") {
            settingsRow(
                icon: "mic",
                label: "Voice Mode",
                value: viewModel.settings.autoRecordEnabled ? "AUTO" : "MANUAL",
                tappable: viewModel.voiceCommandsAvailable
            ) {
                if viewModel.voiceCommandsAvailable {
                    Toggle("", isOn: $viewModel.settings.autoRecordEnabled)
                        .labelsHidden()
                        .tint(Theme.Hangs.Colors.accent)
                        .accessibilityIdentifier("settings.autoRecord")
                } else {
                    EmptyView()
                }
            }

            settingsRow(
                icon: "headphones",
                label: "Microphone",
                value: viewModel.currentInputDeviceName.uppercased()
            ) {
                Button { viewModel.showingMicrophonePicker = true } label: { EmptyView() }
            }

            settingsRow(
                icon: "checkmark.circle",
                label: "Auto-Confirm",
                value: viewModel.settings.autoConfirmEnabled ? "ON" : "OFF",
                tappable: false
            ) {
                Toggle("", isOn: $viewModel.settings.autoConfirmEnabled)
                    .labelsHidden()
                    .tint(Theme.Hangs.Colors.accent)
                    .accessibilityIdentifier("settings.autoConfirm")
            }

            settingsRow(
                icon: "timer",
                label: "Auto-advance",
                value: "\(viewModel.settings.autoAdvanceDelay)s"
            ) {
                Menu {
                    ForEach(Config.autoAdvanceDelayOptions, id: \.self) { seconds in
                        Button("\(seconds) seconds") { viewModel.settings.autoAdvanceDelay = seconds }
                    }
                } label: { EmptyView() }
            }

            settingsRow(
                icon: "hourglass",
                label: "Answer Time Limit",
                value: viewModel.settings.answerTimeLimit == 0 ? "OFF" : "\(viewModel.settings.answerTimeLimit)s"
            ) {
                Menu {
                    ForEach(Config.answerTimeLimitOptions, id: \.self) { seconds in
                        Button(seconds == 0 ? "Off" : "\(seconds) seconds") {
                            viewModel.settings.answerTimeLimit = seconds
                        }
                    }
                } label: { EmptyView() }
            }

            settingsRow(
                icon: "brain.head.profile",
                label: "Thinking Time",
                value: viewModel.settings.thinkingTime == 0 ? "OFF" : "\(viewModel.settings.thinkingTime)s"
            ) {
                Menu {
                    ForEach(Config.thinkingTimeOptions, id: \.self) { seconds in
                        Button(seconds == 0 ? "Off" : "\(seconds) seconds") {
                            viewModel.settings.thinkingTime = seconds
                        }
                    }
                } label: { EmptyView() }
            }
        }
    }

    // MARK: - History group

    private var historyGroup: some View {
        settingsGroup(title: "HISTORY") {
            settingsRow(
                icon: "chart.line.uptrend.xyaxis",
                label: "Questions Seen",
                value: "\(viewModel.questionHistoryCount) / 500",
                tappable: false
            ) {
                EmptyView()
            }

            Button {
                showResetConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.error)
                        .frame(width: 16)
                    Text("Clear History")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.Hangs.Colors.error)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Hangs.Colors.textTertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
            }
            .disabled(viewModel.questionHistoryCount == 0)
            .accessibilityIdentifier("settings.resetHistory")
        }
    }

    // MARK: - Building blocks

    private func settingsGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.infoAccent)
                    .tracking(2)
                Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.Hangs.Colors.bgCard)
            .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
        }
    }

    private func settingsRow<Trailing: View>(
        icon: String,
        label: String,
        value: String,
        tappable: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.accent)
                trailing()
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Hangs.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
        }
    }

    private var questionCountColor: Color {
        let count = viewModel.questionHistoryCount
        if count >= 450 { return Theme.Hangs.Colors.error }
        if count > 400 { return Theme.Hangs.Colors.warning }
        return Theme.Hangs.Colors.textSecondary
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
