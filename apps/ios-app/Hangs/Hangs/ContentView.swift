//
//  ContentView.swift
//  Hangs
//
//  Main navigation and state management
//

import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: QuizViewModel
    @StateObject private var onboardingVM: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding: Bool
    @State private var showOnboardingReplay = false
    // #58 §9: contextual sign-in sheet after purchase/restore (decision 10).
    @State private var showSignInPrompt = false
    /// Set while the paywall is still up so the sign-in sheet presents only
    /// after the paywall's dismissal completes (two sheets can't overlap).
    @State private var signInPromptPending = false
    /// Identity of the root NavigationStack. Bumped when a custom pack's
    /// "Start quiz" fires (#95): the pack flow pushes Settings → OrderPack →
    /// OrderProgress onto this same stack, and flipping `quizState` only swaps
    /// the stack's *root* content — the pushed chain would stay on top and hide
    /// QuestionView. Recreating the stack drops the pushed chain; QuestionView
    /// then mounts as the fresh root. Safe because quiz state lives in
    /// `viewModel` (a @StateObject above the stack), not in the recreated views.
    @State private var navStackID = UUID()

    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: appState.makeQuizViewModel())
        _onboardingVM = StateObject(wrappedValue: OnboardingViewModel(
            audioService: appState.audioService,
            persistenceStore: appState.persistenceStore
        ))
        _showOnboarding = State(initialValue: !appState.persistenceStore.hasCompletedOnboarding)
        #if DEBUG
        // `--ui-test-signin-prompt`: present the #58 §9 contextual sign-in
        // sheet directly — it is otherwise reachable only through a real
        // StoreKit purchase, which the sim can't perform.
        if CommandLine.arguments.contains("--ui-test-signin-prompt") {
            _showSignInPrompt = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        if showOnboarding {
            OnboardingView(viewModel: onboardingVM)
                .onChange(of: onboardingVM.isComplete) { _, complete in
                    if complete { showOnboarding = false }
                }
        } else {
            mainContent
        }
    }

    /// #82 item 5: replay presents as a cover over the existing navigation
    /// stack instead of swapping the whole tree — swapping tore down the
    /// stack, so finishing the replay always dumped the user on Home rather
    /// than back in Settings where they started it. First-launch onboarding
    /// keeps the tree swap (there is no stack to preserve yet).
    private func replayOnboarding() {
        onboardingVM.startOnboarding()
        showOnboardingReplay = true
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Main navigation content
            NavigationStack {
                Group {
                    switch viewModel.quizState {
                    case .idle:
                        HomeView(viewModel: viewModel, onReplayOnboarding: replayOnboarding)

                    // .startingQuiz mounts QuestionView immediately (founder batch
                    // 2026-07-12): the top bar + progress render at launch — the
                    // total count is already known from settings — while the body
                    // shows the built-in spinner until the first question arrives.
                    case .startingQuiz, .askingQuestion, .recording, .processing, .skipping:
                        // Show HomeView when minimized, otherwise QuestionView
                        if viewModel.isMinimized {
                            HomeView(viewModel: viewModel)
                        } else {
                            QuestionView(viewModel: viewModel)
                        }

                    case .showingResult:
                        // Show HomeView when minimized, otherwise ResultView
                        if viewModel.isMinimized {
                            HomeView(viewModel: viewModel)
                        } else {
                            ResultView(viewModel: viewModel)
                        }

                    case .finished:
                        CompletionView(viewModel: viewModel)

                    case let .error(_, context):
                        // activeErrorModel is built by setError via AppErrorModel.from
                        // (localised copy + context-correct CTA — 54.15); the context
                        // fallback covers direct transitions that bypass setError.
                        ErrorView(
                            viewModel: viewModel,
                            model: viewModel.activeErrorModel ?? AppErrorModel.from(context: context)
                        )
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut, value: viewModel.quizState)
            }
            .id(navStackID)

            // Floating minimized quiz view overlay
            if viewModel.isMinimized {
                VStack {
                    Spacer()
                    MinimizedQuizView(viewModel: viewModel)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isMinimized)
        .fullScreenCover(isPresented: $showOnboardingReplay) {
            OnboardingView(viewModel: onboardingVM)
                .onChange(of: onboardingVM.isComplete) { _, complete in
                    if complete { showOnboardingReplay = false }
                }
        }
        .sheet(isPresented: $viewModel.showPaywall, onDismiss: {
            if signInPromptPending {
                signInPromptPending = false
                showSignInPrompt = true
            }
        }) {
            PaywallView(
                storeManager: appState.storeManager,
                limitError: viewModel.quotaLimitError,
                onDismiss: { viewModel.showPaywall = false }
            )
        }
        .sheet(isPresented: $showSignInPrompt) {
            ContextualSignInSheet(authService: appState.authService) {
                showSignInPrompt = false
            }
            .presentationDetents([.height(520)])
            .presentationDragIndicator(.visible)
        }
        // `.onReceive` subscribes to the publisher directly — the old
        // `.onChange(of: appState.storeManager.isPurchased)` never fired
        // because ContentView doesn't observe StoreManager (AppState has no
        // @Published members), so value-diffing had nothing to re-evaluate
        // against (#96 P1). Post-purchase side effects (entitlement sync,
        // usage refresh, paywall dismissal) live on the purchase outcome in
        // StoreManager/PaywallView now; this bridge only offers the #58
        // contextual sign-in prompt when Premium turns on.
        .onReceive(appState.storeManager.$isPurchased.removeDuplicates()) { isPurchased in
            guard isPurchased else { return }
            maybeQueueSignInPrompt(afterPaywall: viewModel.showPaywall)
        }
        // #95: a custom pack's "Start quiz" was tapped inside the pushed pack
        // flow. Recreate the root NavigationStack so that pushed chain is torn
        // down and the freshly started QuestionView is the visible root.
        .onReceive(NotificationCenter.default.publisher(for: .packQuizStarted)) { _ in
            navStackID = UUID()
        }
    }

    /// #58 §9: offer the contextual sign-in sheet when Premium turns on.
    /// StoreManager re-checks entitlements on every launch, so this fires
    /// both at the purchase moment and on later app opens — the gate's
    /// shown-count cap (1 prompt + 1 reminder) is what bounds it.
    private func maybeQueueSignInPrompt(afterPaywall: Bool) {
        let isSignedIn = KeychainTokenStore().load()?.isSignedIn ?? false
        guard SignInPromptGate.shouldPrompt(
            isPurchased: true,
            isSignedIn: isSignedIn,
            shownCount: appState.persistenceStore.signInPromptShownCount
        ) else { return }
        appState.persistenceStore.incrementSignInPromptShownCount()
        if afterPaywall {
            signInPromptPending = true
        } else {
            showSignInPrompt = true
        }
    }
}

/// Error screen — Fwafe frame. Bound to AppErrorModel (52.7 mapping).
/// Red icon circle + "OOPS" Anton hero + error-accent line + model title/description + CTA stack.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let model: AppErrorModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            Spacer(minLength: 40)

            VStack(spacing: 24) {
                errorIconCircle

                heroBlock

                Text(model.description)
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .accessibilityLabel(String(localized: "Error: \(model.title). \(model.description)", comment: "Accessibility label for the error screen: error title and description"))
                    .accessibilityIdentifier("error.description")

                #if DEBUG
                    if let detail = viewModel.lastErrorDebugInfo {
                        DebugErrorDetailsView(detail: detail)
                            .padding(.horizontal, 20)
                    }
                #endif
            }

            Spacer()

            ctaStack
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .accessibilityIdentifier("error.root")
    }

    private var errorIconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.error.opacity(0.12))
                .frame(width: 120, height: 120)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(Theme.Hangs.Colors.error)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("error.icon")
    }

    private var heroBlock: some View {
        VStack(spacing: 8) {
            Text("OOPS")
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Capsule()
                .fill(Theme.Hangs.Colors.error)
                .frame(width: 40, height: 3)
                .accessibilityHidden(true)

            Text(model.title)
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("error.title")
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: 10) {
            switch model.retryAction {
            case .retryOperation:
                HangsPrimaryButton(title: "Try Again", icon: "arrow.counterclockwise") {
                    Task {
                        if viewModel.shouldRetryWithNewSession {
                            await viewModel.startNewQuiz()
                        } else {
                            await viewModel.retryLastOperation()
                        }
                    }
                }
                .accessibilityIdentifier("error.retry")

                HangsSecondaryButton(title: "Go Home", icon: "house.fill", height: 56) {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.home")

            case .goHome:
                HangsPrimaryButton(title: "Go Home", icon: "house.fill") {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.home")

            case .dismiss:
                HangsSecondaryButton(title: "Dismiss", icon: "xmark", height: 56) {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.dismiss")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

extension Notification.Name {
    /// Posted by the custom-pack "Start quiz" action (SettingsView.playPack) so
    /// ContentView resets the root NavigationStack's identity — dropping the
    /// pushed Settings → OrderPack → OrderProgress (or MyPacks) chain that would
    /// otherwise cover the freshly started QuestionView (#95).
    nonisolated static let packQuizStarted = Notification.Name("packQuizStarted")
}

#Preview {
    let appState = AppState()
    ContentView(appState: appState)
        .environmentObject(appState)
}
