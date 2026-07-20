//
//  SettingsView.swift
//  Hangs
//
//  Hangs redesign settings — bg-page background, grouped white cards,
//  pink/blue mono section labels. Matches Pencil NEW_Screen/Settings (Jjcs5).
//  #52 task 52.9.
//  #61 task 61.7: account section (Sign in with Apple / signed-in state / delete account).
//  #80: pinned HIG navigation bar — brand back chip leading, large-title collapse,
//  mono micro-caps pinned title, edge-swipe pop restored.
//

import AuthenticationServices
import Combine
import SwiftUI
import os

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
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

    // Custom packs (#95): admin-gated entry. `hasAdminKey` reflects whether a key
    // is stored; the order/list links only appear once one is saved.
    @State private var adminKeyInput: String = ""
    @State private var hasAdminKey: Bool = false

    // #80: pinned-bar title fades in once the in-content hero scrolls away.
    @State private var isHeroCollapsed = false

    // #109: in-app feedback. Built when the row is tapped, with a screenshot of
    // the Settings screen + a snapshot of the quiz state; drives the sheet.
    @State private var feedbackPresentation: FeedbackPresentation?

    /// Collapse threshold for the large-title behavior (#80 Variant B): the
    /// pinned mono title appears only after the hero headline has scrolled
    /// under the bar (~hero title height + top padding).
    static func heroIsCollapsed(offsetY: CGFloat) -> Bool {
        offsetY > 96
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
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
                    sessionGroup
                    audioFeedbackGroup
                    accountGroup
                    subscriptionGroup
                    aboutGroup
                    feedbackGroup
                    packsGroup
                    #if DEBUG
                        developerGroup
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            Self.heroIsCollapsed(offsetY: geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, collapsed in
            withAnimation(.easeInOut(duration: 0.15)) { isHeroCollapsed = collapsed }
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        // Founder batch 2026-07-12 (replaces #80's brand chip + custom edge-pan):
        // the system back button and native swipe-to-pop stay untouched — custom
        // navigation gestures proved fragile across iOS versions.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("SETTINGS")
                    .font(.hangsMono(13, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .opacity(isHeroCollapsed ? 1 : 0)
                    .accessibilityHidden(!isHeroCollapsed)
            }
        }
        .task {
            // Load auth state from Keychain on appear.
            currentTokens = KeychainTokenStore().load()
            hasAdminKey = AdminKeyStore().load() != nil
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
        .sheet(item: $feedbackPresentation) { presentation in
            FeedbackView(viewModel: presentation.viewModel)
        }
    }

    // MARK: - Groups

    private var voiceGroup: some View {
        groupSection(label: "voice", color: Theme.Hangs.Colors.pink) {
            // Master command toggle (#96 P2, pen `gEPhB`). Governs the whole
            // screen-scoped command listener; default ON. Refreshes the window
            // immediately so flipping it off tears the listener down at once.
            HangsToggleRow(
                label: "Voice commands",
                subtitle: "Hands-free spoken commands while driving",
                isOn: $viewModel.settings.voiceCommandsEnabled
            )
            .accessibilityIdentifier("settings.voiceCommands")
            .onChange(of: viewModel.settings.voiceCommandsEnabled) { _, _ in
                viewModel.refreshCommandWindow()
            }

            hairline

            // Release-visible recognizer diagnostics (#96 P2): asset state + the
            // last command heard, so the founder can confirm on-device that
            // recognition is armed and firing. Full failure reason → Sentry.
            HangsValueRow(label: "Status", value: voiceCommandsDiagnostic)
                .accessibilityIdentifier("settings-voice-commands-status")

            hairline

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

            hairline

            // #82 item 1 (decision 7, Variant B): re-expose the Call Mode
            // switch the mic-picker footnote points at — Bluetooth mics
            // (car, headset) need the call-mode audio session. The mode
            // model and switch logic existed but were reachable from no
            // screen, leaving the footnote a dangling pointer.
            HangsToggleRow(
                label: "Call Mode",
                // Same catalog key as AudioMode.callMode's description — one
                // translation serves both (founder batch 2026-07-12: the bare
                // toggle didn't explain what Call Mode does).
                subtitle: "Uses Bluetooth microphone (may show as phone call in car)",
                isOn: Binding(
                    get: { viewModel.selectedAudioMode.id == "call" },
                    set: { _ in viewModel.toggleAudioMode() }
                )
            )
            .accessibilityIdentifier("settings-call-mode-toggle")
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
                    // "Current language" read as the APP language — this is the
                    // quiz content/voice language (founder batch 2026-07-12).
                    label: "Quiz language",
                    value: Language.forCode(viewModel.settings.language)?.nativeName ?? "English",
                    valueColor: Theme.Hangs.Colors.pink,
                    action: {}
                )
                .allowsHitTesting(false)
            }
            .accessibilityIdentifier("settings-language-menu")
        }
    }

    // MARK: - Session group (#68, founder decision 6 Variant A)
    // Four menu rows exposing the driving-critical session fields that were
    // previously code-only. Design reference: Pencil NEW_Screen/Settings (Jjcs5).

    private var sessionGroup: some View {
        groupSection(label: "session", color: Theme.Hangs.Colors.blue) {
            sessionMenuRow(
                label: "Thinking time",
                options: QuizSettings.thinkingTimeOptions,
                selection: $viewModel.settings.thinkingTime,
                display: Self.secondsDisplay
            )
            .accessibilityIdentifier("settings-thinking-time-menu")

            hairline

            sessionMenuRow(
                label: "Questions per session",
                options: QuizSettings.questionCountOptions,
                selection: $viewModel.settings.numberOfQuestions,
                display: Self.questionCountDisplay
            )
            .accessibilityIdentifier("settings-question-count-menu")

            hairline

            sessionMenuRow(
                label: "Auto-advance delay",
                options: QuizSettings.autoAdvanceDelayOptions,
                selection: $viewModel.settings.autoAdvanceDelay,
                display: Self.secondsDisplay
            )
            .accessibilityIdentifier("settings-auto-advance-menu")

            hairline

            sessionMenuRow(
                label: "Answer time limit",
                options: QuizSettings.answerTimeLimitOptions,
                selection: $viewModel.settings.answerTimeLimit,
                display: Self.answerLimitDisplay
            )
            .accessibilityIdentifier("settings-answer-limit-menu")
        }
    }

    private func sessionMenuRow(
        label: LocalizedStringKey,
        options: [Int],
        selection: Binding<Int>,
        display: @escaping (Int) -> String
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(display(option)) { selection.wrappedValue = option }
            }
        } label: {
            HangsConfigRow(
                label: label,
                value: display(selection.wrappedValue),
                valueColor: Theme.Hangs.Colors.blue,
                action: {}
            )
            .allowsHitTesting(false)
        }
    }

    /// "10s"; 0 stays literal ("0s" = record immediately for thinking time).
    private static func secondsDisplay(_ seconds: Int) -> String {
        String(localized: "\(seconds)s", comment: "Seconds value in session settings, e.g. 10s")
    }

    /// "10 questions" per the approved frame.
    private static func questionCountDisplay(_ count: Int) -> String {
        String(localized: "\(count) questions", comment: "Questions-per-session value in session settings")
    }

    /// Answer time limit: 0 means the timer is disabled.
    private static func answerLimitDisplay(_ seconds: Int) -> String {
        seconds == 0
            ? String(localized: "Off", comment: "Answer time limit disabled")
            : secondsDisplay(seconds)
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

            hairline

            HangsToggleRow(
                label: "Recording sounds",
                isOn: $viewModel.settings.recordingSoundsEnabled
            )
            .accessibilityIdentifier("settings-recording-sounds-toggle")
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
            guard let payload = AppleSignInPayload(authorization: auth) else {
                Logger.network.warning("🔐 Apple sign-in: missing identity_token or authorization_code")
                return
            }
            let rawNonce = pendingRawNonce

            isSigningIn = true
            Task {
                let newTokens = await appState.authService.completeAppleSignIn(
                    identityToken: payload.identityToken,
                    authorizationCode: payload.authorizationCode,
                    rawNonce: rawNonce,
                    user: payload.user,
                    fullName: payload.fullName,
                    email: payload.email
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

    // MARK: - Subscription group (#93 subscription IAP)
    // Proactive, discoverable paywall entry: shows the current plan state and
    // opens the existing paywall sheet (ContentView owns presentation via
    // viewModel.showPaywall). Restore purchase lives on the paywall itself,
    // so this row is also its discoverable home — no duplicated restore logic.
    // Reads viewModel.usageInfo (refreshed on Home appear); no extra network call.

    private var subscriptionGroup: some View {
        groupSection(label: "subscription", color: Theme.Hangs.Colors.pink) {
            HangsConfigRow(
                label: "Plan",
                value: subscriptionPlanDisplay,
                valueColor: Theme.Hangs.Colors.pink,
                showsChevron: true
            ) {
                viewModel.presentPaywall()
            }
            .accessibilityIdentifier("settings.subscription")
        }
    }

    private var subscriptionPlanDisplay: String {
        guard let usage = viewModel.usageInfo else {
            return String(localized: "Free", comment: "Settings subscription row value before usage has loaded")
        }
        if usage.isPremium {
            return String(localized: "Unlimited", comment: "Settings subscription row value for premium users")
        }
        if usage.creditBalance > 0 {
            return String(localized: "Free · \(usage.creditBalance) credits", comment: "Settings subscription row value: free plan with pack credits remaining")
        }
        return String(localized: "Free · \(usage.remaining ?? 0) of \(usage.questionsLimit ?? 0) left", comment: "Settings subscription row value: free plan with remaining monthly questions")
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

    // MARK: - Feedback group (#109)
    // Manual entry point for the in-app beta feedback sheet — mirrors the
    // shake-to-report gesture but is always discoverable. Captures a screenshot
    // of the Settings screen (still removable in the sheet) + the current quiz
    // state before presenting.

    private var feedbackGroup: some View {
        groupSection(label: "feedback", color: Theme.Hangs.Colors.accentTeal) {
            HangsConfigRow(
                label: "Send feedback",
                value: "",
                valueColor: Theme.Hangs.Colors.muted,
                showsChevron: true
            ) {
                let screenshot = ScreenshotCapture.captureKeyWindow()
                feedbackPresentation = FeedbackPresentation(
                    viewModel: FeedbackViewModel(
                        networkService: appState.networkService,
                        context: FeedbackContext.capture(from: viewModel),
                        screenshot: screenshot
                    )
                )
            }
            .accessibilityIdentifier("settings.sendFeedback")
        }
    }

    // MARK: - Custom packs group (#95)
    // Admin-gated: paste the quiz-pack-api admin key once (stored in the
    // Keychain, never in the binary — works in TestFlight). Once a key is
    // stored, the order + list links appear. This lives OUTSIDE the paywall
    // by design — custom packs are a distinct concept from #93 credit packs.

    private var packsGroup: some View {
        groupSection(label: "custom packs", color: Theme.Hangs.Colors.accentTeal) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    SecureField("Admin key", text: $adminKeyInput)
                        .font(.hangsBody(15))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("packs.adminKeyField")
                    Button("Save") {
                        let trimmed = adminKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        AdminKeyStore().save(trimmed)
                        adminKeyInput = ""
                        hasAdminKey = true
                    }
                    .font(.hangsBody(15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.pink)
                    .accessibilityIdentifier("packs.saveAdminKey")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                if hasAdminKey {
                    hairline

                    NavigationLink {
                        OrderPackView(service: appState.packOrderService, onPlayPack: playPack)
                    } label: {
                        HangsConfigRow(label: "Create a pack", value: "", valueColor: Theme.Hangs.Colors.muted, showsChevron: true, action: {})
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("packs.createPack")

                    hairline

                    NavigationLink {
                        MyPacksView(service: appState.packOrderService, onPlayPack: playPack)
                    } label: {
                        HangsConfigRow(label: "My packs", value: "", valueColor: Theme.Hangs.Colors.muted, showsChevron: true, action: {})
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("packs.myPacks")
                }
            }
        }
    }

    /// Start a quiz that plays the delivered custom pack. Flipping the quiz state
    /// swaps the root NavigationStack content to QuestionView, but the pushed
    /// Settings → OrderPack → OrderProgress (or MyPacks) chain lives on the same
    /// NavigationStack and would otherwise stay on top, hiding QuestionView. So we
    /// post `.packQuizStarted`, which ContentView observes to reset the root
    /// NavigationStack's identity — popping the whole pushed chain — before the
    /// quiz renders (#95 nav fix).
    private func playPack(_ packId: String) {
        NotificationCenter.default.post(name: .packQuizStarted, object: nil)
        Task { await viewModel.startNewQuiz(packId: packId) }
    }

    /// Release-visible readout of the voice-command recognizer state (#96 P2):
    /// master-toggle state, on-device asset availability, and the last command
    /// heard. Kept short for the row; the full failure reason goes to Sentry via
    /// `SilenceDetectionService.markCommandsUnavailable`.
    private var voiceCommandsDiagnostic: String {
        if !viewModel.settings.voiceCommandsEnabled { return "Off" }
        guard appState.silenceDetectionService != nil else {
            return "Needs iOS 26"
        }
        // Read the view-model's observable mirror (not the service's plain
        // property) so this row live-updates when the recognizer flips to
        // `.ready` after the model finishes installing (#96 S2).
        let base: String
        switch viewModel.commandAvailability {
        case .unknown: base = "Checking…"
        case .installingAssets: base = "Installing…"
        case .ready: base = "Ready"
        case .unavailable: base = "Unavailable"
        }
        if let last = viewModel.lastRecognizedCommand {
            return "\(base) · heard \"\(VoiceCommandLexicon.spokenWord(last))\""
        }
        return base
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

