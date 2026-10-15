//
//  QuizViewModel+ScenePhase.swift
//  Hangs
//
//  Scene-phase lifecycle: tear down the microphone INPUT when the app leaves
//  the foreground. UIBackgroundModes audio deliberately stays (question and
//  feedback TTS must keep playing while driving — product decision), but that
//  same mode also kept the SpeechAnalyzer input tap and any in-flight answer
//  recording alive in the background, i.e. the mic stayed hot. Playback
//  continues in the background; input never does.
//

import Clocks
import os
import SwiftUI

extension QuizViewModel {
    /// Route a scene-phase change from HangsApp's WindowGroup.
    /// `.background` tears down all audio input: the command/VAD listener
    /// stops, an in-flight recording aborts via the existing #67 interruption
    /// path, and the audio session is released only when fully idle — never
    /// while TTS is playing. `.active` re-arms the listener via the existing
    /// window sync and reconciles entitlements + usage (#102 findings 1+2).
    /// `.inactive` is transient (app switcher, incoming call UI)
    /// — no teardown, the #67 interruption path covers real interruptions.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Flip the flag FIRST (synchronously): currentCommandScreen returns
            // nil from here on, so a racing refreshCommandWindow() or a
            // post-TTS startSilenceDetectionListening() cannot re-arm the mic.
            isPhoneSceneForeground = false
            attemptLedger.record(.scene, "background")
            // #97: the phone locking under a live CarPlay screen is not leaving
            // the quiz — the driver is still in it, on the car's screen.
            guard !isAppForeground else {
                Logger.audio.info("🌙 Phone → background, CarPlay screen keeps the quiz live")
                return
            }
            tearDownAudioInputForBackground()

        case .active:
            isPhoneSceneForeground = true
            attemptLedger.record(.scene, "active")
            resumeForForeground()

        default:
            break
        }
    }

    /// #97 — CarPlay support: the CarPlay screen came to the front (the driver
    /// opened Trubbo on the car's screen) or left it (switched to Maps,
    /// disconnected). Same rules as the phone window: input runs only while a
    /// screen the driver is using shows the quiz, playback is never cut.
    func handleCarPlayScene(foreground: Bool) {
        let wasForeground = isAppForeground
        isCarPlaySceneForeground = foreground
        attemptLedger.record(.scene, foreground ? "carplay.active" : "carplay.background")
        if foreground {
            resumeForForeground()
        } else if wasForeground, !isAppForeground {
            tearDownAudioInputForBackground()
        }
    }

    private func tearDownAudioInputForBackground() {
        // (a) Tear down the command/VAD listener (idempotent).
        audioDeviceState.stopSilenceDetectionListening()

        // (b) An in-flight answer recording aborts via the existing #67
        // interruption teardown — the single recording state-reset path
        // (no second reset invented here). Since #184 it also drops the
        // batch capture (`abandonAnswerCapture`), so nothing is stopped
        // separately for the batch case any more.
        if quizState == .recording {
            recordingCoordinator.handleAudioInterruption()
        }

        // (c) Release the audio session ONLY when fully idle — never kill
        // in-flight background TTS (the driving use case).
        if quizState == .idle, !audioService.isPlaying {
            audioService.deactivateSession()
        }

        Logger.audio.info("🌙 Scene → background: mic input torn down (playback untouched)")
    }

    private func resumeForForeground() {
        refreshCommandWindow() // re-arm via the existing window sync
        resumeSuppressedAnswerWindow()
        // #179: a submission that wedged while backgrounded has no live owner
        // — this branch did nothing at all for `.processing`/`.skipping`. The
        // watchdog deadline is absolute, so a window that elapsed out of sight
        // surfaces the retryable error on return instead of a dead screen.
        rearmStallWatchdog()

        // Foreground reconciliation (#102 findings 1+2): a webhook that
        // landed while backgrounded (or a purchase sync that failed
        // offline) otherwise only self-heals on the next identity-mint
        // event or purchase. Single-flight + retry/backoff live in
        // `reconcileEntitlements()`.
        Task { [weak self] in
            await self?.entitlementReconciler.reconcileEntitlements()
        }
    }

    /// #171 Track H (founder 2026-09-05): countdowns keep running while
    /// backgrounded, but `startRecording()` refuses to open the mic there — so a
    /// think window that expired out of sight used to leave the driver parked on
    /// a question with every countdown at zero and nothing to press. On return
    /// we do what should have happened: open the mic if the answer window it was
    /// about to start still has time left, otherwise close the question out on
    /// the no-answer confirmation sheet (the Track B path) so the quiz keeps
    /// moving. Anything that already left `.askingQuestion` resolved itself.
    private func resumeSuppressedAnswerWindow() {
        // #173: a paused quiz must not open the mic on a foreground return —
        // that is the one re-arm the timers' own pause guards cannot catch,
        // because this path starts a RECORDING rather than a countdown. The
        // suppression marker is deliberately kept: resuming takes the question
        // from the top instead of from a window nobody was there for.
        guard !isPaused else { return }
        guard quizState == .askingQuestion,
              let suppressedAt = recordingCoordinator.backgroundSuppressedRecordingAt
        else { return }
        recordingCoordinator.backgroundSuppressedRecordingAt = nil

        if suppressedAt.duration(to: clock.now) < .seconds(Config.autoRecordingDuration) {
            Logger.audio.info("🌅 Scene → active: opening the answer window suppressed in the background")
            let owner = currentAttempt
            Task { [weak self] in
                guard let self, self.attemptLedger.ownsQuestion(owner, "foregroundResume.start") else { return }
                await self.recordingCoordinator.startRecording(trigger: .foregroundResume)
            }
        } else {
            Logger.audio.info("🌅 Scene → active: the whole answer window elapsed in the background — no answer")
            // #185 track B: straight to the Again/Skip sheet — the driver was
            // not there for a "didn't catch that", and the mic must not open by
            // itself on the way back.
            recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        }
    }
}
