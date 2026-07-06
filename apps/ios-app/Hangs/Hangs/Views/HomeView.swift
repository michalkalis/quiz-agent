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
    var onReplayOnboarding: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                NavigationLink {
                    SettingsView(viewModel: viewModel, onReplayOnboarding: onReplayOnboarding)
                } label: {
                    navChipVisual(icon: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Settings", comment: "Accessibility label for the settings navigation button"))
                .accessibilityIdentifier("home.moreSettings")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("voice-based trivia for the road")
                        .font(.hangsBody(14))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

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
            // #77: arm the on-device English command listener on Home (idle) so
            // spoken "start" begins the quiz. Founder-overridable (default ON);
            // nothing leaves the device.
            if viewModel.voiceStartOnHomeEnabled {
                viewModel.refreshCommandWindow()
            }
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
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
                HangsDivider()
                imageQuestionsRow
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
        .accessibilityIdentifier("home-language-menu")
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
                valueColor: Theme.Hangs.Colors.blue
            )
        }
        .accessibilityIdentifier("home-difficulty-menu")
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
        .accessibilityIdentifier("home-categories-menu")
    }

    // #68: image questions are fun but unsuitable while driving — user-selectable
    // per session on Home, default OFF (founder decision 6, 2026-07-05).
    private var imageQuestionsRow: some View {
        HangsToggleRow(
            label: "Image questions",
            isOn: $viewModel.settings.includeImageQuestions
        )
        .accessibilityIdentifier("home-image-questions-toggle")
    }

    // MARK: - Row visual (replicates HangsConfigRow body w/o inner Button)

    private func configRowVisual(label: LocalizedStringKey, value: String, valueColor: Color) -> some View {
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
                    .fill(Theme.Hangs.Colors.bgCard)
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
