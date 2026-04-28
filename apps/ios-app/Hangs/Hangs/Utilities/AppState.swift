//
//  AppState.swift
//  Hangs
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
    let silenceDetectionService: SilenceDetectionServiceProtocol?
    let sttService: ElevenLabsSTTServiceProtocol?
    let storeManager: StoreManager

    init() {
        #if DEBUG
        if UITestSupport.isUITesting {
            let mocks = UITestSupport.makeMockServices()
            self.networkService = mocks.network
            self.audioService = mocks.audio
            self.persistenceStore = mocks.persistence
            self.silenceDetectionService = mocks.silence
            self.sttService = mocks.stt
            self.storeManager = StoreManager()
            Logger.quiz.info("🧪 AppState initialized in UI-test mode")
            return
        }
        #endif

        // Production dependencies
        self.networkService = NetworkService(baseURL: Config.apiBaseURL)
        self.audioService = AudioService()
        self.persistenceStore = PersistenceStore()
        self.storeManager = StoreManager()

        // Silence detection / barge-in require iOS 26+ SpeechDetector
        if #available(iOS 26, *) {
            self.silenceDetectionService = SilenceDetectionService()
        } else {
            self.silenceDetectionService = nil
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
        let silenceAvailable = self.silenceDetectionService != nil ? "available" : "unavailable (requires iOS 26+)"
        Logger.quiz.info("🔇 Silence detection: \(silenceAvailable)")
        let sttEnabled = self.sttService != nil ? "enabled (ElevenLabs)" : "disabled (using Whisper)"
        Logger.quiz.info("🎙️ Streaming STT: \(sttEnabled)")
    }

    // For testing
    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol? = nil,
        sttService: ElevenLabsSTTServiceProtocol? = nil,
        storeManager: StoreManager? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        self.storeManager = storeManager ?? StoreManager()
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore,
            silenceDetectionService: silenceDetectionService,
            sttService: sttService
        )
    }
}
