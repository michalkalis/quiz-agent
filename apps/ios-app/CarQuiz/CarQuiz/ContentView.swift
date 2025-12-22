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
        // Will be initialized properly via environmentObject
        _viewModel = StateObject(wrappedValue: QuizViewModel(
            networkService: NetworkService(),
            audioService: AudioService(),
            sessionStore: SessionStore()
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.quizState {
                case .idle:
                    HomeView(viewModel: viewModel)

                case .askingQuestion, .recording, .processing:
                    QuestionView(viewModel: viewModel)

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
                    await viewModel.startNewQuiz()
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
