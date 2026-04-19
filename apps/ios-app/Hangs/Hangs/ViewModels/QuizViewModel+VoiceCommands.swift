//
//  QuizViewModel+VoiceCommands.swift
//  Hangs
//
//  Voice command handling: start/stop listening, command dispatch, barge-in
//

import Foundation
import os

// MARK: - Voice Commands

extension QuizViewModel {

    /// Start listening for voice commands and subscribe to the command stream
    func startVoiceCommands() async {
        guard let service = voiceCommandService, settings.voiceCommandsEnabled else {
            voiceCommandState = .disabled
            return
        }

        // Wait for engine setup to complete before returning
        await service.startListening()

        // Fire off long-running command processing loop
        voiceCommandTask = Task { [weak self] in
            for await command in service.commands {
                guard let self, !Task.isCancelled else { break }
                await self.handleVoiceCommand(command)
            }
        }

        // Subscribe to barge-in events (speech during TTS on external audio)
        if settings.bargeInEnabled {
            bargeInTask = Task { [weak self] in
                for await _ in service.bargeInEvents {
                    guard let self, !Task.isCancelled else { break }
                    await self.handleBargeIn()
                }
            }
        }

        // Sync UI state
        voiceCommandState = .listening
    }

    /// Stop voice command listening
    func stopVoiceCommands() {
        voiceCommandTask?.cancel()
        voiceCommandTask = nil
        bargeInTask?.cancel()
        bargeInTask = nil
        voiceCommandService?.stopListening()
        voiceCommandState = .disabled
    }

    /// Handle barge-in: user spoke during TTS playback on external audio route
    private func handleBargeIn() async {
        // Only barge-in during question playback
        guard quizState == .askingQuestion else { return }

        Logger.voice.info("🗣️ Barge-in triggered — stopping TTS and starting recording")

        // 1. Stop TTS immediately
        await stopAnyPlayingAudio()

        // 2. Clear echo cancellation state
        voiceCommandService?.setPlaybackText(nil)
        voiceCommandService?.setTTSPlaybackActive(false)

        // 3. Wait for audio hardware to settle
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // 4. Guard again — state may have changed during sleep
        guard quizState == .askingQuestion else { return }

        // 5. Auto-start recording (same as post-TTS flow)
        cancelAnswerTimer()
        isAutoRecording = true
        await startRecording()
    }

    /// Dispatch a voice command to the appropriate action based on current state
    private func handleVoiceCommand(_ command: VoiceCommand) async {
        // Update UI state briefly
        voiceCommandState = .commandDetected(command)

        switch command {
        case .start:
            if quizState == .askingQuestion {
                cancelAnswerTimer()
                cancelThinkingTime()
                await startRecording()
            } else if showAnswerConfirmation {
                rerecordAnswer()
            }

        case .stop:
            if quizState == .recording {
                cancelAutoStopRecordingTimer()
                await stopRecordingAndSubmit()
            }

        case .skip:
            if quizState == .askingQuestion {
                await skipQuestion()
            }

        case .repeat:
            await repeatQuestion()

        case .score:
            if quizState == .askingQuestion || quizState.isShowingResult {
                let total = currentSession?.maxQuestions ?? 0
                let current = questionsAnswered + (quizState == .askingQuestion ? 1 : 0)
                let text = "Your score is \(Int(score)) out of \(questionsAnswered). Question \(current) of \(total)."
                await audioService.speakText(text)
            }

        case .help:
            if quizState == .askingQuestion {
                let text = "Say skip to skip, start to record, stop to submit, or ok to confirm."
                await audioService.speakText(text)
            } else if quizState == .finished {
                let text = "Say again to play again, or home to go back."
                await audioService.speakText(text)
            }

        case .ok:
            if showAnswerConfirmation && !isProcessingResponse {
                await confirmAnswer()
            }

        case .again:
            if quizState == .finished {
                await startNewQuiz()
            }

        case .home:
            if quizState == .finished {
                resetToHome()
            }

        case .optionA, .optionB, .optionC, .optionD:
            if quizState == .askingQuestion,
               let question = currentQuestion,
               question.isMultipleChoice {
                let key: String
                switch command {
                case .optionA: key = "a"
                case .optionB: key = "b"
                case .optionC: key = "c"
                case .optionD: key = "d"
                default: return
                }
                if let value = question.possibleAnswers?[key] {
                    await submitMCQAnswer(key: key, value: value)
                }
            }
        }

        // Reset to listening after brief delay
        try? await Task.sleep(nanoseconds: 300_000_000)
        if voiceCommandTask != nil {
            voiceCommandState = .listening
        }
    }
}
