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
    /// The auth service, exposed so SettingsView can drive Apple sign-in, sign-out, and account actions.
    let authService: AuthService

    init() {
        #if DEBUG
        if UITestSupport.isUITesting {
            let mocks = UITestSupport.makeMockServices()
            self.networkService = mocks.network
            self.audioService = mocks.audio
            self.persistenceStore = mocks.persistence
            self.silenceDetectionService = mocks.silence
            self.sttService = mocks.stt
            self.storeManager = StoreManager(purchaseService: MockPurchaseService())
            self.authService = AuthService(baseURL: Config.apiBaseURL)
            UITestSupport.startTestListener()
            Logger.quiz.info("🧪 AppState initialized in UI-test mode")
            return
        }
        #endif

        // RevenueCat (#93): configure once, as early as possible, with whatever
        // durable account id is already on-device (nil on first-ever launch —
        // RC then mints its own anon id; a later sign-in re-aliases it via
        // StoreManager.logIn, see AuthService.completeAppleSignIn call sites).
        LivePurchaseService.configure(appUserID: KeychainTokenStore().load()?.anonId)

        // Production dependencies — NetworkService carries the server-trusted
        // anonymous bearer minted by AuthService (#60/#61); first launch bootstraps
        // an identity into the Keychain, and a 401 triggers a single-flight
        // refresh transparently.
        let authService = AuthService(baseURL: Config.apiBaseURL, attestor: AppAttestor())
        self.authService = authService
        self.networkService = NetworkService(baseURL: Config.apiBaseURL, authService: authService)
        self.audioService = AudioService()
        self.persistenceStore = PersistenceStore()
        self.storeManager = StoreManager()

        // Silence detection / barge-in require iOS 26+ SpeechDetector
        if #available(iOS 26, *) {
            let silenceService = SilenceDetectionService()
            self.silenceDetectionService = silenceService
            // One-time launch prepare (#77 device fix): check/download the
            // on-device en-US SpeechTranscriber model assets. Without them the
            // command transcriber never yields a result on a real device.
            // Non-blocking; any failure flips `commandAvailability` (fail loud).
            Task { await silenceService.prepareAssets() }
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

        // Check Apple credential state and register revocation observer (#61 task 61.6).
        // Runs asynchronously so it does not block app launch; a revoked credential
        // drops to a fresh anon identity transparently.
        Task {
            await authService.setupAppleCredentialObservation()
        }

        // RevenueCat account linking on sign-in (issue #93 Session E must-do):
        // alias RC's identity to the new durable account id, then re-sync the
        // server-side subscription mirror for the purchase↔sign-in race window.
        let storeManager = self.storeManager
        let networkService = self.networkService
        Task {
            await authService.setAccountLinkedHandler { accountId in
                await storeManager.logIn(accountId: accountId)
                try? await networkService.syncEntitlements()
            }
        }

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
        storeManager: StoreManager? = nil,
        authService: AuthService? = nil
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        self.storeManager = storeManager ?? StoreManager()
        self.authService = authService ?? AuthService(baseURL: Config.apiBaseURL)
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        let viewModel = QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore,
            silenceDetectionService: silenceDetectionService,
            sttService: sttService
        )

        #if DEBUG
        // `--ui-test-error`: land directly on a voice QuestionView with the
        // recording-error banner shown, so the error state can be screenshot-
        // verified without driving the full record→disconnect flow. Mirrors the
        // "Connection lost" copy set by QuizViewModel+Recording on STT drop.
        if CommandLine.arguments.contains("--ui-test-error") {
            viewModel.currentQuestion = Question.preview
            viewModel.quizState = .askingQuestion
            viewModel.errorMessage = "Connection lost. Tap Record to try again."
        }
        // `--ui-test-voice`: land on a voice QuestionView in the resting (Ready)
        // state so the rewritten voiceBody layout can be screenshot-verified.
        if CommandLine.arguments.contains("--ui-test-voice") {
            viewModel.currentQuestion = Question.preview
            viewModel.quizState = .askingQuestion
        }
        // `--ui-test-voice-sk`: voice QuestionView (Ready) seeded with a long
        // Slovak question covering every caron (č š ž ľ ť), to verify the
        // full-Unicode fonts render diacritics in-face (step 7 diacritics pass).
        if CommandLine.arguments.contains("--ui-test-voice-sk") {
            viewModel.currentQuestion = Question.previewSlovak
            viewModel.quizState = .askingQuestion
        }
        // `--ui-test-recording`: voice QuestionView mid-recording with a live
        // transcript, to verify the transcript card pins above the action row.
        if CommandLine.arguments.contains("--ui-test-recording") {
            viewModel.currentQuestion = Question.preview
            viewModel.quizState = .recording
            viewModel.liveTranscript = "Paris is the capital of France"
            viewModel.isStreamingSTT = true
        }
        #endif

        return viewModel
    }
}
