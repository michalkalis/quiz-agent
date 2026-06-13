//
//  SettingsView.swift
//  Hangs
//
//  Hangs redesign settings — bg-page background, grouped white cards,
//  pink/blue mono section labels. Matches Pencil NEW_Screen/Settings (Jjcs5).
//  #52 task 52.9.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Replay intro". Caller is responsible for
    /// presenting the onboarding flow; this view only fires the callback.
    /// Wired to `OnboardingViewModel.startOnboarding()` — must not clear
    /// `hasCompletedOnboarding` (52.5 founder decision, tested in 52.9 suite).
    var onReplayOnboarding: (() -> Void)? = nil

    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HangsBrandRow {
                    HangsNavChip(icon: "arrow.left") { dismiss() }
                        .accessibilityIdentifier("settings-back-button")
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
                    aboutGroup
                    #if DEBUG
                        developerGroup
                    #endif
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
                label: "Auto-record answers",
                isOn: $viewModel.settings.autoRecordEnabled
            )
            .accessibilityIdentifier("settings.autoRecord")

            hairline

            HangsToggleRow(
                label: "Auto-confirm answers",
                isOn: $viewModel.settings.autoConfirmEnabled
            )
            .accessibilityIdentifier("settings.autoConfirm")

            hairline

            HangsConfigRow(
                label: "Microphone",
                value: viewModel.currentInputDeviceName,
                valueColor: Theme.Hangs.Colors.blue
            ) {
                viewModel.showingMicrophonePicker = true
            }
            .accessibilityIdentifier("settings-microphone-row")
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
            .accessibilityIdentifier("settings-language-menu")
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
            .accessibilityIdentifier("settings-speak-scores-toggle")
        }
    }

    private var aboutGroup: some View {
        groupSection(label: "about", color: Theme.Hangs.Colors.blue) {
            HangsValueRow(label: "Version", value: appVersion)

            hairline

            HangsConfigRow(
                label: "Replay intro",
                value: "",
                valueColor: Theme.Hangs.Colors.muted,
                showsChevron: true
            ) {
                onReplayOnboarding?()
            }
            .accessibilityIdentifier("settings.replayOnboarding")

            hairline

            // Recovery path for the 500-question history cap: the at-capacity
            // error directs users here (#54 task 54.17 — row was dropped in 52.9).
            HangsConfigRow(
                label: "Reset question history",
                value: "\(viewModel.questionHistoryCount) / 500",
                valueColor: Theme.Hangs.Colors.pink
            ) {
                if viewModel.questionHistoryCount > 0 {
                    showResetConfirmation = true
                }
            }
            .accessibilityIdentifier("settings.resetHistory")
        }
    }

    #if DEBUG
        private var developerGroup: some View {
            groupSection(label: "developer", color: Theme.Hangs.Colors.blue) {
                NavigationLink {
                    DebugLogView()
                } label: {
                    HangsConfigRow(
                        label: "View Logs",
                        value: "OSLogStore",
                        valueColor: Theme.Hangs.Colors.muted,
                        action: {}
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    #endif

    // MARK: - Building blocks

    private func groupSection<Content: View>(
        label: LocalizedStringKey,
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
