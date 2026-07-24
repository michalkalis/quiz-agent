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
    // #111: owns the pushed-stack path for the root NavigationStack, replacing
    // the old broadcast-notification + identity-reset teardown bridge.
    @StateObject private var navModel = NavigationModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding: Bool
    @State private var showOnboardingReplay = false
    // #58 §9: contextual sign-in sheet after purchase/restore (decision 10).
    @State private var showSignInPrompt = false
    /// Set while the paywall is still up so the sign-in sheet presents only
    /// after the paywall's dismissal completes (two sheets can't overlap).
    @State private var signInPromptPending = false
    // #108C: keeps the screen awake for the duration of an active quiz.
    // Injectable so tests assert against a spy, never the real UIApplication.
    @State private var screenAwakeWriter = ScreenAwakeWriter()
    // #109: shake-to-report. Built at shake time with a screenshot of the
    // current screen + a snapshot of the quiz state; drives the feedback sheet.
    @State private var feedbackPresentation: FeedbackPresentation?

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

    /// Start a quiz that plays the delivered custom pack (#95). Moved here
    /// from SettingsView (#111): OrderPack/MyPacks are now built inside this
    /// view's single route-destination closure below, and the
    /// teardown that used to require a broadcast notification is now
    /// automatic — flipping `quizState` to `.startingQuiz` clears the pushed
    /// stack via `navModel.handleQuizStateChange` (the single `.onReceive`
    /// teardown below), so this closure needs no notification post of its own.
    private func playPack(_ packId: String) {
        viewModel.beginQuizStart(packId: packId)
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Main navigation content
            NavigationStack(path: $navModel.path) {
                Group {
                    switch viewModel.quizState {
                    // `.startingQuiz` stays on Home instead of mounting QuestionView
                    // (founder batch 2026-07-12 previously mounted QuestionView here
                    // immediately): with no `currentQuestion` yet, QuestionView rendered
                    // only its top chrome + a centered spinner — perceived as an empty
                    // "Quiz" screen. The Start Quiz button already reflects the loading
                    // state itself (HomeView's cancellable start control).
                    case .idle, .startingQuiz:
                        HomeView(viewModel: viewModel)

                    case .askingQuestion, .recording, .processing, .skipping:
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
                // #111: single route table for the root stack's push chain —
                // replaces the 4 imperative NavigationLink destinations.
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .settings:
                        SettingsView(viewModel: viewModel, onReplayOnboarding: replayOnboarding)
                    case .orderPack:
                        OrderPackView(service: appState.packOrderService, onPlayPack: playPack)
                    case .myPacks:
                        MyPacksView(service: appState.packOrderService, onPlayPack: playPack)
                    #if DEBUG
                        case .debugLog:
                            DebugLogView()
                    #endif
                    }
                }
            }

            // Floating minimized quiz view overlay
            if viewModel.isMinimized, viewModel.canMinimize {
                VStack {
                    Spacer()
                    MinimizedQuizView(viewModel: viewModel)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isMinimized)
        // #108C: keep the screen awake for the duration of an active quiz —
        // both the state and the minimized flag affect the answer, and the
        // flag must never outlive this view (onDisappear force-resets it).
        .onAppear {
            screenAwakeWriter.apply(state: viewModel.quizState, isMinimized: viewModel.isMinimized)
        }
        .onDisappear {
            screenAwakeWriter.reset()
        }
        .onChange(of: viewModel.quizState) { _, newState in
            screenAwakeWriter.apply(state: newState, isMinimized: viewModel.isMinimized)
        }
        .onChange(of: viewModel.isMinimized) { _, isMinimized in
            screenAwakeWriter.apply(state: viewModel.quizState, isMinimized: isMinimized)
        }
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
        // #111: the sole teardown path — entering `.startingQuiz` (from
        // `.idle`, or `.error` once #110's retry transition lands) clears the
        // pushed nav stack + the OrderProgress `isPresented` child in one
        // step, structurally covering every `startNewQuiz` call site
        // (voice "start", error-retry, and the button paths alike).
        // `.onReceive` (not `.onChange`) for the same reason as the
        // `isPurchased` bridge above: with mocked services `startNewQuiz`
        // can race `.idle → .startingQuiz → .askingQuestion` inside a single
        // SwiftUI render pass, and `.onChange` only diffs old/new value
        // *across* render passes — it silently skips the transient
        // `.startingQuiz` value and the teardown never runs. `.onReceive`
        // subscribes to the `@Published` pipeline directly, so every
        // intermediate value is delivered regardless of render coalescing
        // (found via RS-pack-nav-start, #111 T4).
        .onReceive(viewModel.$quizState) { newState in
            navModel.handleQuizStateChange(newState)
        }
        // #109: shake anywhere → capture the CURRENT screen, then present the
        // feedback sheet. Capture must happen before presentation so the shot
        // shows the reported screen, not the sheet. Ignored while one is open.
        .onShake {
            guard feedbackPresentation == nil else { return }
            let screenshot = ScreenshotCapture.captureKeyWindow()
            feedbackPresentation = FeedbackPresentation(
                viewModel: FeedbackViewModel(
                    networkService: appState.networkService,
                    context: FeedbackContext.capture(from: viewModel),
                    screenshot: screenshot,
                    voice: appState.makeFeedbackVoice(for: viewModel)
                )
            )
        }
        .sheet(item: $feedbackPresentation) { presentation in
            FeedbackView(viewModel: presentation.viewModel)
        }
        .environmentObject(navModel)
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
                    if viewModel.shouldRetryWithNewSession {
                        viewModel.beginQuizStart()
                    } else {
                        Task { await viewModel.retryLastOperation() }
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

#Preview {
    let appState = AppState()
    ContentView(appState: appState)
        .environmentObject(appState)
}
