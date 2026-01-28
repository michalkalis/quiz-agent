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

    init() {
        // Production dependencies
        self.networkService = NetworkService(baseURL: Config.apiBaseURL)
        self.audioService = AudioService()
        self.persistenceStore = PersistenceStore()

        // Setup audio session with default mode
        try? audioService.setupAudioSession(mode: AudioMode.default)

        if Config.verboseLogging {
            print("🚀 AppState initialized")
            print("📍 API Base URL: \(Config.apiBaseURL)")
        }
    }

    // For testing
    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore
        )
    }
}
