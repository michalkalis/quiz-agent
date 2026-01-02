//
//  HomeView.swift
//  CarQuiz
//
//  Welcome screen and quiz start
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Icon/Logo
            Image(systemName: "car.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            // Title
            VStack(spacing: 8) {
                Text("CarQuiz")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Hands-Free Trivia While You Drive")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Start Button
            Button(action: {
                Task {
                    await viewModel.startNewQuiz()
                }
            }) {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)

                    Text("Start Quiz")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
            .padding(.horizontal, 40)
            .disabled(viewModel.isLoading)

            // Quiz Settings Panel
            VStack(alignment: .leading, spacing: 12) {
                Text("Quiz Settings")
                    .font(.headline)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 8)

                VStack(spacing: 8) {
                    // Language Picker
                    settingsRow(
                        icon: "globe",
                        title: "Language",
                        value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown"
                    ) {
                        Menu {
                            ForEach(Language.supportedLanguages) { language in
                                Button(language.nativeName) {
                                    viewModel.settings.language = language.id
                                    viewModel.saveSettings()
                                }
                            }
                        } label: {
                            settingsMenuLabel(value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Select")
                        }
                    }

                    // Number of Questions Picker
                    settingsRow(
                        icon: "number",
                        title: "Questions",
                        value: "\(viewModel.settings.numberOfQuestions)"
                    ) {
                        Menu {
                            ForEach(Config.questionCountOptions, id: \.self) { count in
                                Button("\(count) Questions") {
                                    viewModel.settings.numberOfQuestions = count
                                    viewModel.saveSettings()
                                }
                            }
                        } label: {
                            settingsMenuLabel(value: "\(viewModel.settings.numberOfQuestions)")
                        }
                    }

                    // Difficulty Picker
                    settingsRow(
                        icon: "chart.bar",
                        title: "Difficulty",
                        value: viewModel.settings.difficultyDisplayName()
                    ) {
                        Menu {
                            ForEach(Config.difficultyOptions, id: \.0) { (id, display) in
                                Button(display) {
                                    viewModel.settings.difficulty = id
                                    viewModel.saveSettings()
                                }
                            }
                        } label: {
                            settingsMenuLabel(value: viewModel.settings.difficultyDisplayName())
                        }
                    }

                    // Category Picker
                    settingsRow(
                        icon: "tag",
                        title: "Category",
                        value: viewModel.settings.categoryDisplayName()
                    ) {
                        Menu {
                            ForEach(Config.categoryOptions, id: \.id) { option in
                                Button(option.display) {
                                    viewModel.settings.category = option.id
                                    viewModel.saveSettings()
                                }
                            }
                        } label: {
                            settingsMenuLabel(value: viewModel.settings.categoryDisplayName())
                        }
                    }

                    // Audio Mode Toggle
                    settingsRow(
                        icon: viewModel.selectedAudioMode.icon,
                        title: "Audio Mode",
                        value: viewModel.selectedAudioMode.name
                    ) {
                        Button(action: {
                            viewModel.toggleAudioMode()
                        }) {
                            HStack {
                                Text(viewModel.selectedAudioMode.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Auto-advance Timer Picker
                    settingsRow(
                        icon: "timer",
                        title: "Auto-advance",
                        value: "\(viewModel.settings.autoAdvanceDelay)s"
                    ) {
                        Menu {
                            ForEach(Config.autoAdvanceDelayOptions, id: \.self) { seconds in
                                Button("\(seconds) seconds") {
                                    viewModel.settings.autoAdvanceDelay = seconds
                                    viewModel.saveSettings()
                                }
                            }
                        } label: {
                            settingsMenuLabel(value: "\(viewModel.settings.autoAdvanceDelay)s")
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            // Loading indicator
            if viewModel.isLoading {
                ProgressView()
                    .padding()
            }

            Spacer()
        }
        .padding()
        .toolbar {
            // Only show Settings link (Question History management)
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView(viewModel: viewModel)
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .onAppear {
            viewModel.loadSavedLanguage()
            viewModel.loadSavedAudioMode()
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func settingsRow<Content: View>(
        icon: String,
        title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.blue)
                .frame(width: 24)

            Text(title)
                .font(.body)
                .foregroundColor(.primary)

            Spacer()

            content()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private func settingsMenuLabel(value: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .foregroundColor(.primary)
            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    HomeView(viewModel: QuizViewModel.preview)
}
