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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding: Bool

    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: appState.makeQuizViewModel())
        _showOnboarding = State(initialValue: !appState.persistenceStore.hasCompletedOnboarding)
    }

    var body: some View {
        if showOnboarding {
            OnboardingView(audioService: appState.audioService) {
                appState.persistenceStore.completeOnboarding()
                showOnboarding = false
            }
        } else {
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Main navigation content
            NavigationStack {
                Group {
                    switch viewModel.quizState {
                    case .idle, .startingQuiz:
                        HomeView(viewModel: viewModel)

                    case .askingQuestion, .recording, .processing:
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

                    case .error(let message, _):
                        ErrorView(viewModel: viewModel, errorMessage: message)
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

/// Error state view — Hangs redesign: centered "OOPS" hero, pink alert icon,
/// retry + home CTAs. Matches Pencil NEW_Screen/Error.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let errorMessage: String

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            Spacer(minLength: 40)

            VStack(spacing: 24) {
                iconCircle

                HangsHeroBlock(
                    title: "OOPS",
                    subtitle: "Something went wrong",
                    titleFont: .hangsDisplayLG,
                    alignment: .center
                )
                .padding(.horizontal, 20)

                Text(errorMessage.isEmpty
                     ? "Unable to reach the quiz server. Check your connection and try again."
                     : errorMessage)
                    .font(.hangsBody(14))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .accessibilityLabel("Error: \(errorMessage)")

                #if DEBUG
                if let detail = viewModel.lastErrorDebugInfo {
                    DebugErrorDetailsView(detail: detail)
                        .padding(.horizontal, 20)
                }
                #endif
            }

            Spacer()

            VStack(spacing: 10) {
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
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    private var iconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.pinkSoft)
                .frame(width: 128, height: 128)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundColor(Theme.Hangs.Colors.pink)
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    let appState = AppState()
    ContentView(appState: appState)
        .environmentObject(appState)
}
