//
//  AppState.swift
//  CarQuiz
//
//  Dependency injection container for app-wide services
//

import Combine
import Foundation

/// App-wide state and dependency container
@MainActor
final class AppState: ObservableObject {
    let networkService: NetworkServiceProtocol
    let audioService: AudioServiceProtocol
    let persistenceStore: PersistenceStoreProtocol
    let voiceCommandService: VoiceCommandServiceProtocol?

    init() {
        // Production dependencies
        self.networkService = NetworkService(baseURL: Config.apiBaseURL)
        self.audioService = AudioService()
        self.persistenceStore = PersistenceStore()

        // Voice commands require iOS 26+ SpeechAnalyzer
        if #available(iOS 26, *) {
            self.voiceCommandService = VoiceCommandService()
        } else {
            self.voiceCommandService = nil
        }

        // Setup audio session with default mode
        try? audioService.setupAudioSession(mode: AudioMode.default)

        if Config.verboseLogging {
            print("🚀 AppState initialized")
            print("📍 API Base URL: \(Config.apiBaseURL)")
            print("🎙️ Voice commands: \(voiceCommandService != nil ? "available" : "unavailable (requires iOS 26+)")")
        }
    }

    // For testing
    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        voiceCommandService: VoiceCommandServiceProtocol? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.voiceCommandService = voiceCommandService
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore,
            voiceCommandService: voiceCommandService
        )
    }
}
