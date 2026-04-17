//
//  HomeView.swift
//  CarQuiz
//
//  Welcome screen and quiz start matching Pencil design
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // MARK: - Header Section

                VStack(spacing: Theme.Spacing.sm) {
                    AppLogo(size: 80)
                        .accessibilityHidden(true)

                    Text("CarQuiz")
                        .font(.displayXXL)
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text("Hands-Free Trivia While You Drive")
                        .font(.textSM)
                        .foregroundColor(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, Theme.Spacing.lg)

                // MARK: - Quick Settings Section

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Quick Settings")
                        .font(.displayMD)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .padding(.horizontal, 4)

                    VStack(spacing: Theme.Spacing.xs) {
                        // Language
                        QuickSettingRow(
                            icon: "globe",
                            title: "Language",
                            value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown"
                        ) {
                            Menu {
                                ForEach(Language.supportedLanguages) { language in
                                    Button(language.nativeName) {
                                        viewModel.settings.language = language.id
                                    }
                                }
                            } label: {
                                settingsMenuLabel(value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Select")
                            }
                            .accessibilityIdentifier("home.languagePicker")
                        }

                        // Difficulty
                        QuickSettingRow(
                            icon: "chart.bar",
                            title: "Difficulty",
                            value: viewModel.settings.difficultyDisplayName()
                        ) {
                            Menu {
                                ForEach(Config.difficultyOptions, id: \.0) { id, display in
                                    Button(display) {
                                        viewModel.settings.difficulty = id
                                    }
                                }
                            } label: {
                                settingsMenuLabel(value: viewModel.settings.difficultyDisplayName())
                            }
                            .accessibilityIdentifier("home.difficultyPicker")
                        }

                        // Category
                        QuickSettingRow(
                            icon: "tag",
                            title: "Categories",
                            value: viewModel.settings.categoryDisplayName()
                        ) {
                            Menu {
                                ForEach(Config.categoryOptions, id: \.id) { option in
                                    Button(option.display) {
                                        viewModel.settings.category = option.id
                                    }
                                }
                            } label: {
                                settingsMenuLabel(value: viewModel.settings.categoryDisplayName())
                            }
                            .accessibilityIdentifier("home.categoryPicker")
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)

                // MARK: - Usage Badge

                if let usage = viewModel.usageInfo, !usage.isPremium {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: usage.isLimitReached ? "exclamationmark.triangle" : "sparkle")
                            .foregroundColor(usage.isLimitReached ? Theme.Colors.warning : Theme.Colors.accentPrimary)
                            .accessibilityHidden(true)
                        Text(usageText(usage))
                            .font(.textSM)
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.bgCard)
                    .cornerRadius(Theme.Radius.xl)
                    .accessibilityLabel(usageAccessibilityLabel(usage))
                }

                Spacer(minLength: Theme.Spacing.lg)

                // MARK: - Action Buttons

                VStack(spacing: Theme.Spacing.sm) {
                    PrimaryButton(
                        title: "Start Quiz",
                        icon: "play.fill",
                        isLoading: viewModel.quizState == .startingQuiz
                    ) {
                        Task {
                            await viewModel.startNewQuiz()
                        }
                    }
                    .accessibilityIdentifier("home.startQuiz")

                    NavigationLink {
                        SettingsView(viewModel: viewModel)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: Theme.Components.iconSM))
                                .accessibilityHidden(true)
                            Text("More Settings")
                        }
                    }
                    .accessibilityLabel("More Settings")
                    .accessibilityHint("Opens full settings screen")
                    .accessibilityIdentifier("home.moreSettings")
                    .buttonStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .background(Theme.Colors.bgPrimary)
        .onAppear {
            viewModel.refreshAudioDevices()
            Task { await viewModel.refreshUsage() }
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Helper Views

    private func usageText(_ usage: UsageInfo) -> String {
        if usage.isLimitReached {
            return "No free questions left today"
        }
        if let remaining = usage.remaining {
            return "\(remaining) free questions remaining today"
        }
        return ""
    }

    private func usageAccessibilityLabel(_ usage: UsageInfo) -> String {
        if usage.isLimitReached {
            return "No free questions remaining today. Upgrade for unlimited access."
        }
        if let remaining = usage.remaining, let limit = usage.questionsLimit {
            return "\(remaining) of \(limit) free questions remaining today"
        }
        return ""
    }

    private func settingsMenuLabel(value: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(value)
                .foregroundColor(Theme.Colors.textPrimary)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundColor(Theme.Colors.textSecondary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Quick Setting Row

private struct QuickSettingRow<Content: View>: View {
    let icon: String
    let title: String
    let value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Theme.Components.iconMD))
                .foregroundColor(Theme.Colors.accentPrimary)
                .frame(width: Theme.Components.iconMD)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.labelSM)
                    .foregroundColor(Theme.Colors.textSecondary)

                Text(value)
                    .font(.textSM)
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Spacer()

            content()
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView(viewModel: QuizViewModel.preview)
    }
}
#endif
