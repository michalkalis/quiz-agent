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
            sessionStore: SessionStore(),
            questionHistoryStore: QuestionHistoryStore()
        ))
    }

    var body: some View {
        ZStack {
            // Main navigation content
            NavigationStack {
                Group {
                    switch viewModel.quizState {
                    case .idle:
                        HomeView(viewModel: viewModel)

                    case .askingQuestion, .recording, .processing:
                        // Show HomeView when minimized, otherwise QuestionView
                        if viewModel.isMinimized {
                            HomeView(viewModel: viewModel)
                        } else {
                            QuestionView(viewModel: viewModel)
                        }

                    case .showingResult:
                        ResultView(viewModel: viewModel)

                    case .finished:
                        CompletionView(viewModel: viewModel)

                    case .error:
                        ErrorView(viewModel: viewModel)
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

/// Error state view
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Oops!")
                .font(.largeTitle)
                .fontWeight(.bold)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Try Again") {
                Task {
                    // Check error context to determine retry action
                    if viewModel.shouldRetryWithNewSession {
                        await viewModel.startNewQuiz()
                    } else {
                        await viewModel.retryLastOperation()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)
            .padding(.top)

            Button("Go Home") {
                viewModel.resetToHome()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
