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

                    Text("CarQuiz")
                        .font(.system(size: Theme.Typography.sizeXXL, weight: .bold, design: .default))
                        .foregroundColor(Theme.Colors.textPrimary)

                    Text("Hands-Free Trivia While You Drive")
                        .font(.system(size: Theme.Typography.sizeSM))
                        .foregroundColor(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Theme.Spacing.lg)

                // MARK: - Quick Settings Section

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Quick Settings")
                        .font(.system(size: Theme.Typography.sizeMD, weight: .semibold))
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
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)

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

                    NavigationLink {
                        SettingsView(viewModel: viewModel)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: Theme.Components.iconSM))
                            Text("More Settings")
                        }
                    }
                    .buttonStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .background(Theme.Colors.bgPrimary)
        .onAppear {
            viewModel.refreshAudioDevices()
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Helper Views

    private func settingsMenuLabel(value: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(value)
                .foregroundColor(Theme.Colors.textPrimary)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundColor(Theme.Colors.textSecondary)
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
                    .font(.system(size: Theme.Typography.sizeXS, weight: .semibold))
                    .foregroundColor(Theme.Colors.textSecondary)

                Text(value)
                    .font(.system(size: Theme.Typography.sizeSM))
                    .foregroundColor(Theme.Colors.textPrimary)
            }

            Spacer()

            content()
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.xl)
    }
}

#Preview {
    NavigationStack {
        HomeView(viewModel: QuizViewModel.preview)
    }
}
