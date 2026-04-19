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

/// Error state view — Hangs redesign: big "CONNECTION LOST" block, red icon, retry CTA.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let errorMessage: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                iconBlock
                codeLabel
                titleBlock
                Text(errorMessage.isEmpty ? "Unable to reach the quiz server.\nCheck your connection and try again." : errorMessage)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .accessibilityLabel("Error: \(errorMessage)")
            }

            Spacer()

            VStack(spacing: 12) {
                HangsPrimaryButton(title: "RETRY CONNECTION", icon: "arrow.clockwise") {
                    Task {
                        if viewModel.shouldRetryWithNewSession {
                            await viewModel.startNewQuiz()
                        } else {
                            await viewModel.retryLastOperation()
                        }
                    }
                }
                .accessibilityIdentifier("error.retry")

                Button {
                    viewModel.resetToHome()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 13, weight: .bold))
                        Text("BACK TO HOME")
                            .font(.system(size: 15))
                            .tracking(1)
                    }
                    .foregroundColor(Theme.Hangs.Colors.infoAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .overlay(Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1.5))
                }
                .accessibilityIdentifier("error.home")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var iconBlock: some View {
        ZStack {
            Rectangle()
                .fill(Color(hex: "#2A1111"))
                .frame(width: 88, height: 88)
                .overlay(Rectangle().stroke(Theme.Hangs.Colors.error, lineWidth: 1))
            Image(systemName: "wifi.slash")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(Theme.Hangs.Colors.error)
        }
        .accessibilityHidden(true)
    }

    private var codeLabel: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Theme.Hangs.Colors.error).frame(width: 6, height: 6)
            Text("// ERROR_STATE")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Hangs.Colors.error)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 4) {
            Text("CONNECTION")
                .font(.system(size: 52, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("LOST")
                .font(.system(size: 52, weight: .black))
                .tracking(-1)
                .foregroundColor(Theme.Hangs.Colors.bg)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background(Theme.Hangs.Colors.error)
        }
    }
}

#Preview {
    let appState = AppState()
    ContentView(appState: appState)
        .environmentObject(appState)
}
