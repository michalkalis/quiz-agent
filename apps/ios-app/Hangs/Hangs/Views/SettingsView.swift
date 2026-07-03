//
//  SettingsView.swift
//  Hangs
//
//  Hangs redesign settings — bg-page background, grouped white cards,
//  pink/blue mono section labels. Matches Pencil NEW_Screen/Settings (Jjcs5).
//  #52 task 52.9.
//  #61 task 61.7: account section (Sign in with Apple / signed-in state / delete account).
//

import AuthenticationServices
import Combine
import SwiftUI
import os

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.dismiss) private var dismiss
    /// AppState is always present in the environment (set in ContentView). SettingsView
    /// uses it to access `authService` for Sign in with Apple, sign-out, and account
    /// actions. Marked `optional` via `@EnvironmentObject` — nil only in raw Xcode previews
    /// that don't inject AppState; the real app and tests via NavigationStack always have it.
    @EnvironmentObject private var appState: AppState

    /// Called when the user taps "Replay intro". Caller is responsible for
    /// presenting the onboarding flow; this view only fires the callback.
    /// Wired to `OnboardingViewModel.startOnboarding()` — must not clear
    /// `hasCompletedOnboarding` (52.5 founder decision, tested in 52.9 suite).
    var onReplayOnboarding: (() -> Void)? = nil

    // MARK: State

    @State private var showResetConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var isSigningIn = false
    @State private var isDeletingAccount = false
    @State private var accountErrorMessage: String? = nil
    /// Ephemeral raw nonce generated at sign-in tap time; held across the
    /// `SignInWithAppleButton` onRequest → onCompletion lifecycle.
    @State private var pendingRawNonce: String = ""

    // Reflects the current Keychain state; refreshed on appear + after auth events.
    @State private var currentTokens: AuthTokens? = nil

    // MARK: Body

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
                    accountGroup
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
        .task {
            // Load auth state from Keychain on appear.
            currentTokens = KeychainTokenStore().load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .authSignedInSessionDropped)) { _ in
            // A signed-in session was dropped out-of-band (refresh 401) — reload so the
            // account section reflects the fresh anon identity (I7).
            currentTokens = KeychainTokenStore().load()
        }
        .alert("Reset Question History?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { viewModel.resetQuestionHistory() }
        } message: {
            Text("This will allow you to see all questions again. This action cannot be undone.")
        }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await performDeleteAccount() }
            }
        } message: {
            Text("This permanently removes your data, history, and premium access. This can't be undone.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { accountErrorMessage != nil },
                set: { if !$0 { accountErrorMessage = nil } }
            ),
            presenting: accountErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { accountErrorMessage = nil }
        } message: { message in
            Text(message)
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

    // MARK: - Account group (#61 task 61.7)
    // Placed after audio-feedback, before about — founder decision 2026-06-29.
    // Design reference: Pencil NEW_Screen/Settings-SignedOut (taml6), Settings-SignedIn (JB9Oi),
    // Settings-DeleteConfirm (PmJ3A).

    @ViewBuilder
    private var accountGroup: some View {
        if let tokens = currentTokens, tokens.isSignedIn {
            signedInAccountGroup(tokens: tokens)
        } else {
            signedOutAccountGroup
        }
    }

    private var signedOutAccountGroup: some View {
        groupSection(label: "account", color: Theme.Hangs.Colors.accentTeal) {
            VStack(spacing: 16) {
                Text("Sign in to keep your premium and history when you reinstall.")
                    .font(.hangsBody(14))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                SignInWithAppleButton(.signIn) { request in
                    let rawNonce = appState.authService.generateRawNonce()
                    pendingRawNonce = rawNonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = appState.authService.hashedNonce(for: rawNonce)
                } onCompletion: { result in
                    handleAppleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .disabled(isSigningIn)
                .accessibilityIdentifier("account.signInWithApple")
            }
        }
    }

    private func signedInAccountGroup(tokens: AuthTokens) -> some View {
        groupSection(label: "account", color: Theme.Hangs.Colors.accentTeal) {
            VStack(spacing: 0) {
                if let name = tokens.accountName {
                    HangsValueRow(label: "Name", value: name)
                        .accessibilityIdentifier("account.name")
                    hairline
                }
                if let email = tokens.accountEmail {
                    HangsValueRow(label: "Email", value: email)
                        .accessibilityIdentifier("account.email")
                    hairline
                }
                HangsConfigRow(
                    label: "Export my data",
                    value: "",
                    valueColor: Theme.Hangs.Colors.muted,
                    showsChevron: true
                ) {
                    Task { await performExportData() }
                }
                .accessibilityIdentifier("account.exportData")

                hairline

                HangsConfigRow(
                    label: "Sign out",
                    value: "",
                    valueColor: Theme.Hangs.Colors.muted
                ) {
                    Task { await performSignOut() }
                }
                .accessibilityIdentifier("account.signOut")

                hairline

                HangsConfigRow(
                    label: "Delete account",
                    value: "",
                    valueColor: Theme.Hangs.Colors.error
                ) {
                    showDeleteConfirmation = true
                }
                .accessibilityIdentifier("account.deleteAccount")
                .disabled(isDeletingAccount)
            }
        }
    }

    // MARK: Account actions

    private func handleAppleSignInResult(
        _ result: Result<ASAuthorization, Error>
    ) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                return
            }
            guard let idTokenData = credential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let authCodeData = credential.authorizationCode,
                  let authCode = String(data: authCodeData, encoding: .utf8) else {
                Logger.network.warning("🔐 Apple sign-in: missing identity_token or authorization_code")
                return
            }
            let rawNonce = pendingRawNonce
            let appleUser = credential.user
            let components = credential.fullName
            let fullName = [components?.givenName, components?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty
            let email = credential.email

            isSigningIn = true
            Task {
                let newTokens = await appState.authService.completeAppleSignIn(
                    identityToken: idToken,
                    authorizationCode: authCode,
                    rawNonce: rawNonce,
                    user: appleUser,
                    fullName: fullName,
                    email: email
                )
                isSigningIn = false
                if newTokens != nil {
                    currentTokens = KeychainTokenStore().load()
                }
            }
        case .failure(let error):
            // User cancelled or system error — not an app error; ASAuthorizationError.canceled is common.
            Logger.network.info("🔐 Apple sign-in cancelled/failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performSignOut() async {
        await appState.authService.signOut()
        currentTokens = KeychainTokenStore().load()
    }

    private func performDeleteAccount() async {
        isDeletingAccount = true
        do {
            try await appState.authService.deleteAccount()
            currentTokens = KeychainTokenStore().load()
        } catch {
            accountErrorMessage = error.localizedDescription
        }
        isDeletingAccount = false
    }

    private func performExportData() async {
        do {
            let data = try await appState.authService.exportData()
            // Present the export data as a share sheet.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("my-data-export.json")
            try data.write(to: tempURL)
            await MainActor.run {
                let activityVC = UIActivityViewController(
                    activityItems: [tempURL],
                    applicationActivities: nil
                )
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = windowScene.windows.first?.rootViewController {
                    root.present(activityVC, animated: true)
                }
            }
        } catch {
            Logger.network.warning("🔐 Export data failed: \(error.localizedDescription, privacy: .public)")
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
                    .environmentObject(AppState())
            }
        }
    }
#endif

// MARK: - Private helpers

private extension String {
    /// Returns nil when the string is empty (e.g. when Apple provides no given or family name).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
