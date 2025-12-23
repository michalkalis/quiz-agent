//
//  QuestionView.swift
//  CarQuiz
//
//  Main quiz screen with question display and voice recording
//

import SwiftUI

struct QuestionView: View {
    @ObservedObject var viewModel: QuizViewModel
    @EnvironmentObject var appState: AppState

    @State private var recordingError: String?
    @State private var audioData: Data?

    var body: some View {
        VStack(spacing: 24) {
            // Header: Progress and Score
            HStack {
                // Progress indicator
                if let session = viewModel.currentSession,
                   viewModel.questionsAnswered < session.maxQuestions {
                    Text("Q \(viewModel.questionsAnswered + 1)/\(session.maxQuestions)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Score
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)

                    Text("\(Int(viewModel.score))")
                        .font(.headline)
                }
            }
            .padding(.horizontal)

            Spacer()

            // Question content
            if let question = viewModel.currentQuestion {
                VStack(spacing: 16) {
                    // Topic badge
                    Text(question.topic.capitalized)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(12)

                    // Question text
                    Text(question.question)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
            }

            Spacer()

            // Recording status
            if viewModel.quizState == .recording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .modifier(PulsingAnimation())

                    Text("Recording...")
                        .font(.headline)
                        .foregroundColor(.red)
                }
                .padding()
            } else if viewModel.quizState == .processing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Processing your answer...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                Text("Tap to answer")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding()
            }

            // Microphone button
            Button(action: handleMicrophoneTap) {
                ZStack {
                    Circle()
                        .fill(microphoneButtonColor)
                        .frame(width: 80, height: 80)
                        .shadow(radius: viewModel.quizState == .recording ? 8 : 4)

                    Image(systemName: microphoneIcon)
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
            }
            .disabled(viewModel.quizState == .processing)
            .padding(.bottom, 40)

            // Error message
            if let error = recordingError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .padding()
    }

    // MARK: - Computed Properties

    private var microphoneButtonColor: Color {
        switch viewModel.quizState {
        case .recording:
            return .red
        case .processing:
            return .gray
        default:
            return .blue
        }
    }

    private var microphoneIcon: String {
        switch viewModel.quizState {
        case .recording:
            return "stop.circle.fill"
        case .processing:
            return "waveform"
        default:
            return "mic.fill"
        }
    }

    // MARK: - Actions

    private func handleMicrophoneTap() {
        recordingError = nil

        Task {
            do {
                switch viewModel.quizState {
                case .askingQuestion:
                    // Start recording
                    try appState.audioService.startRecording()
                    viewModel.quizState = .recording

                case .recording:
                    // Stop recording and submit
                    let data = try await appState.audioService.stopRecording()
                    await viewModel.submitVoiceAnswer(audioData: data)

                default:
                    break
                }
            } catch {
                recordingError = "Recording failed: \(error.localizedDescription)"
                viewModel.quizState = .askingQuestion

                if Config.verboseLogging {
                    print("❌ Recording error: \(error)")
                }
            }
        }
    }
}

// MARK: - Pulsing Animation

struct PulsingAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

#Preview {
    QuestionView(viewModel: QuizViewModel.preview)
        .environmentObject(AppState())
}
