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
                viewModel.showLanguagePicker()
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

            // Current settings display
            VStack(spacing: 4) {
                if let currentLanguage = Language.forCode(viewModel.selectedLanguage.id) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption)
                        Text("Language: \(currentLanguage.nativeName)")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: viewModel.selectedAudioMode.icon)
                        .font(.caption)
                    Text("Audio: \(viewModel.selectedAudioMode.name)")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            // Loading indicator
            if viewModel.isLoading {
                ProgressView()
                    .padding()
            }

            Spacer()
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink {
                    SettingsView(viewModel: viewModel)
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    viewModel.toggleAudioMode()
                }) {
                    Label {
                        Text(viewModel.selectedAudioMode.name)
                    } icon: {
                        Image(systemName: viewModel.selectedAudioMode.icon)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $viewModel.showingLanguagePicker) {
            LanguagePickerView(
                selectedLanguage: $viewModel.selectedLanguage,
                onConfirm: {
                    viewModel.confirmLanguageAndStartQuiz()
                }
            )
        }
        .onAppear {
            viewModel.loadSavedLanguage()
            viewModel.loadSavedAudioMode()
        }
    }
}

#Preview {
    HomeView(viewModel: QuizViewModel.preview)
}
