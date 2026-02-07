//
//  ContentView.swift
//  CarQuiz
//
//  Main navigation and state management
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: QuizViewModel

    init() {
        // Temporary initialization - will be replaced with proper dependency injection
        _viewModel = StateObject(wrappedValue: QuizViewModel(
            networkService: NetworkService(),
            audioService: AudioService(),
            persistenceStore: PersistenceStore()
        ))
    }

    var body: some View {
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
                .animation(.easeInOut, value: viewModel.quizState)
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
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isMinimized)
        .onAppear {
            // Initialize ViewModel with app-wide dependencies
            // This ensures proper dependency injection
        }
    }
}

/// Error state view with themed styling
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let errorMessage: String

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            // Error icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.errorBg)
                    .frame(width: Theme.Components.trophySize, height: Theme.Components.trophySize)

                Image(systemName: "wifi.slash")
                    .font(.system(size: Theme.Components.trophyIconSize))
                    .foregroundColor(Theme.Colors.error)
            }

            // Error message
            VStack(spacing: Theme.Spacing.xs) {
                Text("Oops!")
                    .font(.displayXXL)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(errorMessage)
                    .font(.textMD)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)
            }

            Spacer()

            // Action buttons
            VStack(spacing: Theme.Spacing.md) {
                PrimaryButton(
                    title: "Try Again",
                    icon: "arrow.clockwise"
                ) {
                    Task {
                        if viewModel.shouldRetryWithNewSession {
                            await viewModel.startNewQuiz()
                        } else {
                            await viewModel.retryLastOperation()
                        }
                    }
                }

                SecondaryButton(title: "Go Home") {
                    viewModel.resetToHome()
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .padding()
        .background(Theme.Colors.bgPrimary)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
