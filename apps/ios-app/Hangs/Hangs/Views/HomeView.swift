//
//  HomeView.swift
//  Hangs
//
//  Hangs redesign home screen — cream editorial aesthetic.
//  See docs/design/hangs-redesign-spec.md section "1. Home".
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                NavigationLink {
                    SettingsView(viewModel: viewModel)
                } label: {
                    navChipVisual(icon: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("home.moreSettings")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HangsHeroBlock(
                        title: "HANGS",
                        subtitle: "voice-based trivia for the road"
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                    statsRow

                    HangsSectionLabel(text: "session", color: Theme.Hangs.Colors.pink)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    configCard
                        .padding(.horizontal, 20)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            HangsPrimaryButton(
                title: "Start Quiz",
                icon: "play.fill",
                isLoading: viewModel.quizState == .startingQuiz
            ) {
                Task { await viewModel.startNewQuiz() }
            }
            .accessibilityIdentifier("home.startQuiz")
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .onAppear {
            viewModel.refreshAudioDevices()
            Task { await viewModel.refreshUsage() }
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            HangsStatBox(
                label: "streak",
                value: "\(viewModel.quizStats.currentStreak)",
                labelColor: Theme.Hangs.Colors.pink,
                valueColor: Theme.Hangs.Colors.blue
            )
            HangsStatBox(
                label: "best",
                value: "\(viewModel.quizStats.bestStreak)",
                labelColor: Theme.Hangs.Colors.blue,
                valueColor: Theme.Hangs.Colors.pink
            )
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Config card

    private var configCard: some View {
        HangsCard {
            VStack(spacing: 0) {
                languageRow
                HangsDivider()
                difficultyRow
                HangsDivider()
                categoriesRow
            }
        }
    }

    private var languageRow: some View {
        Menu {
            ForEach(Language.supportedLanguages) { language in
                Button(language.nativeName) {
                    viewModel.settings.language = language.id
                }
            }
        } label: {
            configRowVisual(
                label: "Language",
                value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown",
                valueColor: Theme.Hangs.Colors.blue
            )
        }
    }

    private var difficultyRow: some View {
        Menu {
            ForEach(Config.difficultyOptions, id: \.0) { id, display in
                Button(display) {
                    viewModel.settings.difficulty = id
                }
            }
        } label: {
            configRowVisual(
                label: "Difficulty",
                value: viewModel.settings.difficultyDisplayName(),
                valueColor: Theme.Hangs.Colors.pink
            )
        }
    }

    private var categoriesRow: some View {
        Menu {
            ForEach(Config.categoryOptions, id: \.id) { option in
                Button(option.display) {
                    viewModel.settings.category = option.id
                }
            }
        } label: {
            configRowVisual(
                label: "Categories",
                value: viewModel.settings.categoryDisplayName(),
                valueColor: Theme.Hangs.Colors.blue
            )
        }
    }

    // MARK: - Row visual (replicates HangsConfigRow body w/o inner Button)

    private func configRowVisual(label: String, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label)
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(.hangsBody(17, weight: .semibold))
                    .foregroundColor(valueColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(valueColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    // MARK: - Nav chip visual (used inside NavigationLink label)

    private func navChipVisual(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.navSquare)
                    .fill(Color.white)
            )
            .hangsShadow(Theme.Hangs.Shadow.navChip)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView(viewModel: QuizViewModel.preview)
    }
}
#endif
