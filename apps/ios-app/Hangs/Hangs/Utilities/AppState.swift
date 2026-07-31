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
    let silenceDetectionService: SilenceDetectionServiceProtocol
    let sttService: ElevenLabsSTTServiceProtocol?
    let storeManager: StoreManager
    /// The auth service, exposed so SettingsView can drive Apple sign-in, sign-out, and account actions.
    let authService: AuthService
    /// Custom-pack ordering client (issue #95), targeting the quiz-pack-api host.
    let packOrderService: PackOrderServiceProtocol

    /// The live QuizViewModel, registered by `makeQuizViewModel()` (weak — the
    /// owner is ContentView's `@StateObject`). HangsApp routes scene-phase
    /// changes through it so the mic input is torn down in the background.
    private(set) weak var quizViewModel: QuizViewModel?

    init() {
        #if DEBUG
            if UITestSupport.isUITesting {
                let mocks = UITestSupport.makeMockServices()
                self.networkService = mocks.network
                audioService = mocks.audio
                persistenceStore = mocks.persistence
                silenceDetectionService = mocks.silence
                sttService = mocks.stt
                let purchaseMock = MockPurchaseService()
                // `--ui-test-purchase-stall` (#129): suspend purchase/restore so
                // the paywall's `.purchasing`/`.restoring` narrating-CTA states
                // stay on screen long enough to screenshot. Without it the mock
                // resolves instantly and the in-flight window is never visible.
                if CommandLine.arguments.contains("--ui-test-purchase-stall") {
                    let stall: () async -> Void = { try? await Task.sleep(for: .seconds(600)) }
                    purchaseMock.purchaseGate = stall
                    purchaseMock.restoreGate = stall
                }
                self.storeManager = StoreManager(purchaseService: purchaseMock)
                self.authService = AuthService(baseURL: Config.apiBaseURL)
                packOrderService = MockPackOrderService()
                storeManager.onPurchaseSuccess = { [weak self] in
                    await self?.quizViewModel?.notifyPremiumPurchased() ?? false
                }
                // Issue #111 T3: seed a fake admin key so `SettingsView.hasAdminKey`
                // is true under UI test — the `packs.createPack` / `packs.myPacks`
                // entries render without a real key. Seed ONLY when the Keychain
                // slot is empty: the store is the sim's persistent Keychain, and
                // an unconditional save would silently clobber a real admin key
                // pasted for manual #95 order testing on the same simulator.
                if AdminKeyStore().load() == nil {
                    AdminKeyStore().save("ui-test")
                }
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
        audioService = AudioService()
        persistenceStore = PersistenceStore()
        self.storeManager = StoreManager()
        packOrderService = PackOrderService(authService: authService)

        // Silence detection / barge-in (iOS 26 SpeechDetector; min target is 26.0).
        let resolved: SilenceDetectionServiceProtocol
        #if DEBUG
            // `--ui-test-voice-ready`: inject a ready mock recognizer so the on-screen
            // "LISTENING FOR COMMANDS" indicator (#96 P2) can be screenshot-verified on
            // the Simulator, where the real SpeechAnalyzer has no installed locales and
            // reports `.unavailable` (which correctly suppresses the cue).
            if CommandLine.arguments.contains("--ui-test-voice-ready") {
                resolved = MockSilenceDetectionService()
            } else {
                let silenceService = SilenceDetectionService()
                // One-time launch authorization + prepare (#77 device fix, #105 auth
                // gap): request speech-recognition permission, then — if granted —
                // check/download the on-device en-US SpeechTranscriber model assets.
                // Without them the command transcriber never yields a result on a
                // real device. Non-blocking; any failure flips `commandAvailability`
                // (fail loud).
                Task { await silenceService.requestAuthorizationAndPrepareAssets() }
                resolved = silenceService
            }
        #else
            let silenceService = SilenceDetectionService()
            // One-time launch authorization + prepare (#77 / #105) — see DEBUG branch.
            Task { await silenceService.requestAuthorizationAndPrepareAssets() }
            resolved = silenceService
        #endif
        silenceDetectionService = resolved

        // ElevenLabs streaming STT (controlled by feature flag)
        if Config.useElevenLabsSTT {
            sttService = ElevenLabsSTTService()
        } else {
            sttService = nil
        }

        // Setup audio session with default mode
        try? audioService.setupAudioSession(mode: AudioMode.default)

        // #131 Track E: diagnostic-only telemetry for the founder-reported
        // hardware volume drift (media volume set to 0, rises during quiz
        // play). Observe-only — never activates/reconfigures the session.
        VolumeChangeMonitor.shared.start(audioService: audioService)

        // Check Apple credential state and register revocation observer (#61 task 61.6).
        // Runs asynchronously so it does not block app launch; a revoked credential
        // drops to a fresh anon identity transparently.
        Task {
            await authService.setupAppleCredentialObservation()
        }

        // RevenueCat account linking (issue #93 Session E must-do, widened in
        // #96 P1): alias RC's identity to the durable account id on EVERY
        // identity mint — anon bootstrap and refresh-failure re-mints, not
        // just Apple sign-in — then re-sync the server-side subscription
        // mirror. Without the bootstrap leg, a purchase on a fresh install
        // lands under an unmappable $RCAnonymousID.
        let storeManager = self.storeManager
        let networkService = self.networkService
        Task {
            await authService.setAccountLinkedHandler { accountId in
                await storeManager.logIn(accountId: accountId)
                try? await networkService.syncEntitlements()
            }
            // The mirror image (founder 2026-07-31): an explicit sign-out
            // releases the RC identity instead of moving it onto the fresh anon
            // id, so the subscription stays with the signed-out account and the
            // new anon user sees no leftover premium.
            await authService.setSignedOutHandler {
                await storeManager.logOut()
            }
        }

        // Post-purchase continuation (#96 P1): entitlement sync + usage
        // refresh on ANY successful purchase or restore attempt — keyed on
        // the purchase *outcome*, not the subscription entitlement state, so
        // consumable packs complete too. Returns whether the server mirror
        // now shows an active entitlement (subscription or pack credits) —
        // `StoreManager.restorePurchases()` needs this to detect a pack-only
        // recovery, since `isPurchased` never reflects packs (#102 finding 3).
        storeManager.onPurchaseSuccess = { [weak self] in
            guard let self else { return false }
            if let viewModel = self.quizViewModel {
                return await viewModel.notifyPremiumPurchased()
            } else {
                try? await self.networkService.syncEntitlements()
                let usage = try? await self.networkService.getUsage()
                return (usage?.isPremium ?? false) || (usage?.creditBalance ?? 0) > 0
            }
        }

        Logger.quiz.info("🚀 AppState initialized")
        Logger.quiz.info("📍 API Base URL: \(Config.apiBaseURL, privacy: .public)")
        Logger.quiz.info("🔇 Silence detection: available")
        let sttEnabled = sttService != nil ? "enabled (ElevenLabs)" : "disabled (using Whisper)"
        Logger.quiz.info("🎙️ Streaming STT: \(sttEnabled)")
    }

    // For testing
    init(
        networkService: NetworkServiceProtocol,
        audioService: AudioServiceProtocol,
        persistenceStore: PersistenceStoreProtocol,
        silenceDetectionService: SilenceDetectionServiceProtocol = SilenceDetectionService(),
        sttService: ElevenLabsSTTServiceProtocol? = nil,
        storeManager: StoreManager? = nil,
        authService: AuthService? = nil,
        packOrderService: PackOrderServiceProtocol = MockPackOrderService()
    ) {
        self.networkService = networkService
        self.audioService = audioService
        self.persistenceStore = persistenceStore
        self.silenceDetectionService = silenceDetectionService
        self.sttService = sttService
        self.storeManager = storeManager ?? StoreManager()
        self.authService = authService ?? AuthService(baseURL: Config.apiBaseURL)
        self.packOrderService = packOrderService
    }

    /// Create a new QuizViewModel with injected dependencies
    func makeQuizViewModel() -> QuizViewModel {
        // #102 finding 1: lets the paywall's pre-429 reconciliation check RC's
        // local entitlement cache without QuizViewModel depending on the
        // concrete StoreManager type.
        let storeManager = self.storeManager
        let viewModel = QuizViewModel(
            networkService: networkService,
            audioService: audioService,
            persistenceStore: persistenceStore,
            silenceDetectionService: silenceDetectionService,
            sttService: sttService,
            isLocallyEntitled: { storeManager.isPurchased }
        )

        #if DEBUG
            // `--ui-test-error`: land directly on a voice QuestionView with the
            // recording-error banner shown, so the error state can be screenshot-
            // verified without driving the full record→disconnect flow. Mirrors the
            // "Connection lost" copy set by RecordingCoordinator+Streaming on STT drop.
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
            // `--ui-test-glow-matched` / `--ui-test-glow-unmatched` (#122): voice
            // QuestionView with the ambient-glow feedback phase pinned, so the
            // Variant C wash/sweep/bar states can be screenshot-verified — the
            // real trigger (SpeechTranscriber) cannot run on the Simulator at
            // all. Direct assignment schedules no clear timer, so the phase is
            // sticky for the screenshot.
            if CommandLine.arguments.contains("--ui-test-glow-matched") {
                viewModel.currentQuestion = Question.preview
                viewModel.quizState = .askingQuestion
                viewModel.voiceCommandCoordinator.voiceFeedbackPhase = .matched
            }
            if CommandLine.arguments.contains("--ui-test-glow-unmatched") {
                viewModel.currentQuestion = Question.preview
                viewModel.quizState = .askingQuestion
                viewModel.voiceCommandCoordinator.voiceFeedbackPhase = .unmatched
            }
            // `--ui-test-result-correct` / `--ui-test-result-incorrect` (#127):
            // land directly on the redesigned Result screen (Variant C) so the
            // verdict field, answer panel and footer can be screenshot-verified.
            // The countdown is pinned so the CTA chip + STAY pill render (no timer
            // runs, so it's static). The incorrect seed carries a deliberately long
            // explanation to force the founder-modification internal scroll.
            if CommandLine.arguments.contains("--ui-test-result-correct") {
                viewModel.currentQuestion = Question.preview
                viewModel.currentSession = QuizSession.preview(score: 3.0, answered: 3, correct: 3)
                viewModel.quizState = .showingResult(
                    question: Question.preview,
                    evaluation: Evaluation.previewCorrect
                )
                viewModel.autoAdvanceCountdown = 5
                viewModel.settings.autoAdvanceDelay = 8
            }
            if CommandLine.arguments.contains("--ui-test-result-incorrect") {
                viewModel.currentQuestion = Question.previewResultLong
                viewModel.currentSession = QuizSession.preview(score: 2.0, answered: 3, correct: 2)
                viewModel.quizState = .showingResult(
                    question: Question.previewResultLong,
                    evaluation: Evaluation(
                        userAnswer: "Saturn",
                        result: .incorrect,
                        points: 0.0,
                        correctAnswer: "Uranus",
                        questionId: Question.previewResultLong.id,
                        explanation: nil
                    )
                )
                viewModel.autoAdvanceCountdown = 5
                viewModel.settings.autoAdvanceDelay = 8
            }
            // `--ui-test-result-skipped` (#131 Track D): a skip must render the
            // neutral "SKIPPED." verdict, never "MISSED IT." — lands directly on
            // the skipped result so the chip/headline/dropped you-said row can be
            // screenshot-verified.
            if CommandLine.arguments.contains("--ui-test-result-skipped") {
                viewModel.currentQuestion = Question.preview
                viewModel.currentSession = QuizSession.preview(score: 2.0, answered: 3, correct: 2)
                viewModel.quizState = .showingResult(
                    question: Question.preview,
                    evaluation: Evaluation(
                        userAnswer: "",
                        result: .skipped,
                        points: 0.0,
                        correctAnswer: "Uranus",
                        questionId: Question.preview.id,
                        explanation: nil
                    )
                )
                viewModel.autoAdvanceCountdown = 5
                viewModel.settings.autoAdvanceDelay = 8
            }
            // `--ui-test-result-nil-evaluation` (#127 req. 6/7): a genuinely nil
            // evaluation cannot route to ResultView (ContentView shows it only for
            // .showingResult, whose payload always carries an evaluation), so this
            // seeds the IDENTICAL recap fallback via an empty-answer evaluation:
            // the empty canonical answer trips `isRecap`, so the question stem
            // becomes the dominant text instead of a blank 46pt row. Plain footer
            // (no countdown) matches the defined nil-path rendering.
            if CommandLine.arguments.contains("--ui-test-result-nil-evaluation") {
                viewModel.currentQuestion = Question.preview
                viewModel.currentSession = QuizSession.preview(score: 3.0, answered: 3, correct: 3)
                viewModel.quizState = .showingResult(
                    question: Question.preview,
                    evaluation: Evaluation(
                        userAnswer: "",
                        result: .incorrect,
                        points: 0.0,
                        correctAnswer: "",
                        questionId: Question.preview.id,
                        explanation: nil
                    )
                )
            }
        #endif

        quizViewModel = viewModel

        #if DEBUG
            // Issue #111 T3: register the live command sink so the `:9999` HTTP
            // listener can drive real voice commands (e.g. "start") through the
            // actual `handleRecognizedCommand` → `routeCommand` pipeline — the
            // recognizer under `--ui-test` is an `.unavailable` mock that never
            // yields transcripts, so this is otherwise
            // undrivable in UI tests.
            if UITestSupport.isUITesting {
                UITestSupport.registerCommandSink { [weak self] text in
                    // An injected utterance is a COMPLETED one (#119): the UI
                    // test types a whole command, never a mid-speech hypothesis.
                    await self?.quizViewModel?.voiceCommandCoordinator
                        .handleCommandTranscript(CommandTranscript(text: text, isFinal: true))
                }
            }
        #endif

        return viewModel
    }
}
