//
//  HomeView.swift
//  Hangs
//
//  Hangs redesign home screen — terminal/cyberpunk aesthetic, dark-only.
//  See docs/issues/issue-14-hangs-redesign.md
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 0) {
            HangsStatusBar(leading: "// HANGS.SYS", trailing: "v2.1.0 • READY")
            HangsDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroSection
                    statsSection
                    quickConfigSection
                    actionButtons
                }
                .padding(.vertical, 18)
            }

            HangsFooterBar(leading: "◢ REG.MARK.01", trailing: "PWR ON • V2.1")
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.refreshAudioDevices()
            Task { await viewModel.refreshUsage() }
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HangsTerminalLabel(text: "[ 001 ]   MODE: DRIVE", color: Theme.Hangs.Colors.textSecondary)

            HangsHeroBlock(text: "HANGS", alignment: .leading)

            Text("Hands-free trivia while you drive — voice-first AI companion.")
                .font(.hangsBody)
                .foregroundColor(Theme.Hangs.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 10) {
            metricTile(
                label: "DAY STREAK",
                value: "\(viewModel.quizStats.currentStreak)",
                valueColor: Theme.Hangs.Colors.textPrimary,
                borderColor: Theme.Hangs.Colors.divider,
                subtext: viewModel.quizStats.currentStreak > 0 ? "→ ACTIVE" : nil
            )
            metricTile(
                label: "BEST SCORE",
                value: "\(viewModel.quizStats.bestStreak)",
                valueColor: Theme.Hangs.Colors.infoAccent,
                borderColor: Theme.Hangs.Colors.infoAccent,
                subtext: "◢ PERSONAL BEST"
            )
        }
        .padding(.horizontal, 24)
    }

    private func metricTile(label: String, value: String, valueColor: Color, borderColor: Color, subtext: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.hangsMonoLabel)
                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                .tracking(1.5)
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
            if let subtext = subtext {
                Text(subtext)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.accent)
                    .tracking(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.Hangs.Colors.bgCard)
        .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
    }

    // MARK: - Quick Config

    private var quickConfigSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("// QUICK_CONFIG")
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
                    .tracking(2)
                Rectangle().fill(Theme.Hangs.Colors.divider).frame(height: 1)
                Text("03")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Hangs.Colors.infoAccent)
            }

            configRow(
                key: "LANG",
                value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown",
                menuContent: {
                    ForEach(Language.supportedLanguages) { language in
                        Button(language.nativeName) {
                            viewModel.settings.language = language.id
                        }
                    }
                }
            )

            configRow(
                key: "DIFF",
                value: viewModel.settings.difficultyDisplayName(),
                menuContent: {
                    ForEach(Config.difficultyOptions, id: \.0) { id, display in
                        Button(display) {
                            viewModel.settings.difficulty = id
                        }
                    }
                }
            )

            configRow(
                key: "CATS",
                value: viewModel.settings.categoryDisplayName(),
                menuContent: {
                    ForEach(Config.categoryOptions, id: \.id) { option in
                        Button(option.display) {
                            viewModel.settings.category = option.id
                        }
                    }
                }
            )
        }
        .padding(.horizontal, 24)
    }

    private func configRow<Content: View>(
        key: String,
        value: String,
        @ViewBuilder menuContent: () -> Content
    ) -> some View {
        Menu {
            menuContent()
        } label: {
            HStack(spacing: 12) {
                Text(key)
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.textTertiary)
                    .tracking(1.5)
                Rectangle().fill(Theme.Hangs.Colors.borderDim).frame(height: 1)
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.textPrimary)
                Text("›")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.Hangs.Colors.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.Hangs.Colors.bgCard)
            .overlay(Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1))
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HangsPrimaryButton(
                title: "START QUIZ",
                icon: "play.fill",
                trailingIcon: "arrow.up.right",
                isLoading: viewModel.quizState == .startingQuiz
            ) {
                Task { await viewModel.startNewQuiz() }
            }
            .accessibilityIdentifier("home.startQuiz")

            NavigationLink {
                SettingsView(viewModel: viewModel)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("SETTINGS")
                        .font(.hangsButton)
                        .tracking(2.5)
                }
                .foregroundColor(Theme.Hangs.Colors.infoAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1.5))
            }
            .accessibilityIdentifier("home.moreSettings")
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView(viewModel: QuizViewModel.preview)
    }
}
#endif
