//
//  ContentView.swift
//  Hangs
//
//  Main navigation and state management
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: QuizViewModel
    @StateObject private var onboardingVM: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding: Bool

    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: appState.makeQuizViewModel())
        _onboardingVM = StateObject(wrappedValue: OnboardingViewModel(
            audioService: appState.audioService,
            persistenceStore: appState.persistenceStore
        ))
        _showOnboarding = State(initialValue: !appState.persistenceStore.hasCompletedOnboarding)
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

    private func replayOnboarding() {
        onboardingVM.startOnboarding()
        showOnboarding = true
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Main navigation content
            NavigationStack {
                Group {
                    switch viewModel.quizState {
                    case .idle, .startingQuiz:
                        HomeView(viewModel: viewModel, onReplayOnboarding: replayOnboarding)

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
            }

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
        .sheet(isPresented: $viewModel.showPaywall) {
            PaywallView(
                storeManager: appState.storeManager,
                limitError: viewModel.dailyLimitError,
                onDismiss: { viewModel.showPaywall = false }
            )
        }
        .onChange(of: appState.storeManager.isPurchased) { _, isPurchased in
            if isPurchased {
                viewModel.showPaywall = false
                Task { await viewModel.notifyPremiumPurchased() }
            }
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
                    .accessibilityLabel("Error: \(model.title). \(model.description)")
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
            Image(systemName: "exclamationmark.triangle.fill")
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

#Preview {
    let appState = AppState()
    ContentView(appState: appState)
        .environmentObject(appState)
}
