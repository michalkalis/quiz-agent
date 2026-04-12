//
//  AppState.swift
//  CarQuiz
//
//  Dependency injection container for app-wide services
//

import Combine
import Foundation
import os

/// App-wide state and dependency container
@MainActor
final class AppState: ObservableObject {
    let networkService: NetworkServiceProtocol
    let audioService: AudioServiceProtocol
    let persistenceStore: PersistenceStoreProtocol
    let voiceCommandService: VoiceCommandServiceProtocol?
    let sttService: ElevenLabsSTTServiceProtocol?
    let storeManager: StoreManager

    init() {
        // Production dependencies
        self.networkService = NetworkService(baseURL: Config.apiBaseURL)
        self.audioService = AudioService()
        self.persistenceStore = PersistenceStore()
        self.storeManager = StoreManager()

        // Voice commands require iOS 26+ SpeechAnalyzer
        if #available(iOS 26, *) {
            self.voiceCommandService = VoiceCommandService()
        } else {
            self.voiceCommandService = nil
        }

        // ElevenLabs streaming STT (controlled by feature flag)
        if Config.useElevenLabsSTT {
            self.sttService = ElevenLabsSTTService()
        } else {
            self.sttService = nil
        }

        // Setup audio session with default mode
        try? audioService.setupAudioSession(mode: AudioMode.default)

        Logger.quiz.info("🚀 AppState initialized")
        Logger.quiz.info("📍 API Base URL: \(Config.apiBaseURL, privacy: .public)")
        let voiceAvailable = self.voiceCommandService != nil ? "available" : "unavailable (requires iOS 26+)"
        Logger.quiz.info("🎙️ Voice commands: \(voiceAvailable)")
        let sttEnabled = self.sttService != nil ? "enabled (ElevenLabs)" : "disabled (using Whisper)"
        Logger.quiz.info("🎙️ Streaming STT: \(sttEnabled)")
    }

    // For testing
    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        voiceCommandService: VoiceCommandServiceProtocol? = nil,
        sttService: ElevenLabsSTTServiceProtocol? = nil,
        storeManager: StoreManager? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.voiceCommandService = voiceCommandService
        self.sttService = sttService
        self.storeManager = storeManager ?? StoreManager()
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore,
            voiceCommandService: voiceCommandService,
            sttService: sttService
        )
    }
}
