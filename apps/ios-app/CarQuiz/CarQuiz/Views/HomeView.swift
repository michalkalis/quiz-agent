//
//  HomeView.swift
//  CarQuiz
//
//  Welcome screen and quiz start
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Icon/Logo
            Image(systemName: "car.fill")
                .font(.system(size: 80))
                .foregroundColor(.blue)

            // Title
            VStack(spacing: 8) {
                Text("CarQuiz")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Hands-Free Trivia While You Drive")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Start Button
            Button(action: {
                Task {
                    await viewModel.startNewQuiz()
                }
            }) {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)

                    Text("Start Quiz")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(16)
            }
            .padding(.horizontal, 40)
            .disabled(viewModel.isLoading)

            // Loading indicator
            if viewModel.isLoading {
                ProgressView()
                    .padding()
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    HomeView(viewModel: QuizViewModel.preview)
}
